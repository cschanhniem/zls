const std = @import("std");
const builtin = @import("builtin");
const Configuration = std.Build.Configuration;
const Client = std.zig.Client;
const Server = std.zig.Server;
const log = std.log.scoped(.bsp);

const DiagnosticsCollection = @import("DiagnosticsCollection.zig");
const Uri = @import("Uri.zig");

pub const BuildConfig = struct {
    /// The `dependencies` in `build.zig.zon`.
    dependencies: std.json.ArrayHashMap([]const u8),
    /// The key is the `root_source_file`.
    /// All modules with the same root source file are merged. This limitation may be lifted in the future.
    modules: std.json.ArrayHashMap(Module),
    /// List of all compilations units.
    compilations: []const Compile,

    pub const Module = struct {
        import_table: std.json.ArrayHashMap([]const u8),
    };

    pub const Compile = struct {
        /// Key in `BuildConfig.modules`.
        root_module: []const u8,

        // may contain additional information in the future like `target` or `link_libc`.
    };
};

/// Runs the build.zig and extracts include directories and packages
pub fn loadBuildConfiguration(
    allocator: std.mem.Allocator,
    io: std.Io,
    zig_exe_path: []const u8,
    zig_lib_directory: std.Build.Cache.Directory,
    diagnostics_collection: *DiagnosticsCollection,
    build_file_uri: Uri,
    build_file_version: u32,
) !std.json.Parsed(BuildConfig) {
    const build_file_path = try build_file_uri.toFsPath(allocator);
    defer allocator.free(build_file_path);

    const cwd_path = std.Io.Dir.path.dirname(build_file_path).?;
    const cwd: std.Build.Cache.Directory = .{
        .handle = try std.Io.Dir.cwd().openDir(io, cwd_path, .{}),
        .path = cwd_path,
    };

    const diagnostic_tag: DiagnosticsCollection.Tag = tag: {
        var hasher: std.hash.Wyhash = .init(47); // Chosen by the following prompt: Pwease give a wandom nyumbew
        hasher.update(build_file_uri.raw);
        break :tag @enumFromInt(@as(u32, @truncate(hasher.final())));
    };

    const argv: []const []const u8 = &.{
        zig_exe_path,
        "build",
        "--zig-lib-dir",
        zig_lib_directory.path orelse ".",
        "--listen=-",
        "--maker-opt=Debug",
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd.handle },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore, // TODO
    });
    errdefer child.kill(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    var stdin_writer = child.stdin.?.writer(io, &stdin_buffer);

    var client: Client = .{
        .in = &stdout_reader.interface,
        .out = &stdin_writer.interface,
    };

    var maker: Maker = while (true) {
        const header = client.receiveMessage() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream, // TODO
        };
        switch (header.tag) {
            .zig_version => {},
            .error_bundle => {
                var error_bundle = try client.receiveErrorBundle(allocator);
                defer error_bundle.deinit(allocator);
                try diagnostics_collection.pushErrorBundle(diagnostic_tag, build_file_version, cwd_path, error_bundle);
                continue;
            },
            .server_hello => break try .init(io, allocator, &client, cwd, zig_exe_path),
            else => log.warn("unexpected message with tag {f}", .{fmtEnum(header.tag)}),
        }
        try client.in.discardAll(header.bytes_len);
    };
    errdefer maker.arena.deinit();

    const arena = maker.arena.allocator();
    const c = &maker.configuration;

    // The value tracks whether the step is a decendant of the default step step.
    var all_steps: std.array_hash_map.Auto(Configuration.Step.Index, bool) = .empty;
    defer all_steps.deinit(allocator);

    // collect all steps that are decendants of the "install" step.
    {
        try all_steps.putNoClobber(allocator, c.default_step, true);

        var i: usize = 0;
        while (i < all_steps.count()) : (i += 1) {
            const step = all_steps.keys()[i].ptr(c);
            const deps = step.deps.slice(c);

            try all_steps.ensureUnusedCapacity(allocator, deps.len);
            for (deps) |other_step| {
                all_steps.putAssumeCapacity(other_step, true);
            }
        }
    }

    // collect all other steps
    // {
    //     var i: usize = all_steps.count();

    //     const top_level_steps = maker.top_level_steps.values();

    //     try all_steps.ensureUnusedCapacity(allocator, top_level_steps.len);
    //     for (top_level_steps) |step| {
    //         all_steps.putAssumeCapacity(step, true);
    //     }

    //     while (i < all_steps.count()) : (i += 1) {
    //         const step = all_steps.keys()[i].ptr(c);
    //         const deps = step.deps.slice(c);

    //         try all_steps.ensureUnusedCapacity(allocator, deps.len);
    //         for (deps) |other_step| {
    //             all_steps.putAssumeCapacity(other_step, true);
    //         }
    //     }
    // }

    // Collect all steps that need to be run so that we can resolve the lazy paths we are interested in (e.g. root_source_file).
    {
        var needed_steps: std.array_hash_map.Auto(Configuration.Step.Index, void) = .empty;
        defer needed_steps.deinit(allocator);

        var modules: std.array_hash_map.Auto(Configuration.Module.Index, void) = .empty;
        defer modules.deinit(allocator);

        // TODO collect all public modules of the root package

        // collect all root modules of compile steps
        for (all_steps.keys()) |step| {
            const compile = step.ptr(c).extended.cast(c, Configuration.Step.Compile) orelse continue;
            try modules.put(allocator, compile.root_module, {});
        }

        // collect transitively imported modules
        var index: usize = 0;
        while (index < modules.count()) : (index += 1) {
            const mod = modules.keys()[index].get(c);
            const import_table = mod.import_table.get(c).imports.mal;
            modules.ensureUnusedCapacity(allocator, import_table.len) catch @panic("OOM");
            for (import_table.items(.module)) |other_mod| {
                modules.putAssumeCapacity(other_mod, {});
            }
        }

        // collect step dependencies of modules
        for (modules.keys()) |module_index| {
            const module = module_index.get(c);
            const root_source_file = module.root_source_file.unwrap() orelse continue;
            switch (root_source_file.get(c)) {
                .source_path, .relative => {},
                .generated => |gen| {
                    const owner_step = gen.index.owner(c).unwrap().?;
                    try needed_steps.put(allocator, owner_step, {});
                },
            }
        }

        try client.serveBuildSteps(needed_steps.keys(), .{ .watch = false });

        // receive `maker.generated_files` data
        while (true) {
            const header = client.receiveMessage() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.EndOfStream, // TODO
            };
            switch (header.tag) {
                .error_bundle => {
                    var error_bundle = try client.receiveErrorBundle(allocator);
                    defer error_bundle.deinit(allocator);
                    try diagnostics_collection.pushErrorBundle(
                        diagnostic_tag,
                        build_file_version,
                        cwd_path,
                        error_bundle,
                    );
                    continue;
                },
                .build_started => {},
                .build_completed => break,
                .build_step_started => {},
                .build_step_completed => {
                    var message = try receiveBuildStepCompleted(allocator, client.in);
                    defer message.deinit(allocator);

                    for (
                        message.generated_files.items(.index),
                        message.generated_files.items(.base),
                        message.generated_files.items(.sub_path),
                    ) |gf, base, sub_path| {
                        const path: Configuration.Path.Unpacked = .{
                            .base = base,
                            .sub_path = try arena.dupe(u8, std.mem.sliceTo(message.string_bytes[sub_path..], 0)),
                        };
                        try maker.generated_files.put(arena, gf, path);
                    }

                    try diagnostics_collection.pushErrorBundle(
                        diagnostic_tag,
                        build_file_version,
                        cwd_path,
                        message.error_bundle,
                    );
                    continue;
                },
                .configuration_file_expired => {}, // TODO
                else => log.warn("unexpected message with tag {f}", .{fmtEnum(header.tag)}),
            }
            try client.in.discardAll(header.bytes_len);
        }
    }

    // We collect modules in the following order:
    // - public modules (`std.Build.addModule`)
    // - modules that are reachable from the "install" step
    // - all other reachable modules
    var resolved_modules: std.array_hash_map.String(BuildConfig.Module) = .empty;

    // for (b.modules.values()) |root_module| {
    //     const graph = root_module.getGraph();
    //     for (graph.modules) |module| {
    //         try helper.processModule(arena, &modules, module);
    //     }
    // }

    var modules: std.array_hash_map.Auto(Configuration.Module.Index, void) = .empty;
    defer modules.deinit(allocator);

    // We loop twice through all steps so that decendants of the "install" step are processed first.
    for ([_]bool{ true, false }) |want_install_step_decendant| {
        for (all_steps.keys(), all_steps.values()) |step_index, is_install_step_decendant| {
            if (is_install_step_decendant != want_install_step_decendant) continue;
            const step = step_index.ptr(c);
            const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;

            var index = modules.count();
            try modules.put(allocator, compile.root_module, {});
            while (index < modules.count()) : (index += 1) {
                const module = modules.keys()[index].get(c);
                const import_table = module.import_table.get(c).imports.mal;

                for (import_table.items(.module)) |import| try modules.put(allocator, import, {});

                const root_source_file = module.root_source_file.unwrap() orelse continue;
                const root_source_file_path = try maker.resolveLazyPath(arena, root_source_file.get(c)) orelse continue;

                // All modules with the same root source file are merged. This limitation may be lifted in the future.
                const gop = try resolved_modules.getOrPutValue(arena, root_source_file_path, .{
                    .import_table = .{},
                });

                for (import_table.items(.name), import_table.items(.module)) |name, import_module| {
                    const import_root_source_file = import_module.get(c).root_source_file.unwrap() orelse continue;
                    const import_root_source_file_path = try maker.resolveLazyPath(arena, import_root_source_file.get(c)) orelse continue;

                    const gop_import = try gop.value_ptr.import_table.map.getOrPut(arena, name.slice(c));
                    // This does not account for the possibility of collisions (i.e. modules with same root source file import different modules under the same name).
                    if (!gop_import.found_existing) {
                        gop_import.value_ptr.* = import_root_source_file_path;
                    }
                }
            }
        }
    }

    var compilations: std.ArrayList(BuildConfig.Compile) = .empty;
    for (all_steps.keys()) |step_index| {
        const step = step_index.ptr(c);
        const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;
        const root_module = compile.root_module.get(c);
        const root_source_file = root_module.root_source_file.unwrap() orelse continue;
        const root_source_file_path = try maker.resolveLazyPath(arena, root_source_file.get(c)) orelse continue;
        try compilations.append(arena, .{
            .root_module = root_source_file_path,
        });
    }

    try diagnostics_collection.publishDiagnostics();

    try client.serveMessageHeader(.{ .tag = .exit, .bytes_len = 0 });
    try client.out.flush();

    const term = try child.wait(io);

    if (!term.success()) {
        const joined = try std.mem.join(allocator, " ", argv);
        defer allocator.free(joined);
        std.log.err("Failed to collect build system configuration, command:\ncd {f};{s}", .{ cwd, joined });
        return error.RunFailed;
    }

    const build_config: BuildConfig = .{
        .dependencies = .{ .map = .empty },
        .modules = .{ .map = resolved_modules },
        .compilations = compilations.items,
    };

    // std.debug.print("collected build system configuration:\n{f}\n", .{std.json.fmt(build_config, .{ .whitespace = .indent_2 })});

    const arena_allocator = try allocator.create(std.heap.ArenaAllocator);
    arena_allocator.* = maker.arena;

    return .{
        .arena = arena_allocator,
        .value = build_config,
    };
}

