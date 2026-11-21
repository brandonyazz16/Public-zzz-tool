//! Moving a .zon in and out of the game, safely.
//!
//! Every step runs Remielle's own commands (print-player / pack-player) and
//! nothing in remielle-storage is touched until the new save has been packed
//! AND read back successfully. The old save is always copied to a backup first,
//! and the replace itself is atomic (the file is never half-written).
//!
//! Folder layout (next to remielle.exe):
//!   remielle-storage/players/<id>.bin   the game's save (only ever replaced atomically)
//!   zzz-zon-tool/<id>.zon               working copy of the player file
//!   zzz-zon-tool/backups/<id>-<time>.bin   a copy of every save before it was replaced

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;

pub const players_dir = "remielle-storage" ++ std.fs.path.sep_str ++ "players";
pub const work_dir = "zzz-zon-tool";
pub const backups_dir = work_dir ++ std.fs.path.sep_str ++ "backups";

pub const Game = struct {
    /// absolute path of remielle.exe
    exe: []const u8,
    /// the folder remielle.exe is in
    folder: []const u8,

    fn join(g: Game, a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(a);
        try all.append(a, g.folder);
        try all.appendSlice(a, parts);
        return std.fs.path.join(a, all.items);
    }
};

/// Result of a step: `ok` false means nothing in the game folder was changed.
pub const Outcome = struct {
    ok: bool,
    /// what happened, in plain words (owned by the arena passed in)
    msg: []const u8,
    /// backup file name, when one was made
    backup: ?[]const u8 = null,
};

/// Runs remielle.exe with `args` inside its own folder; returns its exit status and output.
fn runRemielle(a: std.mem.Allocator, io: Io, g: Game, args: []const []const u8) !struct { ok: bool, out: []const u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, g.exe);
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = .{ .path = g.folder },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    const both = try std.mem.concat(a, u8, &.{ r.stderr, r.stdout });
    const trimmed = std.mem.trim(u8, both, " \r\n\t");
    // "Press any key to exit..." is only Remielle's console prompt, not a message
    const clean = if (std.mem.endsWith(u8, trimmed, "Press any key to exit...")) std.mem.trim(u8, trimmed[0 .. trimmed.len - "Press any key to exit...".len], " \r\n\t") else trimmed;
    return .{ .ok = r.term.success(), .out = clean };
}

fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Player ids that have a save (remielle-storage/players/<id>.bin), sorted.
pub fn listPlayers(a: std.mem.Allocator, io: Io, g: Game) ![]u32 {
    const p = try g.join(a, &.{players_dir});
    var d = Dir.cwd().openDir(io, p, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var ids: std.ArrayList(u32) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".bin")) continue;
        const id = std.fmt.parseInt(u32, e.name[0 .. e.name.len - 4], 10) catch continue;
        try ids.append(a, id);
    }
    std.mem.sortUnstable(u32, ids.items, {}, std.sort.asc(u32));
    return ids.items;
}

pub const Printed = struct { out: Outcome, zon: ?[]u8, zon_path: []const u8 };

/// Runs print-player on the game's save and returns the .zon text.
/// Writes only zzz-zon-tool/<id>.zon (the working copy); the save itself is only read.
pub fn printPlayer(a: std.mem.Allocator, io: Io, g: Game, id: u32) !Printed {
    return printPlayerAs(a, io, g, id, "");
}

/// print-player into zzz-zon-tool/<id><suffix>.zon
fn printPlayerAs(a: std.mem.Allocator, io: Io, g: Game, id: u32, suffix: []const u8) !Printed {
    try Dir.cwd().createDirPath(io, try g.join(a, &.{work_dir}));
    const bin_rel = try std.fmt.allocPrint(a, "{s}{s}{d}.bin", .{ players_dir, std.fs.path.sep_str, id });
    const zon_rel = try std.fmt.allocPrint(a, "{s}{s}{d}{s}.zon", .{ work_dir, std.fs.path.sep_str, id, suffix });
    const zon_abs = try g.join(a, &.{zon_rel});
    const r = try runRemielle(a, io, g, &.{ "print-player", bin_rel, try std.fmt.allocPrint(a, "--output={s}", .{zon_rel}) });
    if (!r.ok or !exists(io, zon_abs))
        return .{ .out = .{ .ok = false, .msg = try std.fmt.allocPrint(a, "print-player failed: {s}", .{if (r.out.len > 0) r.out else "no message"}) }, .zon = null, .zon_path = zon_abs };
    const text = try Dir.cwd().readFileAlloc(io, zon_abs, a, .limited(64 << 20));
    return .{ .out = .{ .ok = true, .msg = try std.fmt.allocPrint(a, "Read player {d} from the game.", .{id}) }, .zon = text, .zon_path = zon_abs };
}

