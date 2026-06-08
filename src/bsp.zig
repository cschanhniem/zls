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
                continue;
            },
            .server_hello => break try .init(allocator, io, &client, cwd, zig_exe_path),
            else => std.log.err("unexpected message: .{t}", .{header.tag}),
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

        try client.serveBuildSteps(needed_steps.keys());

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
                    const body = try client.in.takeStruct(std.zig.Server.Message.BuildStepCompleted, .little);

                    const eb_extra = try client.in.readSliceEndianAlloc(allocator, u32, body.error_bundle.extra_len, .little);
                    defer allocator.free(eb_extra);

                    const eb_string_bytes = try client.in.readAlloc(allocator, body.error_bundle.string_bytes_len);
                    defer allocator.free(eb_string_bytes);

                    const error_bundle: std.zig.ErrorBundle = .{ .extra = eb_extra, .string_bytes = eb_string_bytes };

                    const generated_file_index = try client.in.readSliceEndianAlloc(allocator, Configuration.GeneratedFileIndex, body.generated_file_count, .little);
                    defer allocator.free(generated_file_index);

                    const generated_file_base = try client.in.readSliceEndianAlloc(allocator, Configuration.Path.Base, body.generated_file_count, .little);
                    defer allocator.free(generated_file_base);

                    const generated_file_sub_path = try client.in.readSliceEndianAlloc(allocator, u32, body.generated_file_count, .little);
                    defer allocator.free(generated_file_sub_path);

                    const string_bytes = try client.in.readAlloc(allocator, body.string_bytes_len);
                    defer allocator.free(string_bytes);

                    for (generated_file_index, generated_file_base, generated_file_sub_path) |gf, base, sub_path| {
                        const path: Configuration.Path.Unpacked = .{
                            .base = base,
                            .sub_path = try arena.dupe(u8, std.mem.sliceTo(string_bytes[sub_path..], 0)),
                        };
                        try maker.generated_files.put(arena, gf, path);
                    }

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

        const global_cache_cwd_path = try client.in.readAlloc(allocator, header.base_paths.global_cache_path_len);
        defer allocator.free(global_cache_cwd_path);

        const local_cache_cwd_path = try client.in.readAlloc(allocator, header.base_paths.local_cache_path_len);
        defer allocator.free(local_cache_cwd_path);

        const zig_lib_cwd_path = try client.in.readAlloc(allocator, header.base_paths.zig_lib_path_len);
        defer allocator.free(zig_lib_cwd_path);

        const build_root_cwd_path = try client.in.readAlloc(allocator, header.base_paths.build_root_path_len);
        defer allocator.free(build_root_cwd_path);

        const install_prefix_cwd_path = try client.in.readAlloc(allocator, header.base_paths.install_prefix_path_len);
        defer allocator.free(install_prefix_cwd_path);

        const install_lib_cwd_path = try client.in.readAlloc(allocator, header.base_paths.install_lib_path_len);
        defer allocator.free(install_lib_cwd_path);

        const install_bin_cwd_path = try client.in.readAlloc(allocator, header.base_paths.install_bin_path_len);
        defer allocator.free(install_bin_cwd_path);

        const install_include_cwd_path = try client.in.readAlloc(allocator, header.base_paths.install_include_path_len);
        defer allocator.free(install_include_cwd_path);

        const global_cache_path = try Dir.path.resolve(arena, &.{ cwd.path.?, global_cache_cwd_path });
        const local_cache_path = try Dir.path.resolve(arena, &.{ cwd.path.?, local_cache_cwd_path });
        const zig_lib_path = try Dir.path.resolve(arena, &.{ cwd.path.?, zig_lib_cwd_path });
        const build_root_path = try Dir.path.resolve(arena, &.{ cwd.path.?, build_root_cwd_path });
        const install_prefix_path = try Dir.path.resolve(arena, &.{ cwd.path.?, install_prefix_cwd_path });
        const install_lib_path = try Dir.path.resolve(arena, &.{ cwd.path.?, install_lib_cwd_path });
        const install_bin_path = try Dir.path.resolve(arena, &.{ cwd.path.?, install_bin_cwd_path });
        const install_include_path = try Dir.path.resolve(arena, &.{ cwd.path.?, install_include_cwd_path });

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
            .arena = arena_allocator,
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
