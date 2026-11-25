//! Everything behind zzz://app/ (the app window's own address - not a network address):
//!   /...            the site's files (site/) and the app's own pages (app_pages/)
//!   /api/check/...  Check file: server-accurate checks and fixes (zon_check.zig)
//!   /api/game/...   Game save: read / pack the save with Remielle's commands (game_save.zig)
//!
//! Called by cef_app.c from CEF's threads; one request at a time (mutex).

const std = @import("std");
const zon_check = @import("zon_check.zig");
const game_save = @import("game_save.zig");
const exe_data = @import("exe_data.zig");
const char_names = @import("data_characters.zon");
const weng_names = @import("data_wengines.zon");

extern fn plat_open_file(filter: [*:0]const u16, out: [*]u8, out_len: c_int) c_int;
/// Ctrl + mouse wheel: one zoom step in (1) or out (-1) - cef_app.c, on the window's thread
extern fn zcef_zoom_step(dir: c_int) void;
/// The Remielle server (cef_app.c): started in its own command window, stopped with Ctrl+C
extern fn plat_server_start(exe: [*:0]const u8, dir: [*:0]const u8) c_int;
extern fn plat_server_running() c_int;
extern fn plat_server_stop() c_int;
/// Starts a program in its own window, from its own folder (the game's launcher)
extern fn plat_launch(exe: [*:0]const u8, dir: [*:0]const u8) c_int;
/// closes the game (everything running from its folder, never the server) and starts it again
extern fn plat_game_restart(exe: [*:0]const u8, dir: [*:0]const u8) c_int;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
var mutex: std.Io.Mutex = .init;
var site_dir: []const u8 = "site";
var pages_dir: []const u8 = "app_pages";
var data_dir: []const u8 = ".";

// Check file session
var c_name: []u8 = &.{};
var c_text: ?[]u8 = null;
var c_original: ?[]u8 = null;
var c_report: ?zon_check.Report = null;
var c_fixes: u32 = 0;

// Game save
var exe_abs: ?[:0]u8 = null;
var folder: []const u8 = "";
var player: u32 = 1;
var tried_default = false;

// Game data read from remielle.exe (kept until another exe is picked)
var d_for: []u8 = &.{};
/// size and change time of the exe when it was read: a rebuilt remielle.exe (same path, e.g.
/// after git pull + zig build) is read again
var d_size: u64 = 0;
var d_mtime: i128 = 0;
var d_chars: ?[]exe_data.Stats = null;
var d_wengs: ?[]exe_data.WEngine = null;
var d_skins: ?[]exe_data.Skin = null;
/// the exe's names (Check file's lists point into it)
var d_names: ?exe_data.Names = null;
var d_error: []const u8 = "";

pub fn init(a: std.mem.Allocator, i: std.Io, site: []const u8, pages: []const u8, data: []const u8) void {
    gpa = a;
    io = i;
    // own copies: the caller's strings may not outlive this call
    site_dir = a.dupe(u8, site) catch site;
    pages_dir = a.dupe(u8, pages) catch pages;
    data_dir = a.dupe(u8, data) catch data;
    owns_dirs = true;
}
var owns_dirs = false;

/// Frees the Check file session and the remembered remielle.exe path (on exit).
pub fn deinit() void {
    gpa.free(c_name);
    c_name = &.{};
    if (c_text) |t| gpa.free(t);
    c_text = null;
    if (c_original) |t| gpa.free(t);
    c_original = null;
    if (c_report) |*r| r.deinit();
    c_report = null;
    if (exe_abs) |e| gpa.free(e);
    exe_abs = null;
    folder = "";
    tried_default = false;
    dropData();
    if (owns_dirs) {
        gpa.free(site_dir);
        gpa.free(pages_dir);
        gpa.free(data_dir);
        owns_dirs = false;
    }
}

// ---------------------------------------------------------------- C entry points