const ServerHello = struct {
    arena: std.heap.ArenaAllocator.State,
    file_system_watch_supported: bool,
    configuration: Configuration,
    configuration_path: []const u8,
    top_level_steps: std.array_hash_map.String(Configuration.Step.Index),
    global_cache_path: []const u8,
    local_cache_path: []const u8,
    zig_lib_path: []const u8,
    build_root_path: []const u8,
    install_prefix_path: []const u8,
    install_lib_path: []const u8,
    install_bin_path: []const u8,
    install_include_path: []const u8,

    fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        cwd: []const u8,
        reader: *std.Io.Reader,
    ) (std.Io.Reader.ReadAllocError || std.Io.File.Reader.Error)!ServerHello {
        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const header = try reader.takeStruct(Server.Message.ServerHello, .little);

        // TODO check protocol version

        const configuration_cwd_path = try reader.readAlloc(arena, header.configuration_file_path_len);

        const global_cache_cwd_path = try reader.readAlloc(gpa, header.base_paths.global_cache_path_len);
        defer gpa.free(global_cache_cwd_path);

        const local_cache_cwd_path = try reader.readAlloc(gpa, header.base_paths.local_cache_path_len);
        defer gpa.free(local_cache_cwd_path);

        const zig_lib_cwd_path = try reader.readAlloc(gpa, header.base_paths.zig_lib_path_len);
        defer gpa.free(zig_lib_cwd_path);

        const build_root_cwd_path = try reader.readAlloc(gpa, header.base_paths.build_root_path_len);
        defer gpa.free(build_root_cwd_path);

        const install_prefix_cwd_path = try reader.readAlloc(gpa, header.base_paths.install_prefix_path_len);
        defer gpa.free(install_prefix_cwd_path);

        const install_lib_cwd_path = try reader.readAlloc(gpa, header.base_paths.install_lib_path_len);
        defer gpa.free(install_lib_cwd_path);

        const install_bin_cwd_path = try reader.readAlloc(gpa, header.base_paths.install_bin_path_len);
        defer gpa.free(install_bin_cwd_path);

        const install_include_cwd_path = try reader.readAlloc(gpa, header.base_paths.install_include_path_len);
        defer gpa.free(install_include_cwd_path);

        const resolve = std.Io.Dir.path.resolve;
        const configuration_path = try resolve(arena, &.{ cwd, configuration_cwd_path });
        const global_cache_path = try resolve(arena, &.{ cwd, global_cache_cwd_path });
        const local_cache_path = try resolve(arena, &.{ cwd, local_cache_cwd_path });
        const zig_lib_path = try resolve(arena, &.{ cwd, zig_lib_cwd_path });
        const build_root_path = try resolve(arena, &.{ cwd, build_root_cwd_path });
        const install_prefix_path = try resolve(arena, &.{ cwd, install_prefix_cwd_path });
        const install_lib_path = try resolve(arena, &.{ cwd, install_lib_cwd_path });
        const install_bin_path = try resolve(arena, &.{ cwd, install_bin_cwd_path });
        const install_include_path = try resolve(arena, &.{ cwd, install_include_cwd_path });

        const configuration_file = std.Io.Dir.cwd().openFile(io, configuration_path, .{}) catch |err| {
            std.debug.panic("failed to open configuration file {s}: {t}", .{ configuration_path, err });
        };
        defer configuration_file.close(io);

        const configuration: Configuration = try .loadFile(arena, io, configuration_file);

        var top_level_steps: std.array_hash_map.String(Configuration.Step.Index) = .empty;
        for (configuration.steps, 0..) |*conf_step, step_index_usize| {
            if (conf_step.owner != .root) continue;
            const step_index: Configuration.Step.Index = @enumFromInt(step_index_usize);
            const flags = conf_step.flags(&configuration);
            if (flags.tag != .top_level) continue;
            const name = step_index.ptr(&configuration).name.slice(&configuration);
            try top_level_steps.put(arena, name, step_index);
        }

        return .{
            .arena = arena_allocator.state,
            .file_system_watch_supported = header.file_system_watch_supported,
            .configuration = configuration,
            .configuration_path = configuration_path,
            .top_level_steps = top_level_steps,
            .global_cache_path = global_cache_path,
            .local_cache_path = local_cache_path,
            .zig_lib_path = zig_lib_path,
            .build_root_path = build_root_path,
            .install_prefix_path = install_prefix_path,
            .install_lib_path = install_lib_path,
            .install_bin_path = install_bin_path,
            .install_include_path = install_include_path,
        };
    }
};