/// "Check the save": reads the save as it is now and compares it with what the app packed
/// last. Shows whether something (e.g. the server, when you log out) wrote over it.
pub fn checkSave(a: std.mem.Allocator, io: Io, g: Game, id: u32) !Outcome {
    const sent = Dir.cwd().readFileAlloc(io, try g.join(a, &.{ work_dir, try std.fmt.allocPrint(a, "{d}.packed.zon", .{id}) }), a, .limited(64 << 20)) catch
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Nothing was packed into player {d} from this app yet, so there's nothing to compare with.", .{id}) };
    const now = try printPlayerAs(a, io, g, id, ".now");
    defer Dir.cwd().deleteFile(io, now.zon_path) catch {};
    if (!now.out.ok) return now.out;
    const diff = try describeDiff(a, try compareZon(a, sent, now.zon.?));
    if (diff.len == 0) return .{ .ok = true, .msg = try std.fmt.allocPrint(a, "Player {d}'s save still holds exactly what was packed last.", .{id}) };
    return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Player {d}'s save changed since the last pack (the game/server wrote to it): {s}", .{ id, diff }) };
}

/// One entry of a .zon list (a character, a W-Engine, a disc...), keyed by its section and
/// name, with its text normalized (no indentation, no \r).
const Item = struct { key: []const u8, text: []const u8 };

fn zonItems(a: std.mem.Allocator, text: []const u8) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    var rest: std.ArrayList(u8) = .empty;
    var section: []const u8 = "";
    var cur: ?std.ArrayList(u8) = null;
    var name: []const u8 = "";
    var counts = std.StringHashMap(u32).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trim(u8, line, " \t");
        if (cur == null) {
            if (std.mem.eql(u8, line, "        .{")) {
                cur = .empty;
                name = "";
                continue;
            }
            if (std.mem.startsWith(u8, line, "    .") and !std.mem.startsWith(u8, line, "     ")) {
                const e = std.mem.indexOf(u8, t, " =") orelse t.len;
                section = t[1..e];
            }
            try rest.appendSlice(a, t);
            try rest.append(a, '\n');
            continue;
        }
        if (std.mem.eql(u8, line, "        },")) {
            const base = try std.fmt.allocPrint(a, "{s}: {s}", .{ section, if (name.len > 0) name else "(no name)" });
            const g = try counts.getOrPut(base);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
            const key = if (g.value_ptr.* == 1) base else try std.fmt.allocPrint(a, "{s} #{d}", .{ base, g.value_ptr.* });
            try items.append(a, .{ .key = key, .text = cur.?.items });
            cur = null;
            continue;
        }
        if (name.len == 0) if (std.mem.indexOf(u8, t, ".name = \"")) |i| {
            const v = t[i + 9 ..];
            name = v[0 .. std.mem.indexOfScalar(u8, v, '"') orelse v.len];
        };
        try cur.?.appendSlice(a, t);
        try cur.?.append(a, '\n');
    }
    try items.append(a, .{ .key = "(the rest of the file)", .text = rest.items });
    return items.items;
}

/// Entries that differ between two .zon texts (in either one only, or with different contents).
pub fn compareZon(a: std.mem.Allocator, x: []const u8, y: []const u8) ![]const []const u8 {
    const xi = try zonItems(a, x);
    const yi = try zonItems(a, y);
    var ym = std.StringHashMap([]const u8).init(a);
    for (yi) |e| try ym.put(e.key, e.text);
    var xm = std.StringHashMap(void).init(a);
    var out: std.ArrayList([]const u8) = .empty;
    for (xi) |e| {
        try xm.put(e.key, {});
        const o = ym.get(e.key) orelse {
            try out.append(a, try std.fmt.allocPrint(a, "{s} (missing)", .{e.key}));
            continue;
        };
        if (!std.mem.eql(u8, o, e.text)) try out.append(a, e.key);
    }
    for (yi) |e| if (!xm.contains(e.key)) try out.append(a, try std.fmt.allocPrint(a, "{s} (extra)", .{e.key}));
    return out.items;
}

fn describeDiff(a: std.mem.Allocator, d: []const []const u8) ![]const u8 {
    if (d.len == 0) return "";
    const shown = d[0..@min(d.len, 12)];
    const list = try std.mem.join(a, ", ", shown);
    return if (d.len > shown.len) try std.fmt.allocPrint(a, "{s} and {d} more", .{ list, d.len - shown.len }) else list;
}