/// Returns the HTTP status; `out` is gpa-allocated (freed by zapi_free).
pub export fn zapi_handle(path_ptr: [*]const u8, path_len: usize, body_ptr: ?[*]const u8, body_len: usize, out: *?[*]u8, out_len: *usize, mime: *[*:0]const u8) c_int {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const path = path_ptr[0..path_len];
    const body: []const u8 = if (body_ptr) |b| b[0..body_len] else "";
    var res: Response = handle(path, body) catch |e| blk: {
        var w: std.Io.Writer.Allocating = .init(gpa);
        w.writer.print("{{\"error\":\"{s}\"}}", .{@errorName(e)}) catch {};
        break :blk .{ .status = 500, .mime = "application/json", .data = w.toOwnedSlice() catch &.{} };
    };
    _ = &res;
    out.* = if (res.data.len > 0) res.data.ptr else null;
    out_len.* = res.data.len;
    mime.* = res.mime;
    return res.status;
}

pub export fn zapi_free(p: ?[*]u8, len: usize) void {
    if (p) |x| gpa.free(x[0..len]);
}

/// File pickers must run on the window's thread.
export fn zapi_needs_ui_thread(path_ptr: [*]const u8, path_len: usize) c_int {
    const p = path_ptr[0..path_len];
    return @intFromBool(std.mem.startsWith(u8, p, "/api/game/pick-") or std.mem.startsWith(u8, p, "/api/game/server-start") or std.mem.startsWith(u8, p, "/api/game/client-start") or std.mem.startsWith(u8, p, "/api/game/client-restart") or std.mem.startsWith(u8, p, "/api/zoom"));
}

const Response = struct { status: c_int = 200, mime: [*:0]const u8 = "application/json", data: []u8 };

fn handle(full: []const u8, body: []const u8) !Response {
    const path = if (std.mem.indexOfScalar(u8, full, '?')) |q| full[0..q] else full;
    if (std.mem.startsWith(u8, path, "/api/")) return api(path[4..], body);
    return file(path);
}

// ---------------------------------------------------------------- files

fn file(raw: []const u8) !Response {
    var buf: [1024]u8 = undefined;
    var path = try urlDecode(&buf, raw);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) path = "/index.html";
    if (std.mem.indexOf(u8, path, "..") != null) return notFound();
    const rel = path[1..];
    // the app's own pages first, then the site
    for ([_][]const u8{ pages_dir, site_dir }) |dir| {
        const full = try std.fs.path.join(gpa, &.{ dir, rel });
        defer gpa.free(full);
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(256 << 20)) catch continue;
        return .{ .mime = mimeOf(rel), .data = data };
    }
    return notFound();
}

fn notFound() !Response {
    return .{ .status = 404, .mime = "text/plain", .data = try gpa.dupe(u8, "Not found") };
}

fn urlDecode(buf: []u8, s: []const u8) ![]const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (o >= buf.len) return error.NameTooLong;
        if (s[i] == '%' and i + 2 < s.len) {
            buf[o] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch '%';
            i += 2;
        } else buf[o] = s[i];
        o += 1;
    }
    return buf[0..o];
}

fn mimeOf(p: []const u8) [*:0]const u8 {
    const ext = std.fs.path.extension(p);
    const map = [_]struct { e: []const u8, m: [*:0]const u8 }{
        .{ .e = ".html", .m = "text/html; charset=utf-8" },  .{ .e = ".js", .m = "text/javascript; charset=utf-8" },
        .{ .e = ".css", .m = "text/css; charset=utf-8" },    .{ .e = ".json", .m = "application/json" },
        .{ .e = ".webp", .m = "image/webp" },                .{ .e = ".png", .m = "image/png" },
        .{ .e = ".jpg", .m = "image/jpeg" },                 .{ .e = ".svg", .m = "image/svg+xml" },
        .{ .e = ".zon", .m = "text/plain; charset=utf-8" }, .{ .e = ".txt", .m = "text/plain; charset=utf-8" },
    };
    for (map) |x| if (std.ascii.eqlIgnoreCase(ext, x.e)) return x.m;
    return "application/octet-stream";
}

