const std = @import("std");
const Configuration = std.Build.Configuration;

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
    /// The names of all top level steps.
    top_level_steps: []const []const u8,

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

    var client: std.zig.Client = .{
        .in = &stdout_reader.interface,
        .out = &stdin_writer.interface,
    };

    var got_errors = false;

    var maker: Maker = while (true) {
        const header = client.receiveMessage() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream, // TODO
        };
        std.debug.print("header (1): .{t} ({d} bytes)\n", .{ header.tag, header.bytes_len });
        switch (header.tag) {
            .zig_version => {},
            .error_bundle => {
                var error_bundle = try client.receiveErrorBundle(allocator);
                defer error_bundle.deinit(allocator);
                try diagnostics_collection.pushErrorBundle(diagnostic_tag, build_file_version, cwd_path, error_bundle);
                got_errors = true;
                continue;
            },
            .server_hello => break try .init(allocator, io, &client, cwd, zig_exe_path),
            else => std.log.err("unexpected message: .{t}", .{header.tag}),
        }
        try client.in.discardAll(header.bytes_len);
    };
    defer maker.deinit(allocator);

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
            const import_table = mod.import_table.get(c).imports;
            modules.ensureUnusedCapacity(allocator, import_table.mal.len) catch @panic("OOM");
            for (import_table.mal.items(.module)) |other_mod| {
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

        try client.serveBuildStepCompleted(needed_steps.keys());

        // receive `maker.generated_files` data
        while (true) {
            const header = client.receiveMessage() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => return error.EndOfStream, // TODO
            };
            std.debug.print("header (2): .{t} ({d} bytes)\n", .{ header.tag, header.bytes_len });
            switch (header.tag) {
                .error_bundle => {
                    var error_bundle = try client.receiveErrorBundle(allocator);
                    defer error_bundle.deinit(allocator);
                    try diagnostics_collection.pushErrorBundle(diagnostic_tag, build_file_version, cwd_path, error_bundle);
                    got_errors = true;
                    continue;
                },
                .build_started => {},
                .build_completed => break,
                .build_step_started => {},
                .build_step_completed => {
                    const body = try client.in.takeStruct(std.zig.Server.Message.BuildStepCompleted, .little);

                    const extra = try client.in.readSliceEndianAlloc(allocator, u32, body.error_bundle.extra_len, .little);
                    defer allocator.free(extra);

                    const string_bytes = try client.in.readAlloc(allocator, body.error_bundle.string_bytes_len);
                    defer allocator.free(string_bytes);

                    const error_bundle: std.zig.ErrorBundle = .{ .extra = extra, .string_bytes = string_bytes };

                    try diagnostics_collection.pushErrorBundle(
                        diagnostic_tag,
                        build_file_version,
                        cwd_path,
                        error_bundle,
                    );
                    continue;
                },
                .configuration_file_expired => {}, // TODO
                else => std.log.err("unexpected message: .{t}", .{header.tag}),
            }
            try client.in.discardAll(header.bytes_len);
        }

        // maker.resolveLazyPath()
    }

    // // We collect modules in the following order:
    // // - public modules (`std.Build.addModule`)
    // // - modules that are reachable from the "install" step
    // // - all other reachable modules
    // var modules: std.array_hash_map.String(BuildConfig.Module) = .empty;

    // // for (b.modules.values()) |root_module| {
    // //     const graph = root_module.getGraph();
    // //     for (graph.modules) |module| {
    // //         try helper.processModule(arena, &modules, module, null);
    // //     }
    // // }

    // // We loop twice through all steps so that decendants of the "install" step are processed first.
    // for ([_]bool{ true, false }) |want_install_step_decendant| {
    //     for (all_steps.keys(), all_steps.values()) |step_index, is_install_step_decendant| {
    //         if (is_install_step_decendant != want_install_step_decendant) continue;
    //         const step = step_index.ptr(c);
    //         const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;
    //         // compile.root_module.get(c)
    //         const graph = compile.root_module.getGraph();
    //         for (graph.modules) |module| {
    //             try helper.processModule(arena, &modules, module, compile);
    //         }
    //     }
    // }

    // var compilations: std.ArrayList(BuildConfig.Compile) = .empty;
    // for (all_steps.keys()) |step| {
    //     const compile = step.cast(Configuration.Step.Compile) orelse continue;
    //     const root_source_file = compile.root_module.root_source_file orelse continue;
    //     const root_source_file_path = try std.Io.Dir.path.resolve(arena, &.{ b.graph.cache.cwd, root_source_file.getPath2(compile.root_module.owner, null) });
    //     try compilations.append(arena, .{
    //         .root_module = root_source_file_path,
    //     });
    // }

    if (got_errors) {
        try diagnostics_collection.publishDiagnostics();
    }

    try client.serveMessageHeader(.{ .tag = .exit, .bytes_len = 0 });
    try client.out.flush();

    const term = try child.wait(io);

    if (got_errors or !term.success()) {
        const joined = try std.mem.join(allocator, " ", argv);
        defer allocator.free(joined);
        std.log.err("Failed to collect build system configuration, command:\ncd {f};{s}", .{ cwd, joined });
        return error.RunFailed;
    } else {
        std.debug.print("collected build system configuration\n", .{});
    }

    const arena_allocator = try allocator.create(std.heap.ArenaAllocator);
    arena_allocator.* = .init(allocator);

    return .{
        .arena = arena_allocator,
        .value = .{
            .dependencies = .{ .map = .empty },
            .modules = .{ .map = .empty },
            .compilations = &.{},
            .top_level_steps = &.{},
        },
    };
}