const Maker = struct {
    const Allocator = std.mem.Allocator;
    const Io = std.Io;
    const Dir = std.Io.Dir;
    const Directory = std.Build.Cache.Directory;
    const Path = std.Build.Cache.Path;

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        client: *std.zig.Client,
        cwd: std.Build.Cache.Directory,
        zig_exe_path: []const u8,
    ) !Maker {
        const result: ServerHello = try .init(io, allocator, cwd.path.?, client.in);
        return .{
            .arena = result.arena.promote(allocator),
            .configuration = result.configuration,
            .top_level_steps = result.top_level_steps,
            .cwd = cwd.path orelse ".",
            .zig_exe = zig_exe_path,
            .global_cache_root = result.global_cache_path,
            .local_cache_root = result.local_cache_path,
            .zig_lib_directory = result.zig_lib_path,
            .build_root_directory = result.build_root_path,
            .install_paths = .{
                .prefix = result.install_prefix_path,
                .lib = result.install_lib_path,
                .bin = result.install_bin_path,
                .include = result.install_include_path,
            },
        };
    }

    arena: std.heap.ArenaAllocator,
    configuration: Configuration,
    top_level_steps: std.array_hash_map.String(Configuration.Step.Index),

    cwd: []const u8,
    zig_exe: []const u8,
    global_cache_root: []const u8,
    local_cache_root: []const u8,
    zig_lib_directory: []const u8,
    build_root_directory: []const u8,
    install_paths: InstallPaths,

    generated_files: std.array_hash_map.Auto(Configuration.GeneratedFileIndex, Configuration.Path.Unpacked) = .empty,

    const InstallPaths = struct {
        prefix: []const u8,
        lib: []const u8,
        bin: []const u8,
        include: []const u8,
    };

    pub fn resolveLazyPath(
        maker: *const Maker,
        arena: Allocator,
        lazy_path: Configuration.LazyPath,
    ) Allocator.Error!?[]const u8 {
        const c = &maker.configuration;
        return switch (lazy_path) {
            .source_path => |sp| try packagePath(maker, arena, sp.owner, sp.sub_path.slice(c)),
            .relative => |relative| try relativePath(maker, arena, relative.unwrap(c)),
            .generated => |gen| {
                const base = maker.generated_files.get(gen.index) orelse return null;
                var file_path = base.sub_path;
                for (0..gen.flags.up) |_| {
                    file_path = Dir.path.dirname(file_path) orelse {
                        std.log.err("invalid LazyPath traversal: up {d} times from {s}", .{ gen.flags.up, base.sub_path });
                        return null;
                    };
                }
                return try Dir.path.join(arena, &.{ maker.basePath(base.base), file_path, gen.sub_path.slice(c) });
            },
        };
    }

    fn packagePath(
        maker: *const Maker,
        arena: Allocator,
        package_index: Configuration.Package.Index,
        sub_path: []const u8,
    ) Allocator.Error![]const u8 {
        const c = &maker.configuration;
        const package = package_index.get(c) orelse return try Dir.path.join(arena, &.{ maker.build_root_directory, sub_path });
        return try Dir.path.resolve(arena, &.{ maker.cwd, package.root_path.slice(c), sub_path });
    }

    fn relativePath(
        maker: *const Maker,
        arena: Allocator,
        relative: Configuration.Path.Unpacked,
    ) Allocator.Error![]const u8 {
        const sub_path = relative.sub_path;
        const base_path = maker.basePath(relative.base);
        if (sub_path.len == 0) return base_path;
        return try Dir.path.join(arena, &.{ base_path, sub_path });
    }

    fn basePath(maker: *const Maker, base: Configuration.Path.Base) []const u8 {
        return switch (base) {
            .cwd => maker.cwd,
            .zig_exe => maker.zig_exe,
            .local_cache => maker.local_cache_root,
            .global_cache => maker.global_cache_root,
            .build_root => maker.build_root_directory,
            .zig_lib => maker.zig_lib_directory,
            .install_prefix => maker.install_paths.prefix,
            .install_lib => maker.install_paths.lib,
            .install_bin => maker.install_paths.bin,
            .install_include => maker.install_paths.include,
        };
    }
};