// ---------------------------------------------------------------- API

fn json(v: anytype) !Response {
    const data = try std.json.Stringify.valueAlloc(gpa, v, .{});
    return .{ .data = data };
}

fn parse(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, if (body.len == 0) "{}" else body, .{});
}
fn getStr(v: std.json.Value, k: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
}
fn getInt(v: std.json.Value, k: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(k) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn api(path: []const u8, body: []const u8) !Response {
    if (std.mem.eql(u8, path, "/ping")) return json(.{ .app = true });
    if (std.mem.startsWith(u8, path, "/check/")) return check(path[6..], body);
    if (std.mem.startsWith(u8, path, "/game/")) return gameApi(path[5..], body);
    if (std.mem.eql(u8, path, "/data")) return dataApi();
    if (std.mem.eql(u8, path, "/zoom")) {
        const p = try parse(body);
        defer p.deinit();
        const d = getInt(p.value, "d") orelse 0;
        if (d != 0) zcef_zoom_step(if (d > 0) 1 else -1);
        return json(.{ .ok = true });
    }
    return notFound();
}

// ---------------------------------------------------------------- Check file

const ProblemOut = struct {
    i: usize,
    sev: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,
    fix: []const u8,
    manual: bool,
    choices: []const []const u8,
};

fn report(a: std.mem.Allocator, extra: []const u8) !Response {
    var list: std.ArrayList(ProblemOut) = .empty;
    var errors: usize = 0;
    if (c_report) |r| for (r.problems, 0..) |p, i| {
        var ch: std.ArrayList([]const u8) = .empty;
        for (p.choices) |c| try ch.append(a, c.label);
        if (p.sev == .err) errors += 1;
        try list.append(a, .{ .i = i, .sev = if (p.sev == .err) "error" else "check", .line = p.line, .col = p.col, .msg = p.msg, .fix = if (p.fix != null) p.label() else "", .manual = p.manual, .choices = ch.items });
    };
    return json(.{
        .open = c_text != null,
        .name = c_name,
        .size = if (c_text) |t| t.len else 0,
        .errors = errors,
        .problems = list.items,
        .fixes_applied = c_fixes,
        .message = extra,
    });
}

fn setText(new: []const u8) !void {
    loadData(); // Check file uses the names in the user's remielle.exe (if one is picked)
    const copy = try gpa.dupe(u8, new);
    if (c_text) |old| gpa.free(old);
    c_text = copy;
    if (c_report) |*r| r.deinit();
    c_report = null;
    c_report = try zon_check.checkWith(gpa, copy, c_original);
}

fn openText(name: []const u8, text: []const u8) !void {
    gpa.free(c_name);
    c_name = try gpa.dupe(u8, name);
    if (c_original) |o| gpa.free(o);
    c_original = try gpa.dupe(u8, text);
    c_fixes = 0;
    try setText(text);
}

fn check(path: []const u8, body: []const u8) !Response {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, path, "/open")) {
        const p = try parse(body);
        defer p.deinit();
        try openText(getStr(p.value, "name"), getStr(p.value, "text"));
        return report(a, "");
    }
    if (std.mem.eql(u8, path, "/report")) return report(a, "");
    if (std.mem.eql(u8, path, "/text")) {
        return .{ .mime = "text/plain; charset=utf-8", .data = try gpa.dupe(u8, c_text orelse "") };
    }
    if (std.mem.eql(u8, path, "/fix")) {
        const p = try parse(body);
        defer p.deinit();
        const r = c_report orelse return report(a, "Open a file first.");
        const i: usize = @intCast(@max(0, getInt(p.value, "i") orelse -1));
        if (i >= r.problems.len) return report(a, "That problem is gone - the list was refreshed.");
        const pr = r.problems[i];
        const fx = if (getInt(p.value, "choice")) |ci| blk: {
            if (ci < 0 or ci >= pr.choices.len) return report(a, "That choice is gone.");
            break :blk pr.choices[@intCast(ci)].fix;
        } else pr.fix orelse return report(a, "This one has no fix.");
        const out = try zon_check.applyFix(a, c_text.?, fx);
        c_fixes += 1;
        try setText(out);
        return report(a, "Fixed.");
    }
    if (std.mem.eql(u8, path, "/fixall")) {
        const t = c_text orelse return report(a, "Open a file first.");
        const res = try zon_check.fixAllWith(gpa, a, t, c_original);
        c_fixes += res.applied;
        try setText(res.text);
        return report(a, try std.fmt.allocPrint(a, "Fixed {d}. Removals and new characters are never done by Fix all - use their own buttons.", .{res.applied}));
    }
    return notFound();
}

