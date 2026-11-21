//! ZZZ .zon Tool: your website in its own window (CEF - Chrome's engine, not Edge), plus the
//! app's own tools that a web page can't have (Check file, Game save, Game data), all served
//! from zzz://app/ - the window's own address, not a network address.
//!
//!   cef_app.c  the window (CEF's C API)
//!   api.zig    everything behind zzz://app/ (site files, app pages, /api/...)

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");

comptime {
    _ = api; // exports zapi_* for cef_app.c
}

extern fn zcef_subprocess() c_int;
extern fn zcef_run(url: [*:0]const u8, data_dir: [*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) @compileError("The app is Windows-only (tests run anywhere: zig build test).");
    // Chrome's helper processes are copies of this .exe: they stop here.
    const code = zcef_subprocess();
    if (code >= 0) std.process.exit(@intCast(code));

    const gpa = init.gpa;
    const io = init.io;
    const site_rel = findSite(io, gpa);
    defer gpa.free(site_rel);
    const site = try std.Io.Dir.cwd().realPathFileAlloc(io, site_rel, gpa);
    defer gpa.free(site);
    const pages = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(site) orelse ".", "app_pages" });
    defer gpa.free(pages);
    // the site's saved builds (its localStorage), zoom, window size, remielle.exe path
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(here);
    const data = try std.fs.path.joinZ(gpa, &.{ here, "zzz-zon-tool-data" });
    defer gpa.free(data);
    std.Io.Dir.cwd().createDirPath(io, data) catch {};

    api.init(gpa, io, site, pages, data);
    defer api.deinit();
    const rc = zcef_run("zzz://app/index.html", data);
    if (rc != 0) std.process.exit(@intCast(rc));
}

/// The site/ folder: in the current folder (zig build run from the repository), or next to
/// the .exe (the ready-to-run zip), or two levels up (zig-out/bin).
fn findSite(io: std.Io, gpa: std.mem.Allocator) []u8 {
    if (std.Io.Dir.cwd().access(io, "site/index.html", .{})) |_| return gpa.dupe(u8, "site") catch @panic("out of memory") else |_| {}
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return gpa.dupe(u8, "site") catch @panic("out of memory");
    defer gpa.free(dir);
    for ([_][]const u8{ "site", "../site", "../../site" }) |c| {
        const p = std.fs.path.join(gpa, &.{ dir, c }) catch continue;
        const idx = std.fs.path.join(gpa, &.{ p, "index.html" }) catch {
            gpa.free(p);
            continue;
        };
        defer gpa.free(idx);
        if (std.Io.Dir.cwd().access(io, idx, .{})) |_| return p else |_| gpa.free(p);
    }
    return gpa.dupe(u8, "site") catch @panic("out of memory");
}
