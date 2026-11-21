//! Build helper: gets CEF (Chrome's engine, for the app window) the first time `zig build`
//! runs, then copies the files the app needs next to the .exe.
//!
//!   fetch_cef <repo-root> <bin-dir>
//!
//! Download: CEF's official build server, checked against its published SHA-1. It uses
//! curl and tar, which are built into Windows 10 / 11 - nothing gets installed.
//! Result: third_party/cef/<version>/ (kept, so later builds don't download again).

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;

pub const version = "cef_binary_156.0.30+g6028375+chromium-156.0.8078.96_windows64_minimal";
const url = "https://cef-builds.spotifycdn.com/cef_binary_156.0.30%2Bg6028375%2Bchromium-156.0.8078.96_windows64_minimal.tar.bz2";
/// SHA-1 of the archive, as published next to it (url + ".sha1")
const sha1_hex = "1fedfc8dd0274caec9183a709ad1ed7856867b91";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const root = args[1];
    const bin = args[2];

    const cef_dir = try std.fs.path.join(gpa, &.{ root, "third_party", "cef" });
    defer gpa.free(cef_dir);
    const dist = try std.fs.path.join(gpa, &.{ cef_dir, version });
    defer gpa.free(dist);
    const marker = try std.fs.path.join(gpa, &.{ dist, ".complete" });
    defer gpa.free(marker);

    if (!exists(io, marker)) {
        try Dir.cwd().createDirPath(io, cef_dir);
        const archive = try std.fs.path.join(gpa, &.{ cef_dir, "cef.tar.bz2" });
        defer gpa.free(archive);
        std.debug.print("Downloading Chrome's engine (CEF 156, about 170 MB) - only the first time...\n", .{});
        try run(gpa, io, &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--output", archive, url }, null);
        std.debug.print("Checking the download...\n", .{});
        try checkSha1(gpa, io, archive);
        std.debug.print("Unpacking...\n", .{});
        try run(gpa, io, &.{ "tar", "-xjf", archive, "-C", cef_dir }, null);
        Dir.cwd().deleteFile(io, archive) catch {};
        trim(gpa, io, dist);
        try Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "ok" });
    }

    // folders unpacked by an older build: trim them once too
    const trimmed = try std.fs.path.join(gpa, &.{ dist, ".trimmed" });
    defer gpa.free(trimmed);
    if (!exists(io, trimmed)) {
        trim(gpa, io, dist);
        Dir.cwd().writeFile(io, .{ .sub_path = trimmed, .data = "ok" }) catch {};
    }

    // the files the app needs, next to the .exe (only copied when missing or changed)
    try Dir.cwd().createDirPath(io, bin);
    // Left out: dxcompiler.dll (WebGPU) and vk_swiftshader / vulkan-1 (software 3D) - the site
    // uses neither, and Chrome falls back to software drawing without them.
    const release = [_][]const u8{ "libcef.dll", "chrome_elf.dll", "d3dcompiler_47.dll", "v8_context_snapshot.bin" };
    for (release) |f| try copyIfChanged(gpa, io, &.{ dist, "Release", f }, &.{ bin, f });
    const resources = [_][]const u8{ "chrome_100_percent.pak", "chrome_200_percent.pak", "resources.pak", "icudtl.dat" };
    for (resources) |f| try copyIfChanged(gpa, io, &.{ dist, "Resources", f }, &.{ bin, f });
    // one language is enough (Chrome's own menus); the site has its own text
    try copyIfChanged(gpa, io, &.{ dist, "Resources", "locales", "en-US.pak" }, &.{ bin, "locales", "en-US.pak" });
}

fn exists(io: Io, p: []const u8) bool {
    Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

fn run(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    _ = cwd;
    const r = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |e| {
        std.debug.print("Couldn't run '{s}' ({s}). It's built into Windows 10 / 11.\n", .{ argv[0], @errorName(e) });
        return e;
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!r.term.success()) {
        std.debug.print("'{s}' failed:\n{s}{s}\n", .{ argv[0], r.stdout, r.stderr });
        return error.CommandFailed;
    }
}

fn checkSha1(gpa: std.mem.Allocator, io: Io, path: []const u8) !void {
    var f = try Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var h = std.crypto.hash.Sha1.init(.{});
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var reader = f.reader(io, buf);
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        h.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var d: [20]u8 = undefined;
    h.final(&d);
    const got = std.fmt.bytesToHex(d, .lower);
    if (!std.mem.eql(u8, &got, sha1_hex)) {
        std.debug.print("The download doesn't match CEF's published checksum (got {s}). Deleted it - run 'zig build' again.\n", .{&got});
        Dir.cwd().deleteFile(io, path) catch {};
        return error.ChecksumMismatch;
    }
}

/// After unpacking: drop what the app never uses (other languages, the sandbox launchers,
/// CEF's own build files) - about 90 MB less on disk.
fn trim(gpa: std.mem.Allocator, io: Io, dist: []const u8) void {
    const gone = [_][]const []const u8{
        &.{ "Release", "bootstrap.exe" },  &.{ "Release", "bootstrapc.exe" }, &.{ "Release", "dxcompiler.dll" },
        &.{ "Release", "vk_swiftshader.dll" }, &.{ "Release", "vulkan-1.dll" }, &.{ "Release", "vk_swiftshader_icd.json" },
    };
    for (gone) |parts| {
        var all: [4][]const u8 = undefined;
        all[0] = dist;
        for (parts, 0..) |x, i| all[i + 1] = x;
        const p = std.fs.path.join(gpa, all[0 .. parts.len + 1]) catch continue;
        defer gpa.free(p);
        Dir.cwd().deleteFile(io, p) catch {};
    }
    for ([_][]const u8{ "libcef_dll", "cmake", "bazel" }) |d| {
        const p = std.fs.path.join(gpa, &.{ dist, d }) catch continue;
        defer gpa.free(p);
        Dir.cwd().deleteTree(io, p) catch {};
    }
    // every language except en-US
    const loc = std.fs.path.join(gpa, &.{ dist, "Resources", "locales" }) catch return;
    defer gpa.free(loc);
    var d = Dir.cwd().openDir(io, loc, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and !std.mem.eql(u8, e.name, "en-US.pak")) names.append(gpa, gpa.dupe(u8, e.name) catch continue) catch {};
    }
    for (names.items) |n| d.deleteFile(io, n) catch {};
}

/// Puts a file in the output folder: a hard link when possible (no second copy on disk),
/// otherwise a copy.
fn copyIfChanged(gpa: std.mem.Allocator, io: Io, from_parts: []const []const u8, to_parts: []const []const u8) !void {
    const from = try std.fs.path.join(gpa, from_parts);
    defer gpa.free(from);
    const to = try std.fs.path.join(gpa, to_parts);
    defer gpa.free(to);
    const a = try Dir.cwd().statFile(io, from, .{});
    if (Dir.cwd().statFile(io, to, .{})) |b| {
        if (a.size == b.size) return;
    } else |_| {}
    if (std.fs.path.dirname(to)) |d| try Dir.cwd().createDirPath(io, d);
    Dir.cwd().deleteFile(io, to) catch {};
    Dir.hardLink(Dir.cwd(), from, Dir.cwd(), to, io, .{}) catch {
        try Dir.copyFile(Dir.cwd(), from, Dir.cwd(), to, io, .{});
    };
}