// ---------------------------------------------------------------- Game save

fn game() ?game_save.Game {
    const e = exe_abs orelse return null;
    return .{ .exe = e, .folder = folder };
}

fn setExe(path: []const u8) !void {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    if (exe_abs) |old| gpa.free(old);
    exe_abs = abs;
    folder = std.fs.path.dirname(abs) orelse ".";
    // remembered for next time
    const keep = try std.fs.path.join(gpa, &.{ data_dir, "remielle-path.txt" });
    defer gpa.free(keep);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = keep, .data = abs }) catch {};
}

/// remielle.exe: the one picked last time, else one in the current folder.
fn findExe() void {
    if (tried_default or exe_abs != null) return;
    tried_default = true;
    const keep = std.fs.path.join(gpa, &.{ data_dir, "remielle-path.txt" }) catch return;
    defer gpa.free(keep);
    if (std.Io.Dir.cwd().readFileAlloc(io, keep, gpa, .limited(4096))) |p| {
        defer gpa.free(p);
        const t = std.mem.trim(u8, p, " \r\n");
        if (setExe(t)) |_| return else |_| {}
    } else |_| {}
    setExe("remielle.exe") catch {};
}

fn winErr(rc: c_int) []const u8 {
    return switch (rc) {
        1223 => "you clicked No on Windows' prompt",
        2, 3 => "the file isn't there any more - pick it again",
        5 => "Windows denied access",
        740 => "it needs to run as administrator",
        else => "unexpected",
    };
}

/// The game's launcher: remielle-bootstrap in the CNBetaWin client folder (it starts the beta
/// with thaumiel.dll and needs admin rights), remembered in client-path.txt.
fn clientPath(a: std.mem.Allocator) []const u8 {
    const keep = std.fs.path.join(a, &.{ data_dir, "client-path.txt" }) catch return "";
    const p = std.Io.Dir.cwd().readFileAlloc(io, keep, a, .limited(4096)) catch return "";
    return std.mem.trim(u8, p, " \r\n");
}

fn gameState(a: std.mem.Allocator, msg: []const u8, ok: bool) !Response {
    findExe();
    const g = game();
    const players = if (g) |x| game_save.listPlayers(a, io, x) catch &.{} else &.{};
    if (players.len > 0 and std.mem.indexOfScalar(u32, players, player) == null) player = players[0];
    const backups = if (g) |x| game_save.listBackups(a, io, x, player) catch &.{} else &.{};
    var errors: usize = 0;
    if (c_report) |r| errors = r.errorCount();
    return json(.{
        .exe = if (exe_abs) |e| @as([]const u8, e) else "",
        .folder = folder,
        .players = players,
        .player = player,
        .backups = backups,
        .file_open = c_text != null,
        .file_name = c_name,
        .file_errors = errors,
        .server = plat_server_running() != 0,
        .client = clientPath(a),
        .message = msg,
        .ok = ok,
    });
}