/// Backup file name for a save made now: <id>-YYYY-MM-DD_HH-MM-SS.bin (UTC), never an existing name.
fn backupName(a: std.mem.Allocator, io: Io, g: Game, id: u32) ![]const u8 {
    const secs: u64 = @intCast(@max(0, Io.Clock.real.now(io).toSeconds()));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var n: u32 = 0;
    while (true) : (n += 1) {
        const name = if (n == 0)
            try std.fmt.allocPrint(a, "{d}-{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}.bin", .{ id, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() })
        else
            try std.fmt.allocPrint(a, "{d}-{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}-{d}.bin", .{ id, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), n });
        if (!exists(io, try g.join(a, &.{ backups_dir, name }))) return name;
    }
}

/// Copies the current save (if any) into backups. Returns the backup's name, or null if there was no save.
fn backupSave(a: std.mem.Allocator, io: Io, g: Game, id: u32) !?[]const u8 {
    const save = try g.join(a, &.{ players_dir, try std.fmt.allocPrint(a, "{d}.bin", .{id}) });
    if (!exists(io, save)) return null;
    try Dir.cwd().createDirPath(io, try g.join(a, &.{backups_dir}));
    const name = try backupName(a, io, g, id);
    const dest = try g.join(a, &.{ backups_dir, name });
    try Dir.copyFile(Dir.cwd(), save, Dir.cwd(), dest, io, .{ .replace = false });
    // make sure the copy really is a full copy before anything else happens
    const s1 = try Dir.cwd().statFile(io, save, .{});
    const s2 = try Dir.cwd().statFile(io, dest, .{});
    if (s1.size != s2.size) return error.BackupIncomplete;
    return name;
}

/// Packs `zon` into the game's save for player `id`:
///   1. pack-player into a new file (the game's save is untouched)
///   2. print-player on the new file, to prove Remielle can read it back
///   3. copy the current save to backups
///   4. atomically replace the save with the new file
/// Any failure before step 4 leaves the game folder exactly as it was.
pub fn pack(a: std.mem.Allocator, io: Io, g: Game, id: u32, zon: []const u8) !Outcome {
    try Dir.cwd().createDirPath(io, try g.join(a, &.{work_dir}));
    const sep = std.fs.path.sep_str;
    const zon_rel = try std.fmt.allocPrint(a, "{s}{s}{d}.zon", .{ work_dir, sep, id });
    const new_rel = try std.fmt.allocPrint(a, "{s}{s}{d}.new.bin", .{ work_dir, sep, id });
    const verify_rel = try std.fmt.allocPrint(a, "{s}{s}{d}.verify.zon", .{ work_dir, sep, id });
    const new_abs = try g.join(a, &.{new_rel});
    const verify_abs = try g.join(a, &.{verify_rel});
    Dir.cwd().deleteFile(io, new_abs) catch {};
    Dir.cwd().deleteFile(io, verify_abs) catch {};
    defer Dir.cwd().deleteFile(io, new_abs) catch {};
    defer Dir.cwd().deleteFile(io, verify_abs) catch {};

    try Dir.cwd().writeFile(io, .{ .sub_path = try g.join(a, &.{zon_rel}), .data = zon });

    const p = try runRemielle(a, io, g, &.{ "pack-player", zon_rel, try std.fmt.allocPrint(a, "--output={s}", .{new_rel}) });
    if (!p.ok or !exists(io, new_abs))
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Remielle refused the file - nothing was changed.\n{s}", .{if (p.out.len > 0) p.out else "(no message)"}) };
    const st = try Dir.cwd().statFile(io, new_abs, .{});
    if (st.size == 0) return .{ .ok = false, .msg = "pack-player made an empty file - nothing was changed." };

    const v = try runRemielle(a, io, g, &.{ "print-player", new_rel, try std.fmt.allocPrint(a, "--output={s}", .{verify_rel}) });
    if (!v.ok or !exists(io, verify_abs))
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "The packed save couldn't be read back, so it wasn't used - nothing was changed.\n{s}", .{v.out}) };

    // what the new save really holds, compared with what was sent
    const back = Dir.cwd().readFileAlloc(io, verify_abs, a, .limited(64 << 20)) catch "";
    const diff = try describeDiff(a, try compareZon(a, zon, back));

    const backup = backupSave(a, io, g, id) catch |e|
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Couldn't back up the current save ({s}), so it wasn't replaced - nothing was changed.", .{@errorName(e)}) };

    try Dir.cwd().createDirPath(io, try g.join(a, &.{players_dir}));
    const save = try g.join(a, &.{ players_dir, try std.fmt.allocPrint(a, "{d}.bin", .{id}) });
    Dir.copyFile(Dir.cwd(), new_abs, Dir.cwd(), save, io, .{}) catch |e|
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Couldn't replace the save ({s}). The old save is still in place{s}.", .{ @errorName(e), if (backup != null) " and backed up" else "" }), .backup = backup };

    // kept, so "Check the save" can tell later whether something changed it (e.g. the server)
    Dir.cwd().writeFile(io, .{ .sub_path = try g.join(a, &.{ work_dir, try std.fmt.allocPrint(a, "{d}.packed.zon", .{id}) }), .data = zon }) catch {};

    const head = if (backup) |b|
        try std.fmt.allocPrint(a, "Packed into player {d}. The old save was backed up as {s}.", .{ id, b })
    else
        try std.fmt.allocPrint(a, "Packed into player {d} (there was no save before).", .{id});
    return .{
        .ok = true,
        .msg = if (diff.len == 0)
            try std.fmt.allocPrint(a, "{s} Read back from the new save: everything matches what was sent.", .{head})
        else
            try std.fmt.allocPrint(a, "{s}\nRead back from the new save, these are NOT what was sent (Remielle changed or dropped them): {s}", .{ head, diff }),
        .backup = backup,
    };
}

