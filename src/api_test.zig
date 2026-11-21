//! Tests for api.zig (zzz://app/): the site's files and Check file, as the page calls them.
const std = @import("std");
const api = @import("api.zig");

// stand-in for the Windows file picker
export fn zcef_zoom_step(d: c_int) void {
    _ = d;
}
export fn plat_server_start(exe: [*:0]const u8, dir: [*:0]const u8) c_int {
    _ = exe;
    _ = dir;
    return 0;
}
export fn plat_server_running() c_int {
    return 0;
}
export fn plat_server_stop() c_int {
    return 1;
}
export fn plat_launch(exe: [*:0]const u8, dir: [*:0]const u8) c_int {
    _ = exe;
    _ = dir;
    return 0;
}
export fn plat_open_file(filter: [*:0]const u16, out: [*]u8, out_len: c_int) c_int {
    _ = filter;
    _ = out;
    _ = out_len;
    return 0;
}

fn call(path: []const u8, body: []const u8) !struct { status: c_int, data: []const u8, mime: []const u8 } {
    var out: ?[*]u8 = null;
    var len: usize = 0;
    var mime: [*:0]const u8 = "";
    const st = api.zapi_handle(path.ptr, path.len, if (body.len > 0) body.ptr else null, body.len, &out, &len, &mime);
    const data = if (out) |o| o[0..len] else "";
    return .{ .status = st, .data = data, .mime = std.mem.sliceTo(mime, 0) };
}
fn free(d: []const u8) void {
    if (d.len > 0) api.zapi_free(@constCast(d.ptr), d.len);
}

test "site files, and nothing outside them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "site");
    try tmp.dir.createDirPath(io, "pages");
    try tmp.dir.writeFile(io, .{ .sub_path = "site/index.html", .data = "<h1>site</h1>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pages/app.html", .data = "<h1>app</h1>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "no" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const site = try std.fs.path.join(std.testing.allocator, &.{ root, "site" });
    defer std.testing.allocator.free(site);
    const pages = try std.fs.path.join(std.testing.allocator, &.{ root, "pages" });
    defer std.testing.allocator.free(pages);
    api.init(std.testing.allocator, io, site, pages, root);
    defer api.deinit();

    const a = try call("/", "");
    defer free(a.data);
    try std.testing.expectEqualStrings("<h1>site</h1>", a.data);
    try std.testing.expect(std.mem.startsWith(u8, a.mime, "text/html"));
    const b = try call("/app.html?x=1", "");
    defer free(b.data);
    try std.testing.expectEqualStrings("<h1>app</h1>", b.data);
    const c = try call("/../secret.txt", "");
    defer free(c.data);
    try std.testing.expectEqual(@as(c_int, 404), c.status);
    const d = try call("/%2e%2e/secret.txt", "");
    defer free(d.data);
    try std.testing.expectEqual(@as(c_int, 404), d.status);
}

test "Check file through the API: open, fix one, fix all" {
    const io = std.testing.io;
    api.init(std.testing.allocator, io, "site", "pages", ".");
    defer api.deinit();
    const broken =
        \\.{
        \\    .uid = 1,
        \\    .avatars = .{
        \\        .{ .id = 1451, .level = 60 }
        \\    },
        \\}
    ;
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try std.json.Stringify.value(.{ .name = "1.zon", .text = broken }, .{}, &body.writer);
    const r = try call("/api/check/open", body.written());
    defer free(r.data);
    try std.testing.expectEqual(@as(c_int, 200), r.status);
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, r.data, .{});
    defer p.deinit();
    try std.testing.expect(p.value.object.get("open").?.bool);
    try std.testing.expectEqualStrings("1.zon", p.value.object.get("name").?.string);
    const probs = p.value.object.get("problems").?.array.items;
    try std.testing.expect(probs.len > 0);

    const all = try call("/api/check/fixall", "{}");
    defer free(all.data);
    try std.testing.expectEqual(@as(c_int, 200), all.status);
    const t = try call("/api/check/text", "");
    defer free(t.data);
    try std.testing.expect(t.data.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, t.mime, "text/plain"));
    // asking for a problem that isn't there is answered, not a crash
    const bad = try call("/api/check/fix", "{\"i\":9999}");
    defer free(bad.data);
    try std.testing.expectEqual(@as(c_int, 200), bad.status);
    const gs = try call("/api/game/state", "");
    defer free(gs.data);
    try std.testing.expectEqual(@as(c_int, 200), gs.status);
}