fn gameApi(path: []const u8, body: []const u8) !Response {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, path, "/state")) return gameState(a, "", true);
    if (std.mem.eql(u8, path, "/pick-exe")) {
        var out: [2048]u8 = undefined;
        const filter = std.unicode.utf8ToUtf16LeStringLiteral("remielle.exe\x00remielle.exe\x00Programs (*.exe)\x00*.exe\x00");
        if (plat_open_file(filter, &out, out.len) == 0) return gameState(a, "", true);
        const p = std.mem.sliceTo(&out, 0);
        setExe(p) catch |e| return gameState(a, try std.fmt.allocPrint(a, "Couldn't use that file ({s}).", .{@errorName(e)}), false);
        return gameState(a, "", true);
    }
    if (std.mem.eql(u8, path, "/pick-client")) {
        var out: [2048]u8 = undefined;
        const filter = std.unicode.utf8ToUtf16LeStringLiteral("remielle-bootstrap\x00remielle-bootstrap*.exe\x00Programs (*.exe)\x00*.exe\x00");
        if (plat_open_file(filter, &out, out.len) == 0) return gameState(a, "", true);
        const picked = std.mem.sliceTo(&out, 0);
        if (exe_abs) |e| if (std.mem.eql(u8, picked, e))
            return gameState(a, "That's the server's remielle.exe. Pick the remielle-bootstrap in your CNBetaWin client folder.", false);
        const keep = try std.fs.path.join(a, &.{ data_dir, "client-path.txt" });
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = keep, .data = picked }) catch |e|
            return gameState(a, try std.fmt.allocPrint(a, "Couldn't remember it ({s}).", .{@errorName(e)}), false);
        return gameState(a, "", true);
    }
    if (std.mem.eql(u8, path, "/client-restart")) {
        const c = clientPath(a);
        if (c.len == 0) return gameState(a, "Pick remielle-bootstrap first.", false);
        const exe = try a.dupeSentinel(u8, c, 0);
        const dir = try a.dupeSentinel(u8, std.fs.path.dirname(c) orelse ".", 0);
        const rc = plat_game_restart(exe.ptr, dir.ptr);
        if (rc != 0) return gameState(a, try std.fmt.allocPrint(a, "Couldn't restart the game ({s}, Windows error {d}).", .{ winErr(rc), rc }), false);
        return gameState(a, "Game restarting: closed it, starting remielle-bootstrap again.", true);
    }
    if (std.mem.eql(u8, path, "/client-start")) {
        const c = clientPath(a);
        if (c.len == 0) return gameState(a, "Pick remielle-bootstrap first.", false);
        const exe = try a.dupeSentinel(u8, c, 0);
        const dir = try a.dupeSentinel(u8, std.fs.path.dirname(c) orelse ".", 0);
        const rc = plat_launch(exe.ptr, dir.ptr);
        if (rc != 0) return gameState(a, try std.fmt.allocPrint(a, "Couldn't start the game ({s}, Windows error {d}).", .{ winErr(rc), rc }), false);
        return gameState(a, if (plat_server_running() != 0) "Game started." else "Game started. (The server isn't running from here - start it too if it isn't running yet.)", true);
    }
    const p = try parse(body);
    defer p.deinit();
    if (std.mem.eql(u8, path, "/player")) {
        if (getInt(p.value, "id")) |id| player = @intCast(@max(0, id));
        return gameState(a, "", true);
    }
    const g = game() orelse return gameState(a, "Pick remielle.exe first.", false);
    if (std.mem.eql(u8, path, "/server-start")) {
        if (plat_server_running() != 0) return gameState(a, "The server is already running.", true);
        const dir = try a.dupeSentinel(u8, folder, 0);
        const rc = plat_server_start(exe_abs.?.ptr, dir.ptr);
        if (rc != 0) return gameState(a, try std.fmt.allocPrint(a, "Couldn't start remielle.exe ({s}, Windows error {d}).", .{ winErr(rc), rc }), false);
        return gameState(a, "Server started in its own window.", true);
    }
    if (std.mem.eql(u8, path, "/server-stop")) {
        if (plat_server_running() == 0) return gameState(a, "The server isn't running (from here).", true);
        return if (plat_server_stop() != 0)
            gameState(a, "Server stopped.", true)
        else
            gameState(a, "The server didn't stop (if it runs as administrator, the app can't stop it) - close its window yourself.", false);
    }
    // Packing works with the server running (the guide's way: pack, then log out and back in).
    const relog = " Log out and back in to the game to see it.";
    if (std.mem.eql(u8, path, "/read")) {
        const r = try game_save.printPlayer(a, io, g, player);
        if (!r.out.ok) return gameState(a, r.out.msg, false);
        try openText(std.fs.path.basename(r.zon_path), r.zon.?);
        return gameState(a, r.out.msg, true);
    }
    if (std.mem.eql(u8, path, "/pack")) {
        const t = c_text orelse return gameState(a, "Open or read a file in Check file first.", false);
        if (c_report) |r| if (r.errorCount() > 0) return gameState(a, "Check file still shows errors - a file with errors is never packed.", false);
        const r = try game_save.pack(a, io, g, player, t);
        return gameState(a, if (r.ok) try std.mem.concat(a, u8, &.{ r.msg, relog }) else r.msg, r.ok);
    }
    // the site's .zon editor: its whole file, checked here first (it also shows up in Check
    // file, so any error can be fixed there)
    if (std.mem.eql(u8, path, "/pack-text")) {
        const text = getStr(p.value, "text");
        if (text.len == 0) return gameState(a, "The .zon editor has no file loaded.", false);
        const name = getStr(p.value, "name");
        try openText(if (name.len > 0) name else "zon-editor.zon", text);
        const r = c_report.?;
        const n = r.errorCount();
        if (n > 0) {
            for (r.problems) |pr| if (pr.sev == .err) {
                return gameState(a, try std.fmt.allocPrint(a, "Not packed: the file has {d} error{s} (first: line {d}:{d} {s}). It's open in App tools > Check file to fix.", .{ n, if (n == 1) "" else "s", pr.line, pr.col, pr.msg }), false);
            };
        }
        const res = try game_save.pack(a, io, g, player, c_text.?);
        return gameState(a, if (res.ok) try std.mem.concat(a, u8, &.{ res.msg, relog }) else res.msg, res.ok);
    }
    if (std.mem.eql(u8, path, "/check-save")) {
        const r = try game_save.checkSave(a, io, g, player);
        return gameState(a, r.msg, r.ok);
    }
    if (std.mem.eql(u8, path, "/restore")) {
        const r = try game_save.restore(a, io, g, player, getStr(p.value, "name"));
        return gameState(a, if (r.ok) try std.mem.concat(a, u8, &.{ r.msg, relog }) else r.msg, r.ok);
    }
    return notFound();
}