/// Backups for one player, newest first.
pub fn listBackups(a: std.mem.Allocator, io: Io, g: Game, id: u32) ![]const []const u8 {
    var d = Dir.cwd().openDir(io, try g.join(a, &.{backups_dir}), .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    const prefix = try std.fmt.allocPrint(a, "{d}-", .{id});
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, prefix) or !std.mem.endsWith(u8, e.name, ".bin")) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn newer(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .gt;
        }
    }.newer);
    return names.items;
}

/// Puts a backup back as the game's save. The current save is backed up first,
/// so a restore can itself be undone.
pub fn restore(a: std.mem.Allocator, io: Io, g: Game, id: u32, backup: []const u8) !Outcome {
    if (std.mem.indexOfAny(u8, backup, "/\\") != null) return error.BadName;
    const src = try g.join(a, &.{ backups_dir, backup });
    if (!exists(io, src)) return .{ .ok = false, .msg = "That backup is gone - nothing was changed." };
    const current = backupSave(a, io, g, id) catch |e|
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Couldn't back up the current save ({s}) - nothing was changed.", .{@errorName(e)}) };
    try Dir.cwd().createDirPath(io, try g.join(a, &.{players_dir}));
    const save = try g.join(a, &.{ players_dir, try std.fmt.allocPrint(a, "{d}.bin", .{id}) });
    Dir.copyFile(Dir.cwd(), src, Dir.cwd(), save, io, .{}) catch |e|
        return .{ .ok = false, .msg = try std.fmt.allocPrint(a, "Couldn't restore ({s}). The save wasn't changed.", .{@errorName(e)}) };
    return .{
        .ok = true,
        .msg = if (current) |c|
            try std.fmt.allocPrint(a, "Restored {s}. The save it replaced was backed up as {s}.", .{ backup, c })
        else
            try std.fmt.allocPrint(a, "Restored {s}.", .{backup}),
        .backup = current,
    };
}

// ---------------------------------------------------------------- tests
// A stand-in for remielle.exe (a shell script) so the whole flow runs on Linux:
// pack-player copies the .zon to the output unless it contains BAD; print-player copies it back.

const fake_remielle =
    \\#!/bin/sh
    \\cmd="$1"; in="$2"; out="${3#--output=}"
    \\case "$cmd" in
    \\  pack-player) if grep -q BAD "$in"; then echo "$in:1:1: error: expected expression" >&2; exit 1; fi; cp "$in" "$out" ;;
    \\  print-player) if grep -q CORRUPT "$in"; then echo "save file is likely corrupted" >&2; exit 1; fi; cp "$in" "$out" ;;
    \\  *) exit 2 ;;
    \\esac
    \\
;