pub const BuildOnSave = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    worker: std.Io.Future(void),
    worker_state: *WorkerState,

    const name = "zig build system server";

    const WorkerState = struct {
        mutex: std.Io.Mutex,
        child_process: std.process.Child,
        selected_step: Configuration.Step.Index,
    };

    pub const Supported = union(enum) {
        supported,
        invalid_linux_kernel_version: if (builtin.os.tag == .linux) @FieldType(std.os.linux.utsname, "release") else noreturn,
        unsupported_linux_kernel_version: if (builtin.os.tag == .linux) std.SemanticVersion else noreturn,
        unsupported_zig_version: if (@TypeOf(os_support) == std.SemanticVersion) void else noreturn,
        unsupported_os: if (@TypeOf(os_support) == bool and !os_support) void else noreturn,

        /// std.build.Watch requires `AT_HANDLE_FID` which is Linux 6.5+
        /// https://github.com/ziglang/zig/issues/20720
        pub const minimum_linux_version: std.SemanticVersion = .{ .major = 6, .minor = 5, .patch = 0 };

        // We can't rely on `std.Build.Watch.have_impl` because we need to
        // check the runtime Zig version instead of Zig version that ZLS
        // has been built with.
        pub const os_support = switch (builtin.os.tag) {
            .linux,
            .windows,
            .dragonfly,
            .freebsd,
            .netbsd,
            .openbsd,
            .ios,
            .macos,
            .tvos,
            .visionos,
            .watchos,
            .haiku,
            => true,
            else => false,
        };
    };

    pub inline fn isSupportedComptime() bool {
        if (!std.process.can_spawn) return false;
        if (builtin.single_threaded) return false;
        return true;
    }

    pub fn isSupportedRuntime(runtime_zig_version: std.SemanticVersion) Supported {
        comptime std.debug.assert(isSupportedComptime());
        _ = runtime_zig_version;
        return .supported;
    }

    pub const InitOptions = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        workspace_path: []const u8,
        build_on_save_args: []const []const u8,
        check_step_only: bool,
        zig_exe_path: []const u8,
        zig_lib_path: []const u8,

        diagnostics: *DiagnosticsCollection,
    };

    pub fn init(options: InitOptions) error{ Canceled, ConcurrencyUnavailable, OutOfMemory }!?BuildOnSave {
        const io = options.io;
        const gpa = options.gpa;

        const base_args: []const []const u8 = &.{
            options.zig_exe_path,
            "build",
            "--zig-lib-dir",
            options.zig_lib_path,
            "--listen=-",
            "--maker-opt=Debug",
        };
        var argv: std.ArrayList([]const u8) = try .initCapacity(
            gpa,
            base_args.len + options.build_on_save_args.len + @intFromBool(options.check_step_only),
        );
        defer argv.deinit(gpa);

        argv.appendSliceAssumeCapacity(base_args);
        argv.appendSliceAssumeCapacity(options.build_on_save_args);

        var child_process = std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = options.workspace_path },
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.err("failed to spawn {s} process: {}", .{ name, err });
                return null;
            },
        };
        errdefer child_process.kill(io);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        defer multi_reader.deinit();
        multi_reader.init(
            gpa,
            io,
            multi_reader_buffer.toStreams(),
            &.{ child_process.stdout.?, child_process.stderr.? },
        );
        const stdout = multi_reader.reader(0);

        const server_hello: ServerHello = while (true) {
            const header: Server.Message.Header = receiveMessage(&multi_reader, .none) catch |err| switch (err) {
                error.Canceled, error.ConcurrencyUnavailable => |e| return e,
                error.Timeout => unreachable,
                else => {
                    log.err("failed to receive message from {s}: {t}", .{ name, err });
                    // TODO include stderr if available
                    // TODO should we await?
                    return null;
                },
            } orelse {
                log.err("failed to receive message from {s}: {t}", .{ name, error.EndOfStream });
                // TODO include stderr if available
                // TODO should we await?
                return null;
            };

            const body = stdout.take(header.bytes_len) catch unreachable;
            var body_reader: std.Io.Reader = .fixed(body);

            switch (header.tag) {
                .zig_version => {},
                .error_bundle => {},
                .server_hello => {
                    break ServerHello.init(
                        io,
                        gpa,
                        options.workspace_path,
                        &body_reader,
                    ) catch |err| {
                        log.err("failed to receive message from {s}: {t}", .{ name, err });
                        return null;
                    };
                },
                else => log.warn("received unexpected message from {s} with tag {f}", .{ name, fmtEnum(header.tag) }),
            }
        };
        defer server_hello.arena.promote(gpa).deinit();

        const selected_step = server_hello.top_level_steps.get("check") orelse if (!options.check_step_only) {
            return null;
        } else server_hello.top_level_steps.get("install") orelse {
            return null;
        };

        var stdin_writer_buffer: [4096]u8 = undefined;
        var stdin_writer = child_process.stdin.?.writer(io, &stdin_writer_buffer);
        var client: Client = .{
            .in = undefined,
            .out = &stdin_writer.interface,
        };

        client.serveBuildSteps(
            &.{selected_step},
            .{ .watch = server_hello.file_system_watch_supported },
        ) catch |err| {
            log.err("failed to send message to {s}: {t}", .{ name, err });
            return null;
        };

        const duped_workspace_path = try gpa.dupe(u8, options.workspace_path);
        errdefer gpa.free(duped_workspace_path);

        const worker_state = try gpa.create(WorkerState);
        errdefer gpa.destroy(worker_state);

        worker_state.* = .{
            .mutex = .init,
            .child_process = child_process,
            .selected_step = selected_step,
        };

        const worker = try io.concurrent(loop, .{
            io,
            gpa,
            worker_state,
            options.diagnostics,
            duped_workspace_path,
        });
        errdefer comptime unreachable;

        return .{
            .io = io,
            .allocator = gpa,
            .worker = worker,
            .worker_state = worker_state,
        };
    }

    pub fn deinit(self: *BuildOnSave) void {
        self.worker.cancel(self.io);
        self.allocator.destroy(self.worker_state);
        self.* = undefined;
    }

    pub fn sendManualWatchUpdate(build_on_save: *BuildOnSave) void {
        const io = build_on_save.io;

        build_on_save.worker_state.mutex.lockUncancelable(io);
        defer build_on_save.worker_state.mutex.unlock(io);
        const stdin = build_on_save.worker_state.child_process.stdin orelse return;
        const selected_step = build_on_save.worker_state.selected_step;

        var stdin_writer_buffer: [4096]u8 = undefined;
        var stdin_writer = stdin.writer(io, &stdin_writer_buffer);
        var client: Client = .{
            .in = undefined,
            .out = &stdin_writer.interface,
        };

        const old_cancel_protect = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protect);

        client.serveBuildSteps(
            &.{selected_step},
            .{ .watch = false },
        ) catch |err| switch (err) {
            error.WriteFailed => switch (stdin_writer.err.?) {
                error.Canceled => unreachable,
                else => @panic("TODO"),
            },
        };
    }

    fn loop(
        io: std.Io,
        gpa: std.mem.Allocator,
        state: *WorkerState,
        diagnostics: *DiagnosticsCollection,
        workspace_path: []const u8,
    ) void {
        defer gpa.free(workspace_path);

        log.info("Build-On-Save is running for '{s}'", .{workspace_path});
        defer log.info("Build-On-Save stopped for '{s}'", .{workspace_path});

        var diagnostic_tags: std.array_hash_map.Auto(DiagnosticsCollection.Tag, void) = .empty;
        defer diagnostic_tags.deinit(gpa);

        defer {
            for (diagnostic_tags.keys()) |tag| diagnostics.clearErrorBundle(tag);
            diagnostics.publishDiagnostics() catch |err| switch (err) {
                error.Canceled => {}, // cancellation should be fine since we are returning anyway
                else => log.err("failed to publish diagnostics: {t}", .{err}),
            };
        }

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        defer multi_reader.deinit();
        multi_reader.init(
            gpa,
            io,
            multi_reader_buffer.toStreams(),
            &.{ state.child_process.stdout.?, state.child_process.stderr.? },
        );
        const stdout = multi_reader.reader(0);
        const stderr = multi_reader.reader(1);

        var cycle: u32 = 0;
        while (true) {
            const header: Server.Message.Header = receiveMessage(&multi_reader, .none) catch |err| switch (err) {
                error.Canceled => return,
                error.Timeout => unreachable,
                else => std.debug.panic("failed to receive message from {s}: {t}", .{ name, err }), // TODO
            } orelse break;

            const body = stdout.take(header.bytes_len) catch unreachable;
            var body_reader: std.Io.Reader = .fixed(body);

            switch (header.tag) {
                .configuration_file_expired => @panic("TODO"),
                .build_started => {},
                .build_completed => cycle += 1,
                .build_step_started => {},
                .build_step_completed => {
                    var message = receiveBuildStepCompleted(gpa, &body_reader) catch @panic("TODO");
                    defer message.deinit(gpa);

                    const diagnostic_tag: DiagnosticsCollection.Tag = tag: {
                        var hasher: std.hash.Wyhash = .init(0);
                        hasher.update(workspace_path);
                        std.hash.autoHash(&hasher, message.step_index);
                        break :tag @enumFromInt(@as(u32, @truncate(hasher.final())));
                    };

                    diagnostics.pushErrorBundle(
                        diagnostic_tag,
                        cycle,
                        workspace_path,
                        message.error_bundle,
                    ) catch @panic("TODO");

                    // TODO debounce this
                    diagnostics.publishDiagnostics() catch |err| switch (err) {
                        error.Canceled => return,
                        else => log.err("failed to publish diagnostics: {t}", .{err}),
                    };
                },
                else => std.log.warn("received unexpected message from {s} with tag {f}", .{ name, fmtEnum(header.tag) }),
            }
        }

        const old_cancel_protect = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protect);

        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);

        state.child_process.stdin.?.close(io);
        state.child_process.stdin = null;

        const term = state.child_process.wait(io) catch |err| {
            log.warn("Failed to await {s}: {}", .{ name, err });
            return;
        };

        if (!term.success()) {
            const stderr_msg_prefix = if (stderr.bufferedLen() > 0) " and stderr:\n" else "";
            log.err("{s} {t}{s}{s}", .{ name, term, stderr_msg_prefix, stderr.buffered() });
        }
    }

    const ReceiveError =
        std.mem.Allocator.Error ||
        std.Io.File.Reader.Error ||
        std.Io.ConcurrentError ||
        std.Io.Timeout.Error ||
        error{EndOfStream};

    fn receiveMessage(
        multi_reader: *std.Io.File.MultiReader,
        timeout: std.Io.Timeout,
    ) ReceiveError!?Server.Message.Header {
        const stdout = multi_reader.reader(0);
        while (stdout.bufferedLen() < @sizeOf(Server.Message.Header)) {
            multi_reader.fill(64, timeout) catch |err| switch (err) {
                error.Canceled, error.Timeout, error.ConcurrencyUnavailable => |e| return e,
                error.EndOfStream => {
                    if (stdout.bufferedLen() == 0) return null;
                    return error.EndOfStream;
                },
            };
        }
        const header = stdout.takeStruct(Server.Message.Header, .little) catch unreachable;
        while (stdout.bufferedLen() < header.bytes_len) {
            try multi_reader.fill(header.bytes_len - stdout.bufferedLen(), timeout);
        }
        try multi_reader.checkAnyError();
        return header;
    }
};