// ---------------------------------------------------------------- Game data (from remielle.exe)

fn dropData() void {
    if (d_chars) |c| gpa.free(c);
    if (d_wengs) |w| gpa.free(w);
    if (d_skins) |k| gpa.free(k);
    d_chars = null;
    d_wengs = null;
    d_skins = null;
    zon_check.lists = zon_check.builtin_lists;
    if (d_names) |*n| n.deinit();
    d_names = null;
    gpa.free(d_for);
    d_for = &.{};
    d_error = "";
}

/// Reads characters and W-Engines from remielle.exe, once per exe.
fn loadData() void {
    findExe();
    const e = exe_abs orelse return;
    const st = std.Io.Dir.cwd().statFile(io, e, .{}) catch null;
    const size: u64 = if (st) |x| x.size else 0;
    const mtime: i128 = if (st) |x| x.mtime.nanoseconds else 0;
    if (std.mem.eql(u8, d_for, e) and size == d_size and mtime == d_mtime) return;
    dropData();
    d_for = gpa.dupe(u8, e) catch return;
    d_size = size;
    d_mtime = mtime;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, e, gpa, .limited(256 << 20)) catch {
        d_error = "Couldn't read remielle.exe.";
        return;
    };
    defer gpa.free(bytes);
    d_chars = exe_data.decode(gpa, bytes) catch blk: {
        d_error = "That doesn't look like a remielle.exe this app can read.";
        break :blk null;
    };
    d_wengs = exe_data.decodeWEngines(gpa, bytes) catch null;
    d_skins = exe_data.decodeSkins(gpa, bytes) catch null; // older Remielle builds have none
    // Check file's name lists, adapted to this exe
    d_names = exe_data.decodeNames(gpa, bytes) catch null;
    if (d_names) |*n| {
        if (zon_check.adapt(n.arena.allocator(), @as(*const exe_data.Names, n), exe_data.Names.has, n.w_engines, n.discs, n.sections, n.avatars, d_for)) |l| {
            zon_check.lists = l;
        } else |_| {}
    }
}