fn testGame(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Game {
    try tmp.dir.writeFile(io, .{ .sub_path = "remielle", .data = fake_remielle, .flags = .{ .permissions = .executable_file } });
    try tmp.dir.createDirPath(io, players_dir);
    const folder = try tmp.dir.realPathFileAlloc(io, ".", a);
    return .{ .exe = try std.fs.path.join(a, &.{ folder, "remielle" }), .folder = folder };
}

fn readSave(a: std.mem.Allocator, io: Io, g: Game, id: u32) ![]u8 {
    return Dir.cwd().readFileAlloc(io, try g.join(a, &.{ players_dir, try std.fmt.allocPrint(a, "{d}.bin", .{id}) }), a, .limited(1 << 20));
}

test "pack: good file replaces the save and backs up the old one" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try testGame(a, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/1.bin", .data = "OLD SAVE" });

    const printed = try printPlayer(a, io, g, 1);
    try std.testing.expect(printed.out.ok);
    try std.testing.expectEqualStrings("OLD SAVE", printed.zon.?);

    const r = try pack(a, io, g, 1, "NEW SAVE");
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("NEW SAVE", try readSave(a, io, g, 1));
    const bs = try listBackups(a, io, g, 1);
    try std.testing.expectEqual(@as(usize, 1), bs.len);
    try std.testing.expectEqualStrings(r.backup.?, bs[0]);
    try std.testing.expectEqualStrings("OLD SAVE", try Dir.cwd().readFileAlloc(io, try g.join(a, &.{ backups_dir, bs[0] }), a, .limited(1 << 20)));
    // no leftovers
    try std.testing.expect(!exists(io, try g.join(a, &.{ work_dir, "1.new.bin" })));
}

test "pack: a file Remielle rejects changes nothing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try testGame(a, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/1.bin", .data = "OLD SAVE" });

    const r = try pack(a, io, g, 1, "BAD");
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "expected expression") != null);
    try std.testing.expectEqualStrings("OLD SAVE", try readSave(a, io, g, 1));
    try std.testing.expectEqual(@as(usize, 0), (try listBackups(a, io, g, 1)).len);

    // packs fine but can't be read back -> also nothing changed
    const r2 = try pack(a, io, g, 1, "CORRUPT");
    try std.testing.expect(!r2.ok);
    try std.testing.expectEqualStrings("OLD SAVE", try readSave(a, io, g, 1));
}

test "restore: puts a backup back and backs up what it replaced" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try testGame(a, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/1.bin", .data = "FIRST" });

    const r = try pack(a, io, g, 1, "SECOND");
    try std.testing.expect(r.ok);
    const back = try restore(a, io, g, 1, r.backup.?);
    try std.testing.expect(back.ok);
    try std.testing.expectEqualStrings("FIRST", try readSave(a, io, g, 1));
    // the SECOND save was backed up by the restore, so nothing is ever lost
    const bs = try listBackups(a, io, g, 1);
    try std.testing.expectEqual(@as(usize, 2), bs.len);
    var found = false;
    for (bs) |b| {
        const t = try Dir.cwd().readFileAlloc(io, try g.join(a, &.{ backups_dir, b }), a, .limited(1 << 20));
        if (std.mem.eql(u8, t, "SECOND")) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expectError(error.BadName, restore(a, io, g, 1, "../x.bin"));
}

test "players are listed from remielle-storage" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try testGame(a, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/2.bin", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/1.bin", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/notes.txt", .data = "x" });
    const ids = try listPlayers(a, io, g);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, ids);
}

test "compareZon: names the characters that differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x =
        \\.{
        \\    .avatars = .{
        \\        .{
        \\            .name = "Ellen",
        \\            .rank = 6,
        \\        },
        \\        .{
        \\            .name = "Miyabi",
        \\            .rank = 0,
        \\        },
        \\    },
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try compareZon(a, x, x)).len);
    // line endings and indentation don't count
    const crlf = try std.mem.replaceOwned(u8, a, x, "\n", "\r\n");
    try std.testing.expectEqual(@as(usize, 0), (try compareZon(a, x, crlf)).len);
    const y = try std.mem.replaceOwned(u8, a, x, ".rank = 0", ".rank = 2");
    const d = try compareZon(a, x, y);
    try std.testing.expectEqual(@as(usize, 1), d.len);
    try std.testing.expectEqualStrings("avatars: Miyabi", d[0]);
}

test "checkSave: tells when the save changed after packing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try testGame(a, io, &tmp);
    const r = try pack(a, io, g, 1, "NEW SAVE");
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "everything matches") != null);
    try std.testing.expect((try checkSave(a, io, g, 1)).ok);
    // the server writes something else into the save
    try tmp.dir.writeFile(io, .{ .sub_path = players_dir ++ "/1.bin", .data = "SERVER SAVE" });
    const c = try checkSave(a, io, g, 1);
    try std.testing.expect(!c.ok);
    try std.testing.expect(std.mem.indexOf(u8, c.msg, "changed since the last pack") != null);
}