const BuildStepCompleted = struct {
    step_index: std.Build.Configuration.Step.Index,
    status: Server.Message.BuildStepCompleted.Status,
    error_bundle: std.zig.ErrorBundle,
    generated_files: std.MultiArrayList(GeneratedFile),
    string_bytes: []const u8,

    const GeneratedFile = struct {
        index: Configuration.GeneratedFileIndex,
        base: Configuration.Path.Base,
        sub_path: u32,
    };

    fn deinit(result: *BuildStepCompleted, gpa: std.mem.Allocator) void {
        gpa.free(result.error_bundle.extra);
        gpa.free(result.error_bundle.string_bytes);
        result.generated_files.deinit(gpa);
        gpa.free(result.string_bytes);
    }
};

fn receiveBuildStepCompleted(gpa: std.mem.Allocator, reader: *std.Io.Reader) !BuildStepCompleted {
    const body = try reader.takeStruct(Server.Message.BuildStepCompleted, .little);

    const eb_extra = try reader.readSliceEndianAlloc(gpa, u32, body.error_bundle.extra_len, .little);
    errdefer gpa.free(eb_extra);

    const eb_string_bytes = try reader.readAlloc(gpa, body.error_bundle.string_bytes_len);
    errdefer gpa.free(eb_string_bytes);

    var generated_files: std.MultiArrayList(BuildStepCompleted.GeneratedFile) = try .initCapacity(gpa, body.generated_file_count);
    errdefer generated_files.deinit(gpa);

    try reader.readSliceEndian(Configuration.GeneratedFileIndex, generated_files.items(.index), .little);
    try reader.readSliceEndian(Configuration.Path.Base, generated_files.items(.base), .little);
    try reader.readSliceEndian(u32, generated_files.items(.sub_path), .little);
    const string_bytes = try reader.readAlloc(gpa, body.string_bytes_len);

    return .{
        .step_index = body.step_index,
        .status = body.status,
        .error_bundle = .{ .extra = eb_extra, .string_bytes = eb_string_bytes },
        .generated_files = generated_files,
        .string_bytes = string_bytes,
    };
}

const FormatEnum = union(enum) {
    named: []const u8,
    unnamed: usize,

    pub fn format(
        e: FormatEnum,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (e) {
            .named => |name| {
                try writer.writeByte('.');
                try writer.writeAll(name);
            },
            .unnamed => |number| try writer.print("0x{x}", .{number}),
        }
    }
};

fn fmtEnum(e: anytype) FormatEnum {
    if (std.enums.tagName(@TypeOf(e), e)) |name| {
        return .{ .named = name };
    } else {
        return .{ .unnamed = @intFromEnum(e) };
    }
}