/// Forms are their own ids in the skin table: Aria 1501 (+1502), Sunbringer 1601 (+1602, 1603, 1606)
fn skinOwner(id: u32) u32 {
    return switch (id) {
        1502 => 1501,
        1602, 1603, 1606 => 1601,
        else => id,
    };
}

fn charName(id: u32) ?[]const u8 {
    inline for (char_names) |c| if (c.id == id) return c.name;
    return null;
}
fn wengName(id: u32) ?[]const u8 {
    inline for (weng_names) |w| if (w.id == id) return w.name;
    return null;
}

const CharOut = struct { id: u32, name: []const u8, skins: []const u32, hp: u32, atk: u32, def: u32, impact: u32, crit_rate: f64, crit_dmg: f64, anomaly_mastery: u32, anomaly_proficiency: u32, energy_regen: ?f64 };
const WengOut = struct { id: u32, name: []const u8, known: bool, rank: []const u8, base_stat: []const u8, base: u32, adv_stat: []const u8, adv: f64, adv_pct: bool };

fn dataApi() !Response {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    loadData();
    var chars: std.ArrayList(CharOut) = .empty;
    if (d_chars) |list| for (list) |c| {
        const name = charName(c.id) orelse continue; // NPC / trial rows the site doesn't know
        var sk: std.ArrayList(u32) = .empty;
        if (d_skins) |ks| for (ks) |k| if (skinOwner(k.owner) == c.id) try sk.append(a, k.id);
        try chars.append(a, .{
            .id = c.id, .name = name, .skins = sk.items, .hp = c.hp, .atk = c.atk, .def = c.def, .impact = c.impact,
            .crit_rate = @as(f64, @floatFromInt(c.crit_rate)) / 100, .crit_dmg = @as(f64, @floatFromInt(c.crit_dmg)) / 100,
            .anomaly_mastery = c.anomaly_mastery, .anomaly_proficiency = c.anomaly_proficiency,
            .energy_regen = if (c.isRupture()) null else @as(f64, @floatFromInt(c.energy_regen)) / 100,
        });
    };
    var wengs: std.ArrayList(WengOut) = .empty;
    if (d_wengs) |list| for (list) |w| {
        const info = exe_data.statName(w.adv_stat);
        const rank: []const u8 = switch (w.rarity()) {
            'S' => "S",
            'A' => "A",
            'B' => "B",
            else => "?",
        };
        try wengs.append(a, .{
            .id = w.id, .name = wengName(w.id) orelse try std.fmt.allocPrint(a, "W-Engine {d}", .{w.id}), .known = wengName(w.id) != null,
            .rank = rank, .base_stat = exe_data.statName(w.base_stat).name, .base = w.base, .adv_stat = info.name,
            .adv = if (info.pct) @as(f64, @floatFromInt(w.adv)) / 100 else @floatFromInt(w.adv), .adv_pct = info.pct,
        });
    };
    return json(.{ .exe = d_for, .error_message = d_error, .has_skins = d_skins != null, .characters = chars.items, .wengines = wengs.items });
}