const Maker = struct {
    const Allocator = std.mem.Allocator;
    const Io = std.Io;
    const Dir = std.Io.Dir;
    const Directory = std.Build.Cache.Directory;
    const Path = std.Build.Cache.Path;

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        client: *std.zig.Client,
        cwd: std.Build.Cache.Directory,
        zig_exe_path: []const u8,
    ) !Maker {
        var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const header = try client.in.takeStruct(std.zig.Server.Message.ServerHello, .little);

        // TODO check protocol version

        const configuration_file_path = try client.in.readAlloc(allocator, header.configuration_file_path_len);
        defer allocator.free(configuration_file_path);

        const global_cache_path = try client.in.readAlloc(arena, header.base_paths.global_cache_path_len);
        const local_cache_path = try client.in.readAlloc(arena, header.base_paths.local_cache_path_len);
        const zig_lib_path = try client.in.readAlloc(arena, header.base_paths.zig_lib_path_len);
        const build_root_path = try client.in.readAlloc(arena, header.base_paths.build_root_path_len);
        const install_prefix_path = try client.in.readAlloc(arena, header.base_paths.install_prefix_path_len);
        const install_lib_path = try client.in.readAlloc(arena, header.base_paths.install_lib_path_len);
        const install_bin_path = try client.in.readAlloc(arena, header.base_paths.install_bin_path_len);
        const install_include_path = try client.in.readAlloc(arena, header.base_paths.install_include_path_len);

        const configuration_file = cwd.handle.openFile(io, configuration_file_path, .{}) catch |err| {
            std.log.err("failed to open configuration file {s}: {t}", .{ configuration_file_path, err });
            return err;
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
            .configuration = configuration,
            .top_level_steps = top_level_steps,
            .cwd = cwd.path orelse ".",
            .zig_exe = zig_exe_path,
            .global_cache_root = global_cache_path,
            .local_cache_root = local_cache_path,
            .zig_lib_directory = zig_lib_path,
            .build_root_directory = build_root_path,
            .install_paths = .{
                .prefix = install_prefix_path,
                .lib = install_lib_path,
                .bin = install_bin_path,
                .include = install_include_path,
            },
        };
    }

    fn deinit(config: *Maker, allocator: std.mem.Allocator) void {
        config.arena.promote(allocator).deinit();
    }

    arena: std.heap.ArenaAllocator.State,
    configuration: Configuration,
    top_level_steps: std.array_hash_map.String(Configuration.Step.Index),

    cwd: []const u8,
    zig_exe: []const u8,
    global_cache_root: []const u8,
    local_cache_root: []const u8,
    zig_lib_directory: []const u8,
    build_root_directory: []const u8,
    install_paths: InstallPaths,

    generated_files: std.array_hash_map.Auto(Configuration.GeneratedFileIndex, Path) = .empty,

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
    ) Allocator.Error!?Path {
        const c = &maker.scanned_config.configuration;
        return switch (lazy_path) {
            .source_path => |sp| try packagePath(maker, arena, sp.owner, sp.sub_path.slice(c)),
            .relative => |relative| relativePath(maker, arena, relative),
            .generated => |gen| {
                const base = maker.generated_files.get(gen.index) orelse return null;
                var file_path = base;
                for (0..gen.flags.up) |_| {
                    file_path.sub_path = Dir.path.dirname(file_path.sub_path) orelse {
                        std.log.err(maker, "invalid LazyPath traversal: up {d} times from {f}", .{ gen.flags.up, base });
                        return null;
                    };
                }
                return file_path.join(arena, gen.sub_path.slice(c));
            },
        };
    }

    fn packagePath(
        maker: *const Maker,
        arena: Allocator,
        package_index: Configuration.Package.Index,
        sub_path: []const u8,
    ) Allocator.Error!Path {
        const c = &maker.scanned_config.configuration;
        const package = package_index.get(c) orelse return maker.build_root_directory.join(arena, &.{sub_path});
        return try Dir.path.join(arena, &.{ maker.cwd, package.root_path.slice(c), sub_path });
    }

    fn relativePath(
        maker: *const Maker,
        arena: Allocator,
        relative: Configuration.LazyPath.Relative,
    ) Allocator.Error!Path {
        const c = &maker.scanned_config.configuration;
        const sub_path = relative.sub_path.slice(c);

        return switch (relative.flags.base) {
            .cwd => Dir.path.join(arena, &.{ maker.cwd, sub_path }),
            .zig_exe => {
                if (sub_path.len == 0) return maker.zig_exe;
                return try Dir.path.join(arena, &.{ maker.zig_exe, sub_path });
            },
            .local_cache => maker.local_cache_root.join(arena, &.{sub_path}),
            .global_cache => maker.global_cache_root.join(arena, &.{sub_path}),
            .build_root => maker.build_root_directory.join(arena, &.{sub_path}),
            .zig_lib => maker.zig_lib_directory.join(arena, &.{sub_path}),
            .install_prefix => try maker.install_paths.prefix.join(arena, sub_path),
            .install_lib => try maker.install_paths.lib.join(arena, sub_path),
            .install_bin => try maker.install_paths.bin.join(arena, sub_path),
            .install_include => try maker.install_paths.include.join(arena, sub_path),
        };
    }
};
