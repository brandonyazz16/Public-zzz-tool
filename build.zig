const std = @import("std");

pub fn build(b: *std.Build) void {
    // Windows-only app. On Windows this is just the host target.
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // ---- CEF (Chrome's engine, for the app window). The first build downloads it
    // (tools/fetch_cef.zig) and puts the files the app needs next to the .exe.
    const cef_version = @import("tools/fetch_cef.zig").version;
    const fetch = b.addExecutable(.{ .name = "fetch_cef", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/fetch_cef.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const fetch_run = b.addRunArtifact(fetch);
    fetch_run.addDirectoryArg(b.path("."));
    const cef_files = fetch_run.addOutputDirectoryArg("cef-runtime");
    const cef_root = "third_party/cef/" ++ cef_version;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path(cef_root));
    mod.addCSourceFiles(.{ .files = &.{"src/cef_app.c"}, .flags = &.{ "-std=c11", "-DUNICODE", "-D_UNICODE" } });
    mod.addObjectFile(b.path(cef_root ++ "/Release/libcef.lib"));
    mod.addWin32ResourceFile(.{ .file = b.path("src/app.rc") }); // the app icon
    for ([_][]const u8{ "user32", "comdlg32", "gdi32", "shell32" }) |lib| mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{
        .name = "zzz-zon-tool",
        .root_module = mod,
        .win32_manifest = b.path("src/app.manifest"),
    });
    exe.subsystem = .windows; // no console window behind the app
    exe.step.dependOn(&fetch_run.step);

    // zig-out/bin is a complete, ready-to-run app folder:
    // the .exe, CEF's files, the site and the app's own pages
    b.installArtifact(exe);
    b.installDirectory(.{ .source_dir = cef_files, .install_dir = .bin, .install_subdir = "" });
    b.installDirectory(.{ .source_dir = b.path("site"), .install_dir = .bin, .install_subdir = "site" });
    b.installDirectory(.{ .source_dir = b.path("app_pages"), .install_dir = .bin, .install_subdir = "app_pages" });

    // `zig build run`: runs from the repository folder, so saved data stays in
    // zzz-zon-tool-data/ there, as before
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    // `zig build release`: zig-out/zzz-zon-tool-windows.zip - unzip anywhere and run
    // zzz-zon-tool.exe (made with Windows' built-in tar)
    const pack = b.addExecutable(.{ .name = "package", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/package.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const pack_run = b.addRunArtifact(pack);
    pack_run.step.dependOn(b.getInstallStep());
    pack_run.addDirectoryArg(.{ .relative = .{ .base = .install_bin } });
    pack_run.addDirectoryArg(.{ .relative = .{ .base = .install_prefix } });
    pack_run.has_side_effects = true;
    b.step("release", "Make zig-out/zzz-zon-tool-windows.zip (ready to run)").dependOn(&pack_run.step);

    // `zig build test`: the checker, the save handling, the exe reader and the app's API
    const test_step = b.step("test", "Run the tests");
    for ([_][]const u8{ "src/exe_data.zig", "src/zon_check.zig", "src/game_save.zig", "src/api_test.zig" }) |f| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(f),
            .target = b.graph.host,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
