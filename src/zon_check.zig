//! Checks a whole Remielle player .zon the way the server does before packing.
//!
//! 1. Syntax: Zig's own .zon parser (std.zig.Ast in .zon mode) - the same parser
//!    family Remielle uses, so messages and line:column match the server.
//!    For a missing `},` it also finds the real cause further up the file.
//! 2. Rules: names checked against the server's lists, refine, Mindscape tab
//!    state, rank/level, disc slots and main stats, substats, Potential.
//!
//! Every problem can carry a Fix that edits the text; fixes are re-checked.

const std = @import("std");
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const names = @import("data_server_names.zon");
/// skin ids per character, from remielle.exe's skin table
const SkinEntry = struct { name: []const u8, skins: []const u32 };
const skins_data: []const SkinEntry = @import("data_skins.zon");

pub const Severity = enum { err, check };

pub const Fix = union(enum) {
    /// insert a line "<ind spaces>}," before `line`
    brace: struct { line: u32, ind: u32 },
    /// insert "," at line:col
    comma: struct { line: u32, col: u32 },
    /// delete `line` (a stray closing brace or a stray ".{")
    delete_line: struct { line: u32 },
    /// insert a line "<ind spaces>.{" before `line`
    open_brace: struct { line: u32, ind: u32 },
    /// append " .{" to the end of `line` (a "= " that lost its ".{")
    append_open: struct { line: u32 },
    /// rename a field on `line`: ".from =" -> ".to ="
    rename_field: struct { line: u32, from: []const u8, to: []const u8 },
    /// insert `text` (a whole line, indent included) before `line`
    insert_line: struct { line: u32, text: []const u8 },
    /// replace the first `from` on `line` with `to` (used for enum values like .locked)
    replace_text: struct { line: u32, from: []const u8, to: []const u8 },
    /// replace the first "from" string on `line` with "to"
    rename: struct { line: u32, from: []const u8, to: []const u8 },
    /// clamp the number after `.refine = ` on `line` to 1..5
    refine: struct { line: u32 },
    /// clamp the number after `.@"+" = ` on `line` to 0..5
    plus: struct { line: u32 },
    /// set `.rank = 6` on `line`
    rank6: struct { line: u32 },
    /// insert `.@"k" = null,` before `line` (a closing brace), indented one level deeper
    add_null: struct { line: u32, k: u8 },
    /// rewrite the 6 tab-state lines after `line` for Mindscape m
    tabs: struct { line: u32, m: u8 },
    /// replace lines first..last (inclusive) with `text` (may be empty = delete them; may hold several lines)
    replace_range: struct { first: u32, last: u32, text: []const u8 },
    /// several edits at once (applied from the bottom of the file up, so line numbers stay right)
    multi: []const Fix,

    pub fn label(f: Fix) []const u8 {
        return switch (f) {
            .brace => "Add the missing },",
            .comma => "Add the comma",
            .delete_line => "Remove the extra line",
            .open_brace => "Add the missing .{",
            .append_open => "Add the missing .{",
            .rename_field => "Fix the field name",
            .insert_line => "Add the missing field",
            .replace_text => "Fix the value",
            .rename => "Fix the spelling",
            .refine => "Clamp to 1-5",
            .plus => "Clamp to 0-5",
            .rank6 => "Set rank 6",
            .add_null => "Add null",
            .tabs => "Fix tab state",
            .replace_range => "Fix",
            .multi => "Fix",
        };
    }
};

/// One option in a pick list (when there is more than one valid answer).
pub const Choice = struct { label: []const u8, fix: Fix };

pub const Problem = struct {
    sev: Severity,
    line: u32, // 1-based
    col: u32, // 1-based
    msg: []const u8,
    /// applied by the Fix button and by Fix all
    fix: ?Fix = null,
    /// other valid answers to pick from (the app shows a list)
    choices: []const Choice = &.{},
    /// label for the Fix button (defaults to fix.label())
    fix_label: ?[]const u8 = null,
    /// only applied when you click it (never by Fix all): removals and additions of whole blocks
    manual: bool = false,

    pub fn label(p: Problem) []const u8 {
        return p.fix_label orelse if (p.fix) |f| f.label() else "";
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    problems: []Problem,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
    }
    pub fn errorCount(r: Report) usize {
        var n: usize = 0;
        for (r.problems) |p| n += @intFromBool(p.sev == .err);
        return n;
    }
};

fn inList(comptime list: anytype, s: []const u8) bool {
    inline for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const main_by_slot = [6][]const []const u8{
    &.{"HP"},
    &.{"ATK"},
    &.{"DEF"},
    &.{ "Percent HP", "Percent ATK", "Percent DEF", "CRIT Rate", "CRIT DMG", "Anomaly Proficiency" },
    &.{ "Percent HP", "Percent ATK", "Percent DEF", "PEN Ratio", "Physical DMG Bonus", "Fire DMG Bonus", "Ice DMG Bonus", "Electric DMG Bonus", "Ether DMG Bonus", "Wind DMG Bonus" },
    &.{ "Percent HP", "Percent ATK", "Percent DEF", "Anomaly Mastery", "Impact", "Energy Regen" },
};
const sub_keys = [_][]const u8{ "HP", "ATK", "DEF", "Percent HP", "Percent ATK", "Percent DEF", "CRIT Rate", "CRIT DMG", "PEN", "Anomaly Proficiency" };

/// A comptime tuple of strings (from a .zon data file) as a slice.
fn toSlice(comptime t: anytype) []const []const u8 {
    comptime {
        var arr: [t.len][]const u8 = undefined;
        for (t, 0..) |x, i| arr[i] = x;
        const fin = arr;
        return &fin;
    }
}
/// The name lists a file is checked against. Built in (from the remielle.exe the app was made
/// with), or adapted to the user's own remielle.exe with `adapt`: names that exe no longer has
/// are dropped, names it has that aren't built in are added.
pub const Lists = struct {
    characters: []const []const u8,
    w_engines: []const []const u8,
    discs: []const []const u8,
    sections: []const []const u8,
    /// character texts in the exe (names and NPCs): an unknown character that's one of these
    /// is only a check, not an error (a new character the built-in list doesn't have yet)
    avatar_texts: []const []const u8 = &.{},
    /// "built-in" or the exe the lists were adapted to
    source: []const u8 = "built-in",
};
pub const builtin_lists: Lists = .{
    .characters = toSlice(names.characters),
    .w_engines = toSlice(names.w_engines),
    .discs = toSlice(names.discs),
    .sections = toSlice(names.sections),
};
/// What checks use right now (set by the app when it reads remielle.exe).
pub var lists: Lists = builtin_lists;

/// Lists adapted to a remielle.exe (`has`: is this text in the exe; `extra_*`: the exe's names).
pub fn adapt(a: std.mem.Allocator, ctx: anytype, has: fn (@TypeOf(ctx), []const u8) bool, extra_w: []const []const u8, extra_d: []const []const u8, extra_s: []const []const u8, avatars: []const []const u8, source: []const u8) !Lists {
    const one = struct {
        fn f(al: std.mem.Allocator, c: @TypeOf(ctx), h: fn (@TypeOf(ctx), []const u8) bool, base: []const []const u8, extra: []const []const u8) ![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (base) |x| if (h(c, x)) {
                try out.append(al, x);
                try seen.put(al, x, {});
            };
            for (extra) |x| if (!seen.contains(x)) {
                try out.append(al, x);
                try seen.put(al, x, {});
            };
            return out.items;
        }
    }.f;
    return .{
        .characters = try one(a, ctx, has, builtin_lists.characters, &.{}),
        .w_engines = try one(a, ctx, has, builtin_lists.w_engines, extra_w),
        .discs = try one(a, ctx, has, builtin_lists.discs, extra_d),
        .sections = try one(a, ctx, has, builtin_lists.sections, extra_s),
        .avatar_texts = avatars,
        .source = source,
    };
}

fn strIn(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const Kind = enum { root, role, time, main_city, avatar, weapon, awake, equipment, disc, disc_id, main_prop, subs, sub };
/// What a field's value has to be. `block` = a .{ ... } struct (its fields are in `child`).
const Ty = enum { block, int, str, bool_, enum_, list_of_blocks, list_of_bools, any };
const FieldDef = struct {
    name: []const u8,
    child: ?Kind = null,
    list: bool = false,
    default: ?[]const u8 = null,
    ty: Ty = .block,
    nullable: bool = false,
    values: ?[]const []const u8 = null,
    /// newer Remielle fields: files made before them don't have them, so no notice when missing
    newer: bool = false,
};

// Allowed enum values, read from remielle.exe.
const days = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
const periods = [_][]const u8{ "morning", "afternoon", "evening", "night" };
const weapon_status = [_][]const u8{ "locked", "unlocked_disabled", "unlocked_enabled" };
const rarities = [_][]const u8{ "s", "a", "b" };
/// Characters with Potential (awake), from remielle.exe's Potential table (levels 1-6 each).
const has_potential = [_][]const u8{ "Nekomata", "Soldier 11", "Koleda", "Lycaon", "Burnice", "Grace", "Ellen", "Harumasa", "Rina", "Jane", "Vivian", "Soldier 0 - Anby", "Ju Fufu" };
/// Names a newer remielle.exe changed (old -> new). Saves made before keep the old ones,
/// which the new server rejects; Fix renames them.
const renames = [_]struct { old: []const u8, new: []const u8 }{
    .{ .old = "Kafka", .new = "Avatar_Female_Size03_Kafka_En" },
    .{ .old = "Robin", .new = "Avatar_Female_Size02_Robin_En" },
    .{ .old = "Elegy of the Spider Molt", .new = "Requiem Araneae" },
    .{ .old = "Starflow Spectrum", .new = "Iridescent Starsong" },
    .{ .old = "Crimson Wing Nocturne", .new = "Bloodwing Nocturne" },
    .{ .old = "Rank Stele", .new = "Monument of the Star" },
};

/// The new name for an old one; disc pieces keep their "[n]" (always written " [n]" now).
fn renamedTo(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    for (renames) |r| {
        if (std.mem.eql(u8, name, r.old)) return r.new;
        if (std.mem.startsWith(u8, name, r.old)) {
            const rest = std.mem.trimStart(u8, name[r.old.len..], " ");
            if (rest.len == 3 and rest[0] == '[' and rest[2] == ']') return try std.fmt.allocPrint(a, "{s} {s}", .{ r.new, rest });
        }
    }
    return null;
}

/// Form names per character, from remielle.exe's text (AvatarForm_Sunbringer_1-3,
/// AvatarVersion_Aria_01-02). Robin has forms too, but their names are temporary - not checked.
const forms = [_]struct { who: []const u8, names: []const []const u8 }{
    .{ .who = "Sunbringer", .names = &.{ "Eldreda", "Lindverne", "Dracaene" } },
    .{ .who = "Aria", .names = &.{ "Idol Projection", "Construct" } },
};
const forms_unchecked = [_][]const u8{"Avatar_Female_Size02_Robin_En"};
/// remielle.exe stops with "too many ... encountered, the limit is 123" when a count reaches 123.
const server_limit = 123;

/// The file's shape, taken from the game's own player file.
fn schemaOf(kind: Kind) []const FieldDef {
    return switch (kind) {
        .root => &.{
            .{ .name = "role", .child = .role },
            .{ .name = "main_city", .child = .main_city },
            .{ .name = "time", .child = .time },
            .{ .name = "avatars", .child = .avatar, .list = true, .ty = .list_of_blocks },
            .{ .name = "weapons_undressed", .child = .weapon, .list = true, .default = ".{}", .ty = .list_of_blocks },
            .{ .name = "equipment_undressed", .child = .disc, .list = true, .default = ".{}", .ty = .list_of_blocks },
            // key and mouse bindings (newer Remielle); its contents are left to the server
            .{ .name = "keymap", .ty = .any, .newer = true },
        },
        .role => &.{ .{ .name = "avatar", .ty = .str }, .{ .name = "control_avatar", .ty = .str }, .{ .name = "control_guise_avatar", .ty = .str } },
        .time => &.{ .{ .name = "day", .ty = .enum_, .values = &days }, .{ .name = "period", .ty = .enum_, .values = &periods } },
        .main_city => &.{.{ .name = "section", .ty = .str }},
        .avatar => &.{
            .{ .name = "name", .ty = .str },
            .{ .name = "level", .default = "60", .ty = .int },
            .{ .name = "rank", .default = "6", .ty = .int },
            .{ .name = "favorite", .default = "false", .ty = .bool_ },
            .{ .name = "unlocked_mindscape", .default = "0", .ty = .int },
            .{ .name = "mindscape_tab_state", .default = ".{ false, false, false, false, false, false }", .ty = .list_of_bools },
            .{ .name = "show_weapon_status", .default = ".locked", .ty = .enum_, .values = &weapon_status },
            .{ .name = "weapon", .child = .weapon, .default = "null", .nullable = true },
            .{ .name = "equipment", .child = .equipment, .default = ".{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null, .@\"5\" = null, .@\"6\" = null }" },
            .{ .name = "awake", .child = .awake, .default = ".{ .level = 0, .enabled = false }" },
            .{ .name = "skin_id", .default = "0", .ty = .int, .newer = true },
            // which form, as text: .form = "Eldreda" (null = none)
            .{ .name = "form", .default = "null", .ty = .str, .nullable = true, .newer = true },
        },
        .weapon => &.{ .{ .name = "name", .ty = .str }, .{ .name = "refine", .default = "1", .ty = .int } },
        .awake => &.{ .{ .name = "level", .default = "0", .ty = .int }, .{ .name = "enabled", .default = "false", .ty = .bool_ } },
        .equipment => &.{
            .{ .name = "1", .child = .disc, .nullable = true }, .{ .name = "2", .child = .disc, .nullable = true }, .{ .name = "3", .child = .disc, .nullable = true },
            .{ .name = "4", .child = .disc, .nullable = true }, .{ .name = "5", .child = .disc, .nullable = true }, .{ .name = "6", .child = .disc, .nullable = true },
        },
        .disc => &.{
            .{ .name = "id", .child = .disc_id },
            .{ .name = "main_property", .child = .main_prop },
            .{ .name = "sub_properties", .child = .subs, .default = ".{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null }" },
        },
        .disc_id => &.{ .{ .name = "name", .ty = .str }, .{ .name = "rarity", .default = ".s", .ty = .enum_, .values = &rarities } },
        .main_prop => &.{.{ .name = "key", .ty = .str }},
        .subs => &.{ .{ .name = "1", .child = .sub, .nullable = true }, .{ .name = "2", .child = .sub, .nullable = true }, .{ .name = "3", .child = .sub, .nullable = true }, .{ .name = "4", .child = .sub, .nullable = true } },
        .sub => &.{ .{ .name = "key", .ty = .str }, .{ .name = "+", .default = "0", .ty = .int } },
    };
}

/// A field name as written in the file: plain identifiers as-is, others as @"...".
fn fieldText(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const plain = name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '_') and for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break false;
    } else true;
    return if (plain) a.dupe(u8, name) else std.fmt.allocPrint(a, "@\"{s}\"", .{name});
}

fn editDistance(x: []const u8, y: []const u8) usize {
    if (x.len > 40 or y.len > 40) return 99;
    var prev: [41]usize = undefined;
    var cur: [41]usize = undefined;
    for (0..y.len + 1) |j| prev[j] = j;
    for (x, 0..) |cx, i| {
        cur[0] = i + 1;
        for (y, 0..) |cy, j| {
            const sub = prev[j] + @intFromBool(std.ascii.toLower(cx) != std.ascii.toLower(cy));
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        @memcpy(prev[0 .. y.len + 1], cur[0 .. y.len + 1]);
    }
    return prev[y.len];
}

/// Like `closest`, but never a field the block already has (renaming to it would duplicate it).
fn closestFree(sc: []const FieldDef, name: []const u8, have: []const Zoir.NullTerminatedString, zoir: *const Zoir) ?[]const u8 {
    var best: ?[]const u8 = null;
    var bd: usize = 99;
    outer: for (sc) |fd| {
        for (have) |h| if (std.mem.eql(u8, h.get(zoir), fd.name)) continue :outer;
        const d = editDistance(name, fd.name);
        if (d < bd) {
            bd = d;
            best = fd.name;
        }
    }
    const limit = @max(@as(usize, 2), name.len / 3);
    return if (bd <= limit) best else null;
}

/// The supported field closest to a misspelled one (a few letters off at most).
fn closest(sc: []const FieldDef, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var bd: usize = 99;
    for (sc) |fd| {
        const d = editDistance(name, fd.name);
        if (d < bd) {
            bd = d;
            best = fd.name;
        }
    }
    const limit = @max(@as(usize, 2), name.len / 3);
    return if (bd <= limit) best else null;
}

/// The tab state for Mindscape m written on one line: .{ true, false, ... }
fn tabsInline(a: std.mem.Allocator, m: u8) ![]const u8 {
    const t6 = tabState(m);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, ".{ ");
    for (t6, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, if (v) "true" else "false");
    }
    try out.appendSlice(a, " }");
    return out.items;
}

/// Each character's block in a player file, by name: from its ".{" line to its "}," line, exactly as written.
fn characterBlocks(a: std.mem.Allocator, src: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var out: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    var i: usize = 0;
    while (i + 1 < lines.items.len) : (i += 1) {
        const open = lines.items[i];
        if (!std.mem.eql(u8, std.mem.trim(u8, open, " "), ".{")) continue;
        const nm_line = std.mem.trim(u8, lines.items[i + 1], " ");
        if (!std.mem.startsWith(u8, nm_line, ".name = \"") or !std.mem.endsWith(u8, nm_line, "\",")) continue;
        const name = nm_line[".name = \"".len .. nm_line.len - 2];
        // the block ends at the next "}," with the same indent as its ".{"
        const ind = indentOf(open);
        var j = i + 1;
        while (j < lines.items.len) : (j += 1) {
            const l = lines.items[j];
            if (indentOf(l) == ind and std.mem.startsWith(u8, std.mem.trim(u8, l, " "), "}")) break;
        }
        if (j >= lines.items.len) continue;
        if (indentOf(lines.items[i + 1]) != ind + 4) continue;
        const text = try std.mem.join(a, "\n", lines.items[i .. j + 1]);
        const last = std.mem.trimEnd(u8, text, " ");
        const fixed = if (last[last.len - 1] == ',') text else try std.fmt.allocPrint(a, "{s},", .{text});
        if (!out.contains(name)) try out.put(a, name, fixed);
        i = j;
    }
    return out;
}

/// A new character block with the game's defaults: level 60, rank 6, M0, nothing equipped.
fn defaultCharacterBlock(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\        .{{
        \\            .name = "{s}",
        \\            .level = 60,
        \\            .rank = 6,
        \\            .favorite = false,
        \\            .unlocked_mindscape = 0,
        \\            .mindscape_tab_state = .{{
        \\                false,
        \\                false,
        \\                false,
        \\                false,
        \\                false,
        \\                false,
        \\            }},
        \\            .show_weapon_status = .locked,
        \\            .weapon = null,
        \\            .equipment = .{{
        \\                .@"1" = null,
        \\                .@"2" = null,
        \\                .@"3" = null,
        \\                .@"4" = null,
        \\                .@"5" = null,
        \\                .@"6" = null,
        \\            }},
        \\            .awake = .{{ .level = 0, .enabled = false }},
        \\        }},
    , .{name});
}

/// Tab state the server expects for Mindscape m: M1-3 fill the first three, M4-6 clear those and fill the last three.
pub fn tabState(m: u8) [6]bool {
    var st: [6]bool = @splat(false);
    for (0..6) |k| st[k] = if (m <= 3) k < m else (k >= 3 and k < m);
    return st;
}

const Checker = struct {
    a: std.mem.Allocator,
    tree: *const Ast,
    zoir: *const Zoir,
    /// the file as it was when it was opened (to notice characters that went missing)
    original: ?[]const u8 = null,
    /// character names in this file
    present: std.StringHashMapUnmanaged(void) = .empty,
    out: std.ArrayList(Problem) = .empty,

    fn loc(c: *Checker, idx: Zoir.Node.Index) struct { line: u32, col: u32 } {
        const tok = c.tree.firstToken(idx.getAstNode(c.zoir));
        const l = c.tree.tokenLocation(0, tok);
        return .{ .line = @intCast(l.line + 1), .col = @intCast(l.column + 1) };
    }
    fn add(c: *Checker, sev: Severity, at: Zoir.Node.Index, fix: ?Fix, comptime fmt: []const u8, args: anytype) !void {
        const l = c.loc(at);
        try c.out.append(c.a, .{ .sev = sev, .line = l.line, .col = l.col, .msg = try std.fmt.allocPrint(c.a, fmt, args), .fix = fix });
    }
    /// line of the closing brace of a struct/array node (last token)
    fn closeLine(c: *Checker, idx: Zoir.Node.Index) u32 {
        const tok = c.tree.lastToken(idx.getAstNode(c.zoir));
        return @intCast(c.tree.tokenLocation(0, tok).line + 1);
    }

    fn field(c: *Checker, s: Zoir.Node.Index, name: []const u8) ?Zoir.Node.Index {
        switch (s.get(c.zoir)) {
            .struct_literal => |st| for (st.names, 0..) |n, i| {
                if (std.mem.eql(u8, n.get(c.zoir), name)) return st.vals.at(@intCast(i));
            },
            else => {},
        }
        return null;
    }
    fn str(c: *Checker, idx: ?Zoir.Node.Index) ?[]const u8 {
        const i = idx orelse return null;
        return switch (i.get(c.zoir)) {
            .string_literal => |s| s,
            else => null,
        };
    }
    fn int(c: *Checker, idx: ?Zoir.Node.Index) ?i64 {
        const i = idx orelse return null;
        return switch (i.get(c.zoir)) {
            .int_literal => |v| switch (v) {
                .small => |x| x,
                .big => null,
            },
            else => null,
        };
    }
    fn isNull(c: *Checker, idx: Zoir.Node.Index) bool {
        return idx.get(c.zoir) == .null;
    }
    fn items(c: *Checker, idx: ?Zoir.Node.Index) ?Zoir.Node.Index.Range {
        const i = idx orelse return null;
        return switch (i.get(c.zoir)) {
            .array_literal => |r| r,
            .empty_literal => .{ .start = i, .len = 0 },
            else => null,
        };
    }

    /// Field name token of the value at `val` in `.name = val`.
    fn nameLoc(c: *Checker, val: Zoir.Node.Index) struct { line: u32, col: u32 } {
        const tok = c.tree.firstToken(val.getAstNode(c.zoir)) - 2;
        const l = c.tree.tokenLocation(0, tok);
        return .{ .line = @intCast(l.line + 1), .col = @intCast(l.column + 1) };
    }

    /// Checks every block against the file's shape: unknown/misspelled fields and missing ones.
    fn shape(c: *Checker, node: Zoir.Node.Index, kind: Kind) error{OutOfMemory}!void {
        const sc = schemaOf(kind);
        switch (node.get(c.zoir)) {
            .struct_literal => |st| {
                for (st.names, 0..) |n, i| {
                    const name = n.get(c.zoir);
                    const val = st.vals.at(@intCast(i));
                    const f = for (sc) |fd| {
                        if (std.mem.eql(u8, fd.name, name)) break fd;
                    } else {
                        // unknown field: same wording as the server, plus the closest valid name
                        var sup: std.ArrayList(u8) = .empty;
                        for (sc, 0..) |fd, k| {
                            if (k > 0) try sup.appendSlice(c.a, ", ");
                            try sup.print(c.a, "'{s}'", .{fd.name});
                        }
                        const best = closestFree(sc, name, st.names, c.zoir);
                        const l = c.nameLoc(val);
                        const fix: ?Fix = if (best) |b| Fix{ .rename_field = .{ .line = l.line, .from = try fieldText(c.a, name), .to = try fieldText(c.a, b) } } else null;
                        try c.out.append(c.a, .{ .sev = .err, .line = l.line, .col = l.col, .fix = fix, .msg = if (best) |b|
                            try std.fmt.allocPrint(c.a, "unexpected field '{s}' (supported: {s}) - did you mean '{s}'?", .{ name, sup.items, b })
                        else
                            try std.fmt.allocPrint(c.a, "unexpected field '{s}' (supported: {s})", .{ name, sup.items }) });
                        continue;
                    };
                    if (!try c.typeOk(val, f)) continue;
                    if (f.child) |ck| try c.shapeValue(val, ck, f.list);
                }
                // missing fields (numbered slots are handled by the slot rules)
                for (sc) |fd| {
                    if (fd.name[0] >= '1' and fd.name[0] <= '9') continue;
                    const have = for (st.names) |n| {
                        if (std.mem.eql(u8, n.get(c.zoir), fd.name)) break true;
                    } else false;
                    if (have or fd.newer) continue;
                    const close_tok = c.tree.lastToken(node.getAstNode(c.zoir));
                    const open_tok = c.tree.firstToken(node.getAstNode(c.zoir));
                    const cl = c.tree.tokenLocation(0, close_tok);
                    const ol = c.tree.tokenLocation(0, open_tok);
                    var fix: ?Fix = null;
                    // only for blocks written over several lines (closing brace on its own line)
                    if (fd.default != null and cl.line != ol.line) {
                        const close_line_text = c.tree.source[cl.line_start..cl.line_end];
                        const ind = indentOf(close_line_text) + 4;
                        fix = .{ .insert_line = .{ .line = @intCast(cl.line + 1), .text = try std.fmt.allocPrint(c.a, "{s}.{s} = {s},", .{ try spaces(c.a, ind), try fieldText(c.a, fd.name), fd.default.? }) } };
                    }
                    const l = c.loc(node);
                    // The game's own file always has it; the server may or may not have a default.
                    try c.out.append(c.a, .{ .sev = .check, .line = l.line, .col = l.col, .fix = fix, .msg = try std.fmt.allocPrint(c.a, "missing field '{s}' (the game's own file always has it){s}", .{ fd.name, if (fix != null) "" else " - add it by hand" }) });
                }
            },
            else => {},
        }
    }
    /// Checks a value's kind against the field (wording like the server's parser).
    fn typeOk(c: *Checker, val: Zoir.Node.Index, f: FieldDef) error{OutOfMemory}!bool {
        const v = val.get(c.zoir);
        if (f.nullable and v == .null) return true;
        const ok = switch (f.ty) {
            .block => v == .struct_literal or v == .empty_literal,
            .int => v == .int_literal,
            .str => v == .string_literal,
            .bool_ => v == .true or v == .false,
            .enum_ => v == .enum_literal,
            .list_of_blocks, .list_of_bools => v == .array_literal or v == .empty_literal,
            .any => true,
        };
        if (ok and f.ty == .enum_ and f.values != null) {
            const ev = v.enum_literal.get(c.zoir);
            if (!strIn(f.values.?, ev)) {
                var sup: std.ArrayList(u8) = .empty;
                for (f.values.?, 0..) |x, k| {
                    if (k > 0) try sup.appendSlice(c.a, ", ");
                    try sup.print(c.a, "'.{s}'", .{x});
                }
                var bd: usize = 99;
                var best: ?[]const u8 = null;
                for (f.values.?) |x| {
                    const dd = editDistance(ev, x);
                    if (dd < bd) {
                        bd = dd;
                        best = x;
                    }
                }
                if (bd > @max(@as(usize, 2), ev.len / 3)) best = null;
                const l = c.loc(val);
                const fix: ?Fix = if (best) |b| Fix{ .replace_text = .{ .line = l.line, .from = try std.fmt.allocPrint(c.a, ".{s}", .{ev}), .to = try std.fmt.allocPrint(c.a, ".{s}", .{b}) } } else null;
                try c.out.append(c.a, .{ .sev = .err, .line = l.line, .col = l.col, .fix = fix, .msg = try std.fmt.allocPrint(c.a, "unexpected enum literal '.{s}' for .{s} (supported: {s}){s}{s}{s}", .{ ev, f.name, sup.items, if (best != null) " - did you mean '." else "", best orelse "", if (best != null) "'?" else "" }) });
            }
            return true;
        }
        if (ok) {
            // elements of lists must have the right kind too
            if (f.ty == .list_of_blocks or f.ty == .list_of_bools) if (c.items(val)) |r| for (0..r.len) |i| {
                const e = r.at(@intCast(i));
                const ev = e.get(c.zoir);
                const eok = if (f.ty == .list_of_blocks) ev == .struct_literal else (ev == .true or ev == .false);
                if (!eok) {
                    const sp = c.span(e);
                    const fx: Fix = if (f.ty == .list_of_bools)
                        .{ .replace_text = .{ .line = sp.first, .from = try c.a.dupe(u8, std.mem.trim(u8, std.mem.trimEnd(u8, lineText(c.tree.source, sp.first), " \r,"), " ")), .to = "false" } }
                    else
                        .{ .replace_range = .{ .first = sp.first, .last = sp.last, .text = "" } };
                    try c.addFull(.err, e, fx, &.{}, if (f.ty == .list_of_blocks) "Remove this entry" else "Set to false", "expected {s} (each entry of .{s} has to be {s})", .{ if (f.ty == .list_of_blocks) "struct" else "bool", f.name, if (f.ty == .list_of_blocks) "a .{ ... } block" else "true or false" });
                }
            };
            return true;
        }
        const want: []const u8 = switch (f.ty) {
            .block => "struct",
            .int => "integer",
            .str => "string",
            .bool_ => "bool",
            .enum_ => "enum literal",
            .list_of_blocks, .list_of_bools => "array",
            .any => "value",
        };
        const how: []const u8 = switch (f.ty) {
            .block => "a .{ ... } block",
            .int => "a whole number",
            .str => "text in quotes",
            .bool_ => "true or false",
            .enum_ => "a name starting with a dot, like .s",
            .list_of_blocks, .list_of_bools => "a .{ ... } list",
            .any => "any value",
        };
        // Fix: turn the value into the right kind when it's clearly meant (a quoted number, a word
        // that should be quoted, a quoted true/false, a bare string for a { .key / .name } block);
        // otherwise use the game's default for that field.
        var new_text: ?[]const u8 = null;
        switch (f.ty) {
            .int => if (v == .string_literal) {
                const t2 = std.mem.trim(u8, v.string_literal, " ");
                if (std.fmt.parseInt(i64, t2, 10)) |_| {
                    new_text = try c.a.dupe(u8, t2);
                } else |_| {}
            },
            .str => switch (v) {
                .enum_literal => |e| new_text = try std.fmt.allocPrint(c.a, "\"{s}\"", .{e.get(c.zoir)}),
                .int_literal => |iv| switch (iv) {
                    .small => |x| new_text = try std.fmt.allocPrint(c.a, "\"{d}\"", .{x}),
                    .big => {},
                },
                else => {},
            },
            .bool_ => if (v == .string_literal) {
                if (std.mem.eql(u8, v.string_literal, "true")) new_text = "true";
                if (std.mem.eql(u8, v.string_literal, "false")) new_text = "false";
            },
            .enum_ => if (v == .string_literal) {
                new_text = try std.fmt.allocPrint(c.a, ".{s}", .{v.string_literal});
            },
            .block => if (v == .string_literal) {
                if (std.mem.eql(u8, f.name, "main_property")) new_text = try std.fmt.allocPrint(c.a, ".{{ .key = \"{s}\" }}", .{v.string_literal});
                if (std.mem.eql(u8, f.name, "id")) new_text = try std.fmt.allocPrint(c.a, ".{{ .name = \"{s}\", .rarity = .s }}", .{v.string_literal});
            },
            else => {},
        }
        if (new_text == null and f.nullable) new_text = "null";
        if (new_text == null) new_text = f.default;
        const fix: ?Fix = if (new_text) |nt| try c.setValue(val, f.name, nt) else null;
        try c.addFull(.err, val, fix, &.{}, if (new_text) |nt| try std.fmt.allocPrint(c.a, "Set to {s}", .{if (nt.len > 40) "the default" else nt}) else null, "expected {s}{s} - .{s} has to be {s}{s}{s}", .{ want, if (f.nullable) " or null" else "", f.name, how, if (f.nullable) " or null" else "", if (fix == null) " - fix it by hand" else "" });
        return false;
    }

    fn shapeValue(c: *Checker, val: Zoir.Node.Index, kind: Kind, list: bool) error{OutOfMemory}!void {
        if (list) {
            const r = c.items(val) orelse return;
            for (0..r.len) |i| try c.shapeValue(r.at(@intCast(i)), kind, false);
            return;
        }
        if (val.get(c.zoir) == .struct_literal) try c.shape(val, kind);
    }

    fn lineOf(c: *Checker, idx: Zoir.Node.Index) u32 {
        return c.loc(idx).line;
    }
    /// first and last line of a node (a whole block when it spans several lines)
    fn span(c: *Checker, idx: Zoir.Node.Index) struct { first: u32, last: u32 } {
        const n = idx.getAstNode(c.zoir);
        return .{ .first = @intCast(c.tree.tokenLocation(0, c.tree.firstToken(n)).line + 1), .last = @intCast(c.tree.tokenLocation(0, c.tree.lastToken(n)).line + 1) };
    }
    /// Lines of a list entry / field value block including the field name line (".@\"3\" = .{").
    fn fieldSpan(c: *Checker, val: Zoir.Node.Index) struct { first: u32, last: u32 } {
        const sp = c.span(val);
        const name_line = c.nameLoc(val).line;
        return .{ .first = @min(name_line, sp.first), .last = sp.last };
    }
    /// Replaces a whole one-line field ".name = <anything>," with ".name = new,".
    fn setValue(c: *Checker, val: Zoir.Node.Index, field_name: []const u8, new_text: []const u8) !?Fix {
        const sp = c.span(val);
        const nl = c.nameLoc(val).line;
        if (sp.first != sp.last or sp.first != nl) {
            // value spans lines: replace the block lines too
            const indent = indentOf(lineText(c.tree.source, nl));
            const last_txt = std.mem.trimEnd(u8, lineText(c.tree.source, sp.last), " \r");
            const comma = if (last_txt.len > 0 and last_txt[last_txt.len - 1] == ',') "," else "";
            return Fix{ .replace_range = .{ .first = nl, .last = sp.last, .text = try std.fmt.allocPrint(c.a, "{s}.{s} = {s}{s}", .{ try spaces(c.a, indent), try fieldText(c.a, field_name), new_text, comma }) } };
        }
        const line_txt = std.mem.trimEnd(u8, lineText(c.tree.source, nl), " \r");
        const prefix = try std.fmt.allocPrint(c.a, ".{s} =", .{try fieldText(c.a, field_name)});
        const ps = std.mem.indexOf(u8, line_txt, prefix) orelse return null;
        // only when the field is alone on its line
        if (std.mem.trim(u8, line_txt[0..ps], " ").len != 0) return null;
        const comma = if (line_txt[line_txt.len - 1] == ',') "," else "";
        return Fix{ .replace_range = .{ .first = nl, .last = nl, .text = try std.fmt.allocPrint(c.a, "{s}{s} {s}{s}", .{ line_txt[0..ps], prefix, new_text, comma }) } };
    }
    /// Closest valid names to a wrong one: the best (if close enough) as the fix, the rest as choices.
    fn suggest(c: *Checker, list: []const []const u8, wrong: []const u8, line: u32, filter_slot: u8) !struct { fix: ?Fix, choices: []Choice } {
        // renamed in a newer Remielle: the fix is the new name
        if (try renamedTo(c.a, wrong)) |to| if (strIn(list, to)) {
            const fx: Fix = .{ .rename = .{ .line = line, .from = try c.a.dupe(u8, wrong), .to = to } };
            const ch = try c.a.alloc(Choice, 1);
            ch[0] = .{ .label = to, .fix = fx };
            return .{ .fix = fx, .choices = ch };
        };
        const Scored = struct { d: usize, s: []const u8 };
        var all: std.ArrayList(Scored) = .empty;
        for (list) |x| {
            if (filter_slot != 0 and !(x.len >= 2 and x[x.len - 1] == ']' and x[x.len - 2] == '0' + filter_slot)) continue;
            try all.append(c.a, .{ .d = editDistance(wrong, x), .s = x });
        }
        std.mem.sort(Scored, all.items, {}, struct {
            fn lt(_: void, p: Scored, q: Scored) bool {
                return p.d < q.d or (p.d == q.d and std.mem.lessThan(u8, p.s, q.s));
            }
        }.lt);
        var choices: std.ArrayList(Choice) = .empty;
        const from = try c.a.dupe(u8, wrong);
        for (all.items[0..@min(all.items.len, 8)]) |x| try choices.append(c.a, .{ .label = x.s, .fix = .{ .rename = .{ .line = line, .from = from, .to = x.s } } });
        const close = all.items.len > 0 and all.items[0].d <= @max(@as(usize, 2), wrong.len / 3);
        return .{ .fix = if (close) choices.items[0].fix else null, .choices = choices.items };
    }
    fn addFull(c: *Checker, sev: Severity, at: Zoir.Node.Index, fix: ?Fix, choices: []const Choice, fix_label: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
        const l = c.loc(at);
        try c.out.append(c.a, .{ .sev = sev, .line = l.line, .col = l.col, .msg = try std.fmt.allocPrint(c.a, fmt, args), .fix = fix, .choices = choices, .fix_label = fix_label, .manual = if (fix) |f| removesBlock(f) else false });
    }

    /// Characters that were in the opened file but aren't now (restored exactly, also by Fix all),
    /// and characters on the server's list that aren't in the file (added with defaults when clicked).
    fn missingCharacters(c: *Checker, avs: Zoir.Node.Index) error{OutOfMemory}!void {
        const close = c.closeLine(avs);
        var restored: std.StringHashMapUnmanaged(void) = .empty;
        if (c.original) |orig| {
            var blocks = try characterBlocks(c.a, orig);
            var it = blocks.iterator();
            while (it.next()) |e| {
                if (c.present.contains(e.key_ptr.*)) continue;
                // renamed by a newer Remielle (Kafka -> Avatar_Female_Size03_Kafka_En): still there
                if (try renamedTo(c.a, e.key_ptr.*)) |nn| if (c.present.contains(nn)) continue;
                try restored.put(c.a, e.key_ptr.*, {});
                try c.addFull(.err, avs, .{ .insert_line = .{ .line = close, .text = e.value_ptr.* } }, &.{}, "Bring it back", "{s} was in the file you opened but is missing now", .{e.key_ptr.*});
            }
        }
        var missing: std.ArrayList([]const u8) = .empty;
        for (lists.characters) |n| if (!c.present.contains(n) and !restored.contains(n)) try missing.append(c.a, n);
        for (missing.items) |n| {
            const l = c.loc(avs);
            try c.out.append(c.a, .{ .sev = .check, .line = l.line, .col = l.col, .manual = true, .fix = .{ .insert_line = .{ .line = close, .text = try defaultCharacterBlock(c.a, n) } }, .fix_label = "Add (level 60, nothing equipped)", .msg = try std.fmt.allocPrint(c.a, "{s} isn't in the file (Remielle has this character)", .{n}) });
        }
    }

    fn run(c: *Checker) !void {
        const root: Zoir.Node.Index = .root;
        try c.shape(root, .root);
        try c.limits(root);
        // role: the player (Belle or Wise) and the character shown as the guise
        if (c.field(root, "role")) |role| {
            inline for (.{ .{ "avatar", "role avatar" }, .{ "control_avatar", "role control avatar" } }) |pair| {
                if (c.field(role, pair[0])) |n| if (c.str(n)) |v| if (!std.mem.eql(u8, v, "Belle") and !std.mem.eql(u8, v, "Wise")) {
                    const sg = try c.suggest(&.{ "Belle", "Wise" }, v, c.lineOf(n), 0);
                    try c.addFull(.err, n, sg.fix orelse sg.choices[0].fix, sg.choices, null, "invalid " ++ pair[1] ++ " name: {s} (has to be \"Belle\" or \"Wise\")", .{v});
                };
            }
            if (c.field(role, "control_guise_avatar")) |n| if (c.str(n)) |v| if (!strIn(lists.characters, v)) {
                const sg = try c.suggest(lists.characters, v, c.lineOf(n), 0);
                try c.addFull(.err, n, sg.fix, sg.choices, null, "invalid role control guise avatar name: {s} (has to be a character name)", .{v});
            };
        }
        if (c.field(root, "main_city")) |mc| if (c.field(mc, "section")) |n| if (c.str(n)) |v| if (!strIn(lists.sections, v)) {
            const sg = try c.suggest(lists.sections, v, c.lineOf(n), 0);
            const vs: Fix = .{ .rename = .{ .line = c.lineOf(n), .from = try c.a.dupe(u8, v), .to = "Video Store" } };
            try c.addFull(.check, n, sg.fix orelse vs, sg.choices, null, "unknown main city section \"{s}\" - \"Video Store\" always works", .{v});
        };
        // A wrong field name makes the rules below report knock-on errors; show only the
        // field errors first (after they're fixed, the rules run on the corrected file).
        for (c.out.items) |p| if (p.sev == .err) return;
        if (root.get(c.zoir) != .struct_literal) return c.add(.err, root, null, "the file has to start with .{{ and a list of fields", .{});
        const avs = c.field(root, "avatars") orelse return c.add(.err, root, null, "missing .avatars (the character list)", .{});
        const list = c.items(avs) orelse return c.add(.err, avs, null, ".avatars has to be a list of characters", .{});

        for (0..list.len) |i| if (c.str(c.field(list.at(@intCast(i)), "name"))) |n| try c.present.put(c.a, n, {});
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        for (0..list.len) |i| try c.avatar(list.at(@intCast(i)), &seen);
        try c.missingCharacters(avs);

        if (c.items(c.field(root, "weapons_undressed"))) |wl| for (0..wl.len) |i| {
            const w = wl.at(@intCast(i));
            if (c.str(c.field(w, "name"))) |n| if (!strIn(lists.w_engines, n)) {
                const nn = c.field(w, "name").?;
                const sg = try c.suggest(lists.w_engines, n, c.lineOf(nn), 0);
                try c.addFull(.err, nn, sg.fix, sg.choices, null, "inventory W-Engine: unknown name \"{s}\"", .{n});
            };
            if (c.field(w, "refine")) |r| if (c.int(r)) |v| if (v < 1 or v > 5)
                try c.add(.err, r, .{ .refine = .{ .line = c.loc(r).line } }, "inventory W-Engine: refine has to be 1-5 (\"invalid refine value\")", .{});
        };
        if (c.items(c.field(root, "equipment_undressed"))) |el| for (0..el.len) |i| {
            const d = el.at(@intCast(i));
            const nm = c.str(if (c.field(d, "id")) |id| c.field(id, "name") else null) orelse "";
            const slot: u8 = if (nm.len >= 3 and nm[nm.len - 1] == ']' and nm[nm.len - 3] == '[') nm[nm.len - 2] -% '0' else 0;
            try c.disc(d, if (slot >= 1 and slot <= 6) slot else 0, "inventory");
        };
    }

    fn avatar(c: *Checker, a: Zoir.Node.Index, seen: *std.StringHashMapUnmanaged(u32)) !void {
        if (a.get(c.zoir) != .struct_literal) {
            const sp = c.span(a);
            return c.addFull(.err, a, .{ .replace_range = .{ .first = sp.first, .last = sp.last, .text = "" } }, &.{}, "Remove this entry", "each character has to be a .{{ ... }} block", .{});
        }
        const nm_node = c.field(a, "name");
        const who = c.str(nm_node) orelse {
            const sp = c.span(a);
            return c.addFull(.err, a, .{ .replace_range = .{ .first = sp.first, .last = sp.last, .text = "" } }, &.{}, "Remove this character block", "character block has no .name", .{});
        };
        if (!strIn(lists.characters, who)) {
            // never suggest a character that's already in the file (that would make a duplicate)
            var free: std.ArrayList([]const u8) = .empty;
            for (lists.characters) |n| if (!c.present.contains(n)) try free.append(c.a, n);
            const sg = try c.suggest(free.items, who, c.lineOf(nm_node.?), 0);
            if (strIn(lists.avatar_texts, who))
                try c.addFull(.check, nm_node.?, null, sg.choices, null, "character \"{s}\" isn't in the app's list, but your remielle.exe has this name - if it's a new character it's fine", .{who})
            else
                try c.addFull(.err, nm_node.?, sg.fix, sg.choices, null, "unknown character \"{s}\" (not in Remielle's character list)", .{who});
        }
        const gop = try seen.getOrPut(c.a, who);
        if (gop.found_existing) {
            // the server rejects the file; keep the first copy, remove this one
            const sp = c.span(a);
            try c.addFull(.err, nm_node.?, .{ .replace_range = .{ .first = sp.first, .last = sp.last, .text = "" } }, &.{}, "Remove this copy", "duplicated avatar {s} (also on line {d}) - the first copy is kept", .{ who, gop.value_ptr.* });
        } else gop.value_ptr.* = c.loc(nm_node.?).line;

        const lv = c.int(c.field(a, "level"));
        const rk = c.int(c.field(a, "rank"));
        if (lv == null or lv.? < 1 or lv.? > 60) {
            const ln = c.field(a, "level");
            const fx: ?Fix = if (ln) |x| try c.setValue(x, "level", try std.fmt.allocPrint(c.a, "{d}", .{std.math.clamp(lv orelse 60, 1, 60)})) else null;
            try c.addFull(.err, ln orelse a, fx, &.{}, "Set a valid level", "{s}: level has to be 1-60", .{who});
        }
        if (rk == null or rk.? < 0 or rk.? > 6) {
            const rn2 = c.field(a, "rank");
            const fx: ?Fix = if (rn2) |x| try c.setValue(x, "rank", "6") else null;
            try c.addFull(.err, rn2 orelse a, fx, &.{}, "Set rank 6", "{s}: rank has to be 0-6", .{who});
        } else if (lv != null and (lv.? != 60 or rk.? != 6)) {
            const rn = c.field(a, "rank").?;
            const both = try c.a.dupe(Fix, &.{ (try c.setValue(c.field(a, "level").?, "level", "60")) orelse Fix{ .rank6 = .{ .line = c.loc(rn).line } }, Fix{ .rank6 = .{ .line = c.loc(rn).line } } });
            try c.addFull(.check, rn, if (lv.? == 60) Fix{ .rank6 = .{ .line = c.loc(rn).line } } else Fix{ .multi = both }, &.{}, if (lv.? == 60) null else "Set level 60, rank 6", "{s}: level {d} with rank {d} - the server rejects some level/rank combinations (\"invalid rank and level combination\"); level 60 with rank 6 always works", .{ who, lv.?, rk.? });
        }

        const um_node = c.field(a, "unlocked_mindscape");
        const ts_node = c.field(a, "mindscape_tab_state");
        const um = c.int(um_node);
        if (um == null or um.? < 0 or um.? > 6) {
            const fx: ?Fix = if (um_node) |x| try c.setValue(x, "unlocked_mindscape", try std.fmt.allocPrint(c.a, "{d}", .{std.math.clamp(um orelse 0, 0, 6)})) else null;
            try c.addFull(.err, um_node orelse a, fx, &.{}, "Set a valid Mindscape", "{s}: unlocked_mindscape has to be 0-6", .{who});
        } else if (c.items(ts_node)) |ts| {
            var ok = ts.len == 6;
            var have: [6]bool = undefined;
            if (ok) for (0..6) |k| switch (ts.at(@intCast(k)).get(c.zoir)) {
                .true => have[k] = true,
                .false => have[k] = false,
                else => ok = false,
            };
            if (!ok) {
                const fx = try c.setValue(ts_node.?, "mindscape_tab_state", try tabsInline(c.a, @intCast(um.?)));
                try c.addFull(.err, ts_node.?, fx, &.{}, "Fix tab state", "{s}: mindscape_tab_state has to be 6 true/false values", .{who});
            } else {
                const want = tabState(@intCast(um.?));
                if (!std.mem.eql(bool, &want, &have)) {
                    var wb: [6]u8 = undefined;
                    var hb: [6]u8 = undefined;
                    for (0..6) |k| {
                        wb[k] = if (want[k]) 'T' else 'F';
                        hb[k] = if (have[k]) 'T' else 'F';
                    }
                    try c.add(.err, ts_node.?, .{ .tabs = .{ .line = c.loc(ts_node.?).line, .m = @intCast(um.?) } }, "{s}: Mindscape M{d} needs tab state {s} but the file has {s} (\"invalid mindscape unlock and tab combination\")", .{ who, um.?, &wb, &hb });
                }
            }
        } else {
            const fx: ?Fix = if (ts_node) |x| try c.setValue(x, "mindscape_tab_state", try tabsInline(c.a, @intCast(std.math.clamp(um orelse 0, 0, 6)))) else null;
            try c.addFull(.err, ts_node orelse a, fx, &.{}, "Fix tab state", "{s}: mindscape_tab_state has to be 6 true/false values", .{who});
        }

        if (c.field(a, "weapon")) |w| switch (w.get(c.zoir)) {
            .null => {},
            .struct_literal => {
                const wn = c.field(w, "name");
                if (c.str(wn)) |n| {
                    if (!strIn(lists.w_engines, n)) {
                        const sg = try c.suggest(lists.w_engines, n, c.lineOf(wn.?), 0);
                        try c.addFull(.err, wn.?, sg.fix, sg.choices, null, "{s}: unknown W-Engine \"{s}\" (not in Remielle's W-Engine list)", .{ who, n });
                    }
                } else try c.addFull(.err, w, try c.setValue(w, "weapon", "null"), &.{}, "Remove the W-Engine (null)", "{s}: W-Engine has no .name", .{who});
                const wr = c.field(w, "refine");
                const v = c.int(wr);
                if (v == null or v.? < 1 or v.? > 5) try c.add(.err, wr orelse w, if (v != null) Fix{ .refine = .{ .line = c.loc(wr.?).line } } else null, "{s}: W-Engine refine has to be 1-5 (\"invalid refine value\")", .{who});
            },
            else => try c.addFull(.err, w, try c.setValue(w, "weapon", "null"), &.{}, "Set to null", "{s}: .weapon has to be null or .{{ .name = ..., .refine = ... }}", .{who}),
        };

        const eq = c.field(a, "equipment");
        if (eq == null or eq.?.get(c.zoir) != .struct_literal) {
            const fx: ?Fix = if (eq) |x| try c.setValue(x, "equipment", ".{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null, .@\"5\" = null, .@\"6\" = null }") else null;
            try c.addFull(.err, eq orelse a, fx, &.{}, "Set empty slots", "{s}: .equipment has to be a block with slots .@\"1\" to .@\"6\"", .{who});
        } else {
            var odd_keys = false;
            for (eq.?.get(c.zoir).struct_literal.names) |n| {
                const k = n.get(c.zoir);
                if (!(k.len == 1 and k[0] >= '1' and k[0] <= '6')) odd_keys = true;
            }
            for (1..7) |s| {
                const key = [_]u8{@intCast('0' + s)};
                if (c.field(eq.?, &key)) |d| {
                    try c.disc(d, @intCast(s), who);
                } else if (!odd_keys) try c.add(.err, eq.?, .{ .add_null = .{ .line = c.closeLine(eq.?), .k = @intCast(s) } }, "{s}: equipment is missing slot .@\"{d}\" (write .@\"{d}\" = null, for an empty slot)", .{ who, s, s });
            }
            const st = eq.?.get(c.zoir).struct_literal;
            for (st.names, 0..) |n, i| {
                const k = n.get(c.zoir);
                if (!(k.len == 1 and k[0] >= '1' and k[0] <= '6')) {
                    const v = st.vals.at(@intCast(i));
                    // rename it to a missing slot if there is one, otherwise remove it
                    var missing: ?u8 = null;
                    for (1..7) |s2| {
                        const key2 = [_]u8{@intCast('0' + s2)};
                        if (c.field(eq.?, &key2) == null) {
                            missing = @intCast(s2);
                            break;
                        }
                    }
                    const fsp = c.fieldSpan(v);
                    const fx: Fix = if (missing) |m| .{ .rename_field = .{ .line = c.nameLoc(v).line, .from = try fieldText(c.a, k), .to = try fieldText(c.a, &[_]u8{'0' + m}) } } else .{ .replace_range = .{ .first = fsp.first, .last = fsp.last, .text = "" } };
                    try c.addFull(.err, v, fx, &.{}, if (missing != null) "Move it to the empty slot" else "Remove it", "{s}: equipment slot \"{s}\" doesn't exist (slots are 1-6)", .{ who, k });
                }
            }
        }

        // skin_id: 0 (no skin) or one of this character's skins
        if (c.field(a, "skin_id")) |sk| if (c.int(sk)) |id| if (id != 0) {
            const mine: []const u32 = for (skins_data) |e| {
                if (std.mem.eql(u8, e.name, who)) break e.skins;
            } else &.{};
            const ok = for (mine) |x| {
                if (x == id) break true;
            } else false;
            if (!ok) {
                var list: std.ArrayList(u8) = .empty;
                for (mine, 0..) |x, k| {
                    if (k > 0) try list.appendSlice(c.a, ", ");
                    try list.print(c.a, "{d}", .{x});
                }
                const owner: ?[]const u8 = for (skins_data) |e| {
                    if (std.mem.indexOfScalar(u32, e.skins, @intCast(@max(0, @min(id, std.math.maxInt(u32)))))) |_| break e.name;
                } else null;
                try c.addFull(.err, sk, try c.setValue(sk, "skin_id", "0"), &.{}, "Set to 0 (no skin)", "{s}: skin_id {d} {s} ({s}: {s})", .{
                    who,                                                                                    id,
                    if (owner) |o| try std.fmt.allocPrint(c.a, "is {s}'s skin, not {s}'s", .{ o, who }) else "isn't a skin in remielle.exe",
                    who,
                    if (mine.len > 0) try std.fmt.allocPrint(c.a, "0 or {s}", .{list.items}) else "only 0 - no skins",
                });
            }
        };

        // form: one of this character's form names, or null
        if (c.field(a, "form")) |fm| if (fm.get(c.zoir) == .string_literal) {
            const v = fm.get(c.zoir).string_literal;
            const known: ?[]const []const u8 = for (forms) |f| {
                if (std.mem.eql(u8, f.who, who)) break f.names;
            } else null;
            if (known) |names_| {
                if (!strIn(names_, v)) {
                    var list: std.ArrayList(u8) = .empty;
                    var best: ?[]const u8 = null;
                    var bd: usize = 99;
                    for (names_, 0..) |x, k| {
                        if (k > 0) try list.appendSlice(c.a, ", ");
                        try list.print(c.a, "\"{s}\"", .{x});
                        const d = editDistance(v, x);
                        if (d < bd) {
                            bd = d;
                            best = x;
                        }
                    }
                    if (bd > @max(@as(usize, 2), v.len / 3)) best = null;
                    const fx: ?Fix = if (best) |b_| Fix{ .replace_text = .{ .line = c.loc(fm).line, .from = try std.fmt.allocPrint(c.a, "\"{s}\"", .{v}), .to = try std.fmt.allocPrint(c.a, "\"{s}\"", .{b_}) } } else try c.setValue(fm, "form", "null");
                    try c.addFull(.err, fm, fx, &.{}, if (best != null) "Use the closest form" else "Set to null", "{s}: form \"{s}\" isn't one of {s}'s forms ({s}, or null)", .{ who, v, who, list.items });
                }
            } else if (!strIn(&forms_unchecked, who)) {
                // not confirmed what the server does here, so only a check
                try c.addFull(.check, fm, try c.setValue(fm, "form", "null"), &.{}, "Set to null", "{s}: form \"{s}\" - {s} has no forms (only Sunbringer, Aria and Robin do)", .{ who, v, who });
            }
        };

        if (c.field(a, "awake")) |aw| {
            const al_node = c.field(aw, "level");
            const al = c.int(al_node);
            const en_node = c.field(aw, "enabled");
            const enabled = if (en_node) |en| en.get(c.zoir) == .true else false;
            const can = strIn(&has_potential, who);
            const max: i64 = if (can) 6 else 0;
            if (al == null or al.? < 0 or al.? > max) {
                const fix: ?Fix = if (al != null and al_node != null) Fix{ .replace_text = .{ .line = c.loc(al_node.?).line, .from = try std.fmt.allocPrint(c.a, ".level = {d}", .{al.?}), .to = try std.fmt.allocPrint(c.a, ".level = {d}", .{std.math.clamp(al.?, 0, max)}) } } else null;
                try c.add(.err, al_node orelse aw, fix, "avatar {s} has an invalid awake level ({d}, expected 0-{d}){s}", .{ who, al orelse -1, max, if (can) "" else " - only 13 characters have Potential (Neko, Soldier 11, Koleda, Lycaon, Burnice, Grace, Ellen, Harumasa, Rina, Jane, Vivian, Soldier 0 - Anby, Ju Fufu)" });
            }
            if (enabled and !can) {
                const l = c.loc(en_node.?);
                try c.add(.err, en_node.?, .{ .replace_text = .{ .line = l.line, .from = ".enabled = true", .to = ".enabled = false" } }, "avatar {s} awake cannot be enabled - {s} has no Potential", .{ who, who });
            } else if (enabled and al != null and al.? == 0) {
                const l = c.loc(en_node.?);
                try c.addFull(.check, en_node.?, .{ .replace_text = .{ .line = l.line, .from = ".enabled = true", .to = ".enabled = false" } }, &.{}, "Disable it", "{s}: Potential is enabled at level 0", .{who});
            }
            if (en_node) |en| switch (en.get(c.zoir)) {
                .true, .false => {},
                else => try c.addFull(.err, en, try c.setValue(en, "enabled", "false"), &.{}, "Set to false", "{s}: awake .enabled has to be true or false", .{who}),
            };
        }
    }

    /// "too many ... encountered, the limit is 123": counts copies of each disc piece (name + rarity),
    /// equipped and in the inventory. Per piece is an error; per set is only a check (not confirmed).
    fn limits(c: *Checker, root: Zoir.Node.Index) error{OutOfMemory}!void {
        var per_piece: std.StringHashMapUnmanaged(u32) = .empty;
        var per_set: std.StringHashMapUnmanaged(u32) = .empty;
        var first_at: std.StringHashMapUnmanaged(Zoir.Node.Index) = .empty;
        // inventory blocks per piece, so extra copies can be removed
        var inv_blocks: std.StringHashMapUnmanaged(std.ArrayList(Zoir.Node.Index)) = .empty;
        const Visit = struct {
            fn disc(cc: *Checker, d: Zoir.Node.Index, pp: *std.StringHashMapUnmanaged(u32), ps: *std.StringHashMapUnmanaged(u32), fa: *std.StringHashMapUnmanaged(Zoir.Node.Index)) error{OutOfMemory}!void {
                if (d.get(cc.zoir) != .struct_literal) return;
                const id = cc.field(d, "id") orelse return;
                const nm = cc.str(cc.field(id, "name")) orelse return;
                const rr = if (cc.field(id, "rarity")) |r| (if (r.get(cc.zoir) == .enum_literal) r.get(cc.zoir).enum_literal.get(cc.zoir) else "?") else "?";
                const key = try std.fmt.allocPrint(cc.a, "{s} .{s}", .{ nm, rr });
                const set_name = if (nm.len > 3 and nm[nm.len - 1] == ']') std.mem.trimEnd(u8, nm[0 .. nm.len - 3], " ") else nm;
                const skey = try std.fmt.allocPrint(cc.a, "{s} .{s}", .{ set_name, rr });
                const g1 = try pp.getOrPut(cc.a, key);
                g1.value_ptr.* = if (g1.found_existing) g1.value_ptr.* + 1 else 1;
                if (!g1.found_existing) try fa.put(cc.a, key, d);
                const g2 = try ps.getOrPut(cc.a, skey);
                g2.value_ptr.* = if (g2.found_existing) g2.value_ptr.* + 1 else 1;
                if (!g2.found_existing) try fa.put(cc.a, skey, d);
            }
        };
        if (c.items(c.field(root, "avatars"))) |al| for (0..al.len) |i| {
            const eq = c.field(al.at(@intCast(i)), "equipment") orelse continue;
            for (1..7) |s| {
                const key = [_]u8{@intCast('0' + s)};
                if (c.field(eq, &key)) |d| try Visit.disc(c, d, &per_piece, &per_set, &first_at);
            }
        };
        if (c.items(c.field(root, "equipment_undressed"))) |el| for (0..el.len) |i| {
            const d = el.at(@intCast(i));
            try Visit.disc(c, d, &per_piece, &per_set, &first_at);
            if (d.get(c.zoir) == .struct_literal) if (c.field(d, "id")) |id| if (c.str(c.field(id, "name"))) |nm| {
                const rr = if (c.field(id, "rarity")) |r| (if (r.get(c.zoir) == .enum_literal) r.get(c.zoir).enum_literal.get(c.zoir) else "?") else "?";
                const g = try inv_blocks.getOrPut(c.a, try std.fmt.allocPrint(c.a, "{s} .{s}", .{ nm, rr }));
                if (!g.found_existing) g.value_ptr.* = .empty;
                try g.value_ptr.append(c.a, d);
            };
        };
        var it = per_piece.iterator();
        while (it.next()) |e| if (e.value_ptr.* >= server_limit) {
            // remove inventory copies (never equipped ones) until the count is under the limit
            var dels: std.ArrayList(Fix) = .empty;
            var extra = e.value_ptr.* - (server_limit - 1);
            if (inv_blocks.get(e.key_ptr.*)) |blocks| {
                var k = blocks.items.len;
                while (k > 0 and extra > 0) : (extra -= 1) {
                    k -= 1;
                    const sp = c.span(blocks.items[k]);
                    try dels.append(c.a, .{ .replace_range = .{ .first = sp.first, .last = sp.last, .text = "" } });
                }
            }
            try c.addFull(.err, first_at.get(e.key_ptr.*).?, if (dels.items.len > 0) Fix{ .multi = dels.items } else null, &.{}, "Remove the extra inventory copies", "too many {s} encountered, the limit is {d} (this file has {d})", .{ e.key_ptr.*, server_limit, e.value_ptr.* });
        };
        var it2 = per_set.iterator();
        while (it2.next()) |e| if (e.value_ptr.* >= server_limit)
            try c.add(.check, first_at.get(e.key_ptr.*).?, null, "{d} discs of {s} - the server has a limit of {d} somewhere for discs; if packing says \"too many ... encountered\", remove some", .{ e.value_ptr.*, e.key_ptr.*, server_limit });
    }

    fn disc(c: *Checker, d: Zoir.Node.Index, slot: u8, who: []const u8) !void {
        if (c.isNull(d)) return;
        if (d.get(c.zoir) != .struct_literal) return c.addFull(.err, d, try c.setValue(d, &[_]u8{'0' + @max(slot, 1)}, "null"), &.{}, "Empty this slot (null)", "{s} slot {d}: has to be null or a disc block", .{ who, slot });
        const id = c.field(d, "id");
        const nm_node = if (id) |x| c.field(x, "name") else null;
        if (c.str(nm_node)) |v| {
            if (!strIn(lists.discs, v)) {
                // the server spells some slots with no space before the bracket, others with one
                var alt_buf: [128]u8 = undefined;
                const alt: ?[]const u8 = blk: {
                    if (v.len < 4 or v[v.len - 1] != ']' or v[v.len - 3] != '[') break :blk null;
                    const base = v[0 .. v.len - 3];
                    const tail = v[v.len - 3 ..];
                    if (base.len > 0 and base[base.len - 1] == ' ')
                        break :blk std.fmt.bufPrint(&alt_buf, "{s}{s}", .{ base[0 .. base.len - 1], tail }) catch null
                    else
                        break :blk std.fmt.bufPrint(&alt_buf, "{s} {s}", .{ base, tail }) catch null;
                };
                if (alt != null and strIn(lists.discs, alt.?)) {
                    const to = try c.a.dupe(u8, alt.?);
                    try c.add(.err, nm_node.?, .{ .rename = .{ .line = c.loc(nm_node.?).line, .from = try c.a.dupe(u8, v), .to = to } }, "{s} slot {d}: invalid equipment name \"{s}\" - the server spells it \"{s}\"", .{ who, slot, v, to });
                } else {
                    const sg = try c.suggest(lists.discs, v, c.lineOf(nm_node.?), slot);
                    try c.addFull(.err, nm_node.?, sg.fix, sg.choices, null, "{s} slot {d}: invalid equipment name \"{s}\" (not in Remielle's disc list)", .{ who, slot, v });
                }
            }
            if (slot != 0 and v.len >= 3 and v[v.len - 1] == ']' and v[v.len - 2] != '0' + slot) {
                // same set, right slot, spelled the server's way
                const base = std.mem.trimEnd(u8, v[0 .. v.len - 3], " ");
                var b1: [160]u8 = undefined;
                var b2: [160]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "{s} [{d}]", .{ base, slot }) catch v;
                const s2 = std.fmt.bufPrint(&b2, "{s}[{d}]", .{ base, slot }) catch v;
                const right: ?[]const u8 = if (strIn(lists.discs, s1)) s1 else if (strIn(lists.discs, s2)) s2 else null;
                const fx: ?Fix = if (right) |r| Fix{ .rename = .{ .line = c.lineOf(nm_node.?), .from = try c.a.dupe(u8, v), .to = try c.a.dupe(u8, r) } } else null;
                try c.addFull(.err, nm_node.?, fx, &.{}, if (right != null) "Use the slot's piece of this set" else null, "{s} slot {d}: \"{s}\" is a slot {c} disc", .{ who, slot, v, v[v.len - 2] });
            }
        } else try c.addFull(.err, d, try c.setValue(d, &[_]u8{'0' + @max(slot, 1)}, "null"), &.{}, "Empty this slot (null)", "{s} slot {d}: disc has no .id .name", .{ who, slot });

        if (id) |x| if (c.field(x, "rarity")) |r| switch (r.get(c.zoir)) {
            .enum_literal => |e| {
                const s = e.get(c.zoir);
                if (!(std.mem.eql(u8, s, "s") or std.mem.eql(u8, s, "a") or std.mem.eql(u8, s, "b")))
                    try c.addFull(.err, r, .{ .replace_text = .{ .line = c.lineOf(r), .from = try std.fmt.allocPrint(c.a, ".rarity = .{s}", .{s}), .to = ".rarity = .s" } }, &.{}, "Set rarity .s", "{s} slot {d}: rarity has to be .s, .a or .b", .{ who, slot });
            },
            else => try c.add(.err, r, null, "{s} slot {d}: rarity has to be .s, .a or .b", .{ who, slot }),
        };

        const mk_node = if (c.field(d, "main_property")) |mp| c.field(mp, "key") else null;
        const mk = c.str(mk_node);
        if (mk == null) {
            // offer every main stat this slot can have; slots 1-3 have only one
            var ch: std.ArrayList(Choice) = .empty;
            const mp_node = c.field(d, "main_property");
            if (slot != 0) if (mp_node) |mp| for (main_by_slot[slot - 1]) |k| {
                if (try c.setValue(mp, "main_property", try std.fmt.allocPrint(c.a, ".{{ .key = \"{s}\" }}", .{k}))) |fx| try ch.append(c.a, .{ .label = k, .fix = fx });
            };
            try c.addFull(.err, d, if (slot != 0 and slot <= 3 and ch.items.len > 0) ch.items[0].fix else null, ch.items, null, "{s} slot {d}: disc has no main stat key{s}", .{ who, slot, if (ch.items.len > 0 and slot > 3) " - pick one" else "" });
        } else if (slot != 0 and !strIn(main_by_slot[slot - 1], mk.?)) {
            const sev: Severity = if (slot > 3) .check else .err;
            var ch: std.ArrayList(Choice) = .empty;
            // In the inventory the slot comes from the name. HP/ATK/DEF only roll on slots 1/2/3,
            // so for those the name is the part that's wrong: offer the right piece of the set first.
            const implied: u8 = if (std.mem.eql(u8, mk.?, "HP")) 1 else if (std.mem.eql(u8, mk.?, "ATK")) 2 else if (std.mem.eql(u8, mk.?, "DEF")) 3 else 0;
            if (std.mem.eql(u8, who, "inventory") and implied != 0) if (c.str(nm_node)) |v| if (v.len >= 3 and v[v.len - 1] == ']') {
                const base = std.mem.trimEnd(u8, v[0 .. v.len - 3], " ");
                var b1: [160]u8 = undefined;
                var b2: [160]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "{s} [{d}]", .{ base, implied }) catch v;
                const s2 = std.fmt.bufPrint(&b2, "{s}[{d}]", .{ base, implied }) catch v;
                if (if (strIn(lists.discs, s1)) s1 else if (strIn(lists.discs, s2)) s2 else null) |right|
                    try ch.append(c.a, .{ .label = try std.fmt.allocPrint(c.a, "It's a slot {d} disc: {s}", .{ implied, right }), .fix = .{ .rename = .{ .line = c.lineOf(nm_node.?), .from = try c.a.dupe(u8, v), .to = try c.a.dupe(u8, right) } } });
            };
            // If a substat already has this main stat, the disc can't really be that slot: fix the main stat instead.
            var sub_has_main = false;
            if (c.field(d, "sub_properties")) |spp| for (1..5) |k| {
                const key = [_]u8{@intCast('0' + k)};
                if (c.field(spp, &key)) |sx| if (c.str(c.field(sx, "key"))) |sk| if (std.mem.eql(u8, sk, mk.?)) {
                    sub_has_main = true;
                };
            };
            if (sub_has_main and ch.items.len > 0) ch.items.len = 0;
            for (main_by_slot[slot - 1]) |k| try ch.append(c.a, .{ .label = k, .fix = .{ .rename = .{ .line = c.lineOf(mk_node.?), .from = try c.a.dupe(u8, mk.?), .to = k } } });
            try c.addFull(sev, mk_node.?, if (slot <= 3) ch.items[0].fix else null, ch.items, null, "{s} slot {d}: main stat \"{s}\" can't roll on slot {d}{s}", .{ who, slot, mk.?, slot, if (slot > 3) " - pick one" else "" });
        }

        const sp = c.field(d, "sub_properties") orelse {
            const dsp = c.span(d);
            const ind = indentOf(lineText(c.tree.source, dsp.last)) + 4;
            const fx: ?Fix = if (dsp.first != dsp.last) Fix{ .insert_line = .{ .line = dsp.last, .text = try std.fmt.allocPrint(c.a, "{s}.sub_properties = .{{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null }},", .{try spaces(c.a, ind)}) } } else null;
            return c.addFull(.err, d, fx, &.{}, "Add empty substats", "{s} slot {d}: disc has no .sub_properties block", .{ who, slot });
        };
        if (sp.get(c.zoir) != .struct_literal and sp.get(c.zoir) != .empty_literal) return c.addFull(.err, sp, try c.setValue(sp, "sub_properties", ".{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null }"), &.{}, "Set empty substats", "{s} slot {d}: .sub_properties has to be a block", .{ who, slot });
        var keys: [4][]const u8 = undefined;
        var nk: usize = 0;
        var plus: i64 = 0;
        for (1..5) |k| {
            const key = [_]u8{@intCast('0' + k)};
            const s = c.field(sp, &key) orelse {
                try c.add(.err, sp, .{ .add_null = .{ .line = c.closeLine(sp), .k = @intCast(k) } }, "{s} slot {d}: substat .@\"{d}\" is missing - write .@\"{d}\" = null, for an empty one", .{ who, slot, k, k });
                continue;
            };
            if (c.isNull(s)) continue;
            const sk_node = c.field(s, "key");
            if (c.str(sk_node)) |sk| {
                const bad_key = !strIn(&sub_keys, sk);
                const same_main = mk != null and std.mem.eql(u8, sk, mk.?);
                const dup = strIn(keys[0..nk], sk);
                // only build the pick list when this substat has a problem (it scans the file)
                var other: std.ArrayList(Choice) = .empty;
                if (bad_key or same_main or dup) {
                    // substats this disc doesn't have yet (and that aren't its main stat), plus "empty it"
                    for (sub_keys) |x| {
                        if (mk != null and std.mem.eql(u8, x, mk.?)) continue;
                        if (strIn(keys[0..nk], x) or std.mem.eql(u8, x, sk)) continue;
                        try other.append(c.a, .{ .label = x, .fix = .{ .rename = .{ .line = c.lineOf(sk_node.?), .from = try c.a.dupe(u8, sk), .to = x } } });
                    }
                    if (try c.setValue(s, &key, "null")) |tn| try other.append(c.a, .{ .label = "Empty it (null)", .fix = tn });
                }
                if (bad_key) {
                    const sg = try c.suggest(&sub_keys, sk, c.lineOf(sk_node.?), 0);
                    try c.addFull(.err, sk_node.?, sg.fix, other.items, null, "{s} slot {d}: \"{s}\" isn't a substat", .{ who, slot, sk });
                }
                if (same_main) try c.addFull(.check, sk_node.?, null, other.items, null, "{s} slot {d}: substat {d} is the same as the main stat ({s}) - the game never rolls that; pick another", .{ who, slot, k, sk });
                if (dup) try c.addFull(.check, sk_node.?, null, other.items, null, "{s} slot {d}: substat {s} appears twice - the game never rolls that; pick another", .{ who, slot, sk });
                keys[nk] = sk;
                nk += 1;
            } else try c.addFull(.err, s, try c.setValue(s, &key, "null"), &.{}, "Empty it (null)", "{s} slot {d}: substat {d} has no .key", .{ who, slot, k });
            const pn = c.field(s, "+");
            const pv = c.int(pn);
            if (pv == null or pv.? < 0 or pv.? > 5) {
                try c.add(.err, pn orelse s, if (pv != null) Fix{ .plus = .{ .line = c.loc(pn.?).line } } else null, "{s} slot {d}: substat {d} .@\"+\" has to be 0-5", .{ who, slot, k });
            } else plus += pv.?;
        }
        if (plus > 5) {
            // lower the biggest upgrades until the total is 5
            var pl: [4]i64 = .{ 0, 0, 0, 0 };
            var pnodes: [4]?Zoir.Node.Index = .{ null, null, null, null };
            for (1..5) |k| {
                const key = [_]u8{@intCast('0' + k)};
                if (c.field(sp, &key)) |s| if (c.field(s, "+")) |pn| if (c.int(pn)) |pv| {
                    pl[k - 1] = pv;
                    pnodes[k - 1] = pn;
                };
            }
            var total = plus;
            const orig = pl;
            while (total > 5) {
                var bi: usize = 0;
                for (0..4) |k| if (pl[k] > pl[bi]) {
                    bi = k;
                };
                pl[bi] -= 1;
                total -= 1;
            }
            var edits: std.ArrayList(Fix) = .empty;
            for (0..4) |k| if (pl[k] != orig[k]) if (pnodes[k]) |pn| try edits.append(c.a, .{ .replace_text = .{ .line = c.lineOf(pn), .from = try std.fmt.allocPrint(c.a, ".@\"+\" = {d}", .{orig[k]}), .to = try std.fmt.allocPrint(c.a, ".@\"+\" = {d}", .{pl[k]}) } });
            try c.addFull(.check, sp, if (edits.items.len > 0) Fix{ .multi = edits.items } else null, &.{}, "Lower to 5 upgrades", "{s} slot {d}: substats have {d} upgrades in total - a max-level disc only gets 5", .{ who, slot, plus });
        }
    }
};

fn lessThan(_: void, a: Problem, b: Problem) bool {
    if (a.sev != b.sev) return a.sev == .err;
    return a.line < b.line;
}

fn lineText(src: []const u8, line: u32) []const u8 {
    var it = std.mem.splitScalar(u8, src, '\n');
    var n: u32 = 1;
    while (it.next()) |l| : (n += 1) if (n == line) return l;
    return "";
}

/// Line of the first syntax error, or null if the text parses.
fn firstErrorLine(gpa: std.mem.Allocator, src: [:0]const u8) ?u32 {
    var tree = Ast.parse(gpa, src, .{ .mode = .zon }) catch return 0;
    defer tree.deinit(gpa);
    if (tree.errors.len == 0) return null;
    return @intCast(tree.tokenLocation(0, tree.errors[0].token).line + 1);
}

fn parsesClean(gpa: std.mem.Allocator, src: [:0]const u8) bool {
    var tree = Ast.parse(gpa, src, .{ .mode = .zon }) catch return false;
    defer tree.deinit(gpa);
    return tree.errors.len == 0;
}

/// Checks `source`. All strings in the report live in its arena.
pub fn check(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Report {
    return checkWith(gpa, source, null);
}

/// Like `check`, also comparing with the file as it was opened (`original`): characters that were
/// in it and are gone now are reported and can be brought back exactly.
pub fn checkWith(gpa: std.mem.Allocator, source: []const u8, original: ?[]const u8) error{OutOfMemory}!Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupeSentinel(u8, source, 0);
    var out: std.ArrayList(Problem) = .empty;

    var tree = try Ast.parse(gpa, src, .{ .mode = .zon });
    defer tree.deinit(gpa);

    if (tree.errors.len > 0) {
        // Like the server: report the first syntax error.
        const e = tree.errors[0];
        var w: std.Io.Writer.Allocating = .init(a);
        tree.renderError(e, &w.writer) catch return error.OutOfMemory;
        const l = tree.tokenLocation(0, e.token);
        const line: u32 = @intCast(l.line + 1);
        const col: u32 = @intCast(l.column + 1 + tree.errorOffset(e));
        var p: Problem = .{ .sev = .err, .line = line, .col = col, .msg = w.written() };
        if (e.tag == .expected_comma_after_initializer or e.tag == .expected_comma_after_field) {
            // Only offer a comma that gets past this error. Try where the parser stopped, then the end of
            // the previous lines (a missing comma at a line end is often only noticed on the next line).
            var cands: [3]Fix = undefined;
            var nc: usize = 0;
            cands[nc] = .{ .comma = .{ .line = line, .col = col } };
            nc += 1;
            var ln = line;
            while (ln > 1 and nc < 3) {
                ln -= 1;
                const txt = lineText(src, ln);
                const tr = std.mem.trimEnd(u8, txt, " \t\r");
                if (tr.len == 0) continue;
                const last = tr[tr.len - 1];
                if (last == ',' or last == '{') break;
                cands[nc] = .{ .comma = .{ .line = ln, .col = @intCast(tr.len + 1) } };
                nc += 1;
            }
            for (cands[0..nc]) |fx| {
                const fixed = try applyFix(a, src, fx);
                if (firstErrorLine(gpa, fixed)) |nl| {
                    if (nl > line) {
                        p.fix = fx;
                        break;
                    }
                } else {
                    p.fix = fx;
                    break;
                }
            }
            if (p.fix) |f| if (f.comma.line != line) {
                p.msg = try std.fmt.allocPrint(a, "{s} - the comma is missing at the end of line {d}", .{ p.msg, f.comma.line });
            };
        }
        // Find the real cause: collect small edits (missing/extra braces, commas, ".{") near the error
        // and anywhere they're obviously wrong, then keep the best one that makes the file parse.
        if (p.fix == null) {
            var cands: std.ArrayList(Fix) = .empty;
            try dupOpenCands(a, src, &cands);
            try braceCands(a, src, line, &cands);
            try searchCands(a, src, line, &cands);
            if (try pickRepair(gpa, a, src, cands.items)) |fx| {
                p.msg = switch (fx) {
                    .delete_line => |d| try std.fmt.allocPrint(a, "{s} - the real cause: line {d} is an extra brace line", .{ p.msg, d.line }),
                    .brace => |br| try std.fmt.allocPrint(a, "{s} - the real cause: a }}, is missing just before line {d}", .{ p.msg, br.line }),
                    .comma => |cm| try std.fmt.allocPrint(a, "{s} - the real cause: a comma is missing at the end of line {d}", .{ p.msg, cm.line }),
                    .open_brace => |ob| try std.fmt.allocPrint(a, "{s} - the real cause: a .{{ is missing just before line {d}", .{ p.msg, ob.line }),
                    .append_open => |ao| try std.fmt.allocPrint(a, "{s} - the real cause: line {d} ends with = but its .{{ is missing", .{ p.msg, ao.line }),
                    else => p.msg,
                };
                p.fix = fx;
            }
        }
        if (p.fix == null) p.msg = try std.fmt.allocPrint(a, "{s} - no automatic fix found; look at this line and the few above it", .{p.msg});
        try out.append(a, p);
        return .{ .arena = arena, .problems = try out.toOwnedSlice(a) };
    }

    var zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
    defer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) {
        for (zoir.compile_errors) |ce| {
            const tok = if (ce.token.unwrap()) |t| t else tree.firstToken(@enumFromInt(ce.node_or_offset));
            const l = tree.tokenLocation(0, tok);
            const extra: u32 = if (ce.token.unwrap() != null) ce.node_or_offset else 0;
            const line_no: u32 = @intCast(l.line + 1);
            const msg = ce.msg.get(&zoir);
            var fix: ?Fix = null;
            var lbl: ?[]const u8 = null;
            if (std.mem.indexOf(u8, msg, "duplicate") != null) {
                // remove the second copy when it's a one-line field
                const txt = std.mem.trim(u8, std.mem.trimEnd(u8, lineText(src, line_no), "\r"), " ");
                if (std.mem.count(u8, txt, "{") == std.mem.count(u8, txt, "}") and txt.len > 0 and txt[0] == '.') {
                    fix = .{ .replace_range = .{ .first = line_no, .last = line_no, .text = "" } };
                    lbl = "Remove the second copy";
                }
            }
            try out.append(a, .{ .sev = .err, .line = line_no, .col = @intCast(l.column + 1 + extra), .msg = try a.dupe(u8, msg), .fix = fix, .fix_label = lbl });
        }
        return .{ .arena = arena, .problems = try out.toOwnedSlice(a) };
    }

    var c: Checker = .{ .a = a, .tree = &tree, .zoir = &zoir, .original = original };
    try c.run();
    std.mem.sort(Problem, c.out.items, {}, lessThan);
    return .{ .arena = arena, .problems = c.out.items };
}

/// Generic repair: for each line from the error back up to 120 lines, try
/// (1) deleting a line that is only a closing brace, (2) inserting "}," before a closing-brace line
/// at the indent of the line above, (3) adding a comma at the end of the line.
/// Returns the first edit after which the whole file parses.
fn searchCands(a: std.mem.Allocator, src: [:0]const u8, err_line: u32, out: *std.ArrayList(Fix)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    const last: u32 = @intCast(@min(err_line, lines.items.len));
    const first: u32 = if (last > 120) last - 120 else 1;
    var ln: u32 = last;
    while (ln >= first) : (ln -= 1) {
        const l = lines.items[ln - 1];
        const tr = std.mem.trim(u8, l, " \t");
        var cands: [6]?Fix = @splat(null);
        if (std.mem.eql(u8, tr, "},") or std.mem.eql(u8, tr, "}")) {
            cands[0] = .{ .delete_line = .{ .line = ln } };
            const above = if (ln > 1) lines.items[ln - 2] else "";
            cands[1] = .{ .brace = .{ .line = ln, .ind = indentOf(above) } };
        }
        if (tr.len > 0 and tr[tr.len - 1] != ',' and tr[tr.len - 1] != '{' and tr[tr.len - 1] != '=')
            cands[2] = .{ .comma = .{ .line = ln, .col = @intCast(std.mem.trimEnd(u8, l, " \t").len + 1) } };
        // opening side
        if (std.mem.eql(u8, tr, ".{")) cands[3] = .{ .delete_line = .{ .line = ln } };
        if (tr.len > 0 and tr[tr.len - 1] == '=') cands[4] = .{ .append_open = .{ .line = ln } };
        if (tr.len > 0 and tr[0] == '.' and ln > 1) {
            // a block's ".{" line is missing: its fields would start right after the previous "}," or "{"
            const prev = std.mem.trim(u8, lines.items[ln - 2], " \t");
            if ((std.mem.eql(u8, prev, "},") or (prev.len > 0 and prev[prev.len - 1] == '{')) and indentOf(l) >= 4)
                cands[5] = .{ .open_brace = .{ .line = ln, .ind = indentOf(l) - 4 } };
        }
        for (cands) |c| if (c) |fx| try out.append(a, fx);
        if (ln == 1) break;
    }
}

/// Anywhere in the file: a ".{" line repeated at the same indent is never right.
fn dupOpenCands(a: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Fix)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    for (lines.items, 0..) |l, li| {
        if (li == 0) continue;
        const tr = std.mem.trim(u8, l, " \t");
        const prev = lines.items[li - 1];
        if (std.mem.eql(u8, tr, ".{") and std.mem.eql(u8, std.mem.trim(u8, prev, " \t"), ".{") and indentOf(prev) == indentOf(l))
            try out.append(a, .{ .delete_line = .{ .line = @intCast(li + 1) } });
    }
}

/// Of all candidate edits, keeps the best one that makes the file parse: every brace lined up
/// with its block first, then the fewest rule errors afterwards (a wrong repair breaks the rules).
fn pickRepair(gpa: std.mem.Allocator, a: std.mem.Allocator, src: [:0]const u8, cands: []const Fix) error{OutOfMemory}!?Fix {
    var best: ?Fix = null;
    var best_score: u64 = std.math.maxInt(u64);
    var seen: usize = 0;
    for (cands) |fx| {
        const fixed = try applyFix(a, src, fx);
        if (!parsesClean(gpa, fixed)) continue;
        const mm = try indentMismatches(a, fixed);
        var r = try check(gpa, fixed);
        const re = r.errorCount();
        r.deinit();
        const score = @as(u64, mm) * 10_000 + re;
        if (score < best_score) {
            best = fx;
            best_score = score;
        }
        seen += 1;
        if (best_score == 0 or seen > 25) break;
    }
    return best;
}

/// How many closing braces sit at a different indent than the line that opened their block.
fn indentMismatches(a: std.mem.Allocator, src: []const u8) !u32 {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        var in_str = false;
        var k: usize = 0;
        while (k < l.len) : (k += 1) {
            const ch = l[k];
            if (in_str) {
                if (ch == '\\') k += 1 else if (ch == '"') in_str = false;
                continue;
            }
            if (ch == '"') in_str = true else if (ch == '/' and k + 1 < l.len and l[k + 1] == '/') break else if (ch == '{') {
                try stack.append(a, indentOf(l) | (@as(u32, @intFromBool(std.mem.trimStart(u8, l, " ")[0] == '.')) << 31));
            } else if (ch == '}') {
                const o = stack.pop() orelse {
                    n += 1;
                    continue;
                };
                const t0 = std.mem.trimStart(u8, l, " ");
                if (t0.len > 0 and t0[0] == '}' and indentOf(l) != (o & 0x7fffffff)) n += 1;
            }
        }
    }
    return n + @as(u32, @intCast(stack.items.len));
}

fn indentOf(line: []const u8) u32 {
    var n: u32 = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Finds where a "}," is missing. Candidates: before a closing brace whose indent doesn't match the
/// block it closes, and before a field line (".name = ...") that sits at the indent of an outer block.
/// Keeps the candidate after which the file parses and every brace lines up (fewest mismatches).
fn braceCands(a: std.mem.Allocator, src: [:0]const u8, err_line: u32, out: *std.ArrayList(Fix)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    const Open = struct { line: u32, ind: u32 };
    var stack: std.ArrayList(Open) = .empty;
    var cands: std.ArrayList(Fix) = .empty;
    for (lines.items, 0..) |l, li| {
        if (li + 1 > err_line) break;
        const trimmed = std.mem.trimStart(u8, l, " ");
        // a field at (or left of) the indent of the innermost open block's own line belongs to an outer block
        if (trimmed.len > 0 and trimmed[0] == '.' and stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (indentOf(l) <= top.ind and top.line != li) try cands.append(a, .{ .brace = .{ .line = @intCast(li + 1), .ind = top.ind } });
        }
        var in_str = false;
        var k: usize = 0;
        while (k < l.len) : (k += 1) {
            const ch = l[k];
            if (in_str) {
                if (ch == '\\') k += 1 else if (ch == '"') in_str = false;
                continue;
            }
            if (ch == '"') in_str = true else if (ch == '/' and k + 1 < l.len and l[k + 1] == '/') break else if (ch == '{') {
                try stack.append(a, .{ .line = @intCast(li), .ind = indentOf(l) });
            } else if (ch == '}') {
                const o = stack.pop() orelse continue;
                if (trimmed.len > 0 and trimmed[0] == '}' and indentOf(l) != o.ind and o.line != li)
                    try cands.append(a, .{ .brace = .{ .line = @intCast(li + 1), .ind = o.ind } });
            }
        }
        if (cands.items.len > 60) break;
    }
    try out.appendSlice(a, cands.items);
}

/// Applies one fix to the text. Returns new text (allocated with `a`).
pub fn applyFix(a: std.mem.Allocator, src: []const u8, fx: Fix) ![:0]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(a, l);
    const crlf = std.mem.indexOf(u8, src, "\r\n") != null;
    const nl: []const u8 = if (crlf) "\r\n" else "\n";
    const cr: []const u8 = if (crlf) "\r" else "";
    const at = struct {
        fn f(ls: []const []const u8, line: u32) usize {
            return @min(ls.len - 1, line - 1);
        }
    }.f;
    switch (fx) {
        .brace => |b| {
            const s = try std.fmt.allocPrint(a, "{s}}},{s}", .{ try spaces(a, b.ind), cr });
            try lines.insert(a, at(lines.items, b.line), s);
        },
        .delete_line => |d| {
            _ = lines.orderedRemove(at(lines.items, d.line));
        },
        .replace_range => |rr| {
            const f0 = at(lines.items, rr.first);
            const l0 = at(lines.items, rr.last);
            var repl: std.ArrayList([]const u8) = .empty;
            if (rr.text.len > 0) {
                var lit = std.mem.splitScalar(u8, rr.text, '\n');
                while (lit.next()) |x| try repl.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ x, cr }));
            }
            try lines.replaceRange(a, f0, l0 - f0 + 1, repl.items);
        },
        .multi => |list| {
            // apply from the bottom up so earlier line numbers stay valid
            const sorted = try a.dupe(Fix, list);
            std.mem.sort(Fix, sorted, {}, struct {
                fn lt(_: void, x: Fix, y: Fix) bool {
                    return fixLine(x) > fixLine(y);
                }
            }.lt);
            var text: []const u8 = try std.mem.join(a, "\n", lines.items);
            for (sorted) |f| text = try applyFix(a, text, f);
            return a.dupeSentinel(u8, text, 0);
        },
        .rename_field => |rf| {
            const i = at(lines.items, rf.line);
            const from = try std.fmt.allocPrint(a, ".{s} =", .{rf.from});
            const to = try std.fmt.allocPrint(a, ".{s} =", .{rf.to});
            if (std.mem.indexOf(u8, lines.items[i], from)) |pos| {
                const l = lines.items[i];
                lines.items[i] = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ l[0..pos], to, l[pos + from.len ..] });
            }
        },
        .replace_text => |rt| {
            const i = at(lines.items, rt.line);
            if (std.mem.indexOf(u8, lines.items[i], rt.from)) |pos| {
                const l = lines.items[i];
                lines.items[i] = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ l[0..pos], rt.to, l[pos + rt.from.len ..] });
            }
        },
        .insert_line => |il| {
            try lines.insert(a, at(lines.items, il.line), try std.fmt.allocPrint(a, "{s}{s}", .{ il.text, cr }));
        },
        .open_brace => |ob| {
            const s2 = try std.fmt.allocPrint(a, "{s}.{{{s}", .{ try spaces(a, ob.ind), cr });
            try lines.insert(a, at(lines.items, ob.line), s2);
        },
        .append_open => |ao| {
            const i = at(lines.items, ao.line);
            const l = lines.items[i];
            const body = std.mem.trimEnd(u8, l, " \t\r");
            lines.items[i] = try std.fmt.allocPrint(a, "{s} .{{{s}", .{ body, if (l.len > 0 and l[l.len - 1] == '\r') "\r" else "" });
        },
        .comma => |cm| {
            const i = at(lines.items, cm.line);
            const l = lines.items[i];
            const p = @min(l.len, cm.col - 1);
            lines.items[i] = try std.fmt.allocPrint(a, "{s},{s}", .{ l[0..p], l[p..] });
        },
        .rename => |r| {
            const i = at(lines.items, r.line);
            const from = try std.fmt.allocPrint(a, "\"{s}\"", .{r.from});
            const to = try std.fmt.allocPrint(a, "\"{s}\"", .{r.to});
            lines.items[i] = try std.mem.replaceOwned(u8, a, lines.items[i], from, to);
        },
        .refine, .plus, .rank6 => {
            const line, const key: []const u8, const lo: i64, const hi: i64 = switch (fx) {
                .refine => |r| .{ r.line, ".refine = ", 1, 5 },
                .plus => |r| .{ r.line, ".@\"+\" = ", 0, 5 },
                .rank6 => |r| .{ r.line, ".rank = ", 6, 6 },
                else => unreachable,
            };
            const i = at(lines.items, line);
            const l = lines.items[i];
            if (std.mem.indexOf(u8, l, key)) |p| {
                var e = p + key.len;
                if (e < l.len and l[e] == '-') e += 1;
                while (e < l.len and std.ascii.isDigit(l[e])) e += 1;
                const v = std.fmt.parseInt(i64, l[p + key.len .. e], 10) catch lo;
                lines.items[i] = try std.fmt.allocPrint(a, "{s}{d}{s}", .{ l[0 .. p + key.len], std.math.clamp(v, lo, hi), l[e..] });
            }
        },
        .add_null => |n| {
            const i = at(lines.items, n.line);
            const s = try std.fmt.allocPrint(a, "{s}.@\"{d}\" = null,{s}", .{ try spaces(a, indentOf(lines.items[i]) + 4), n.k, cr });
            try lines.insert(a, i, s);
        },
        .tabs => |t| {
            const i = at(lines.items, t.line);
            const ind = indentOf(lines.items[i]) + 4;
            var j = i + 1;
            while (j < lines.items.len and std.mem.indexOfScalar(u8, lines.items[j], '}') == null) j += 1;
            if (j >= lines.items.len) return a.dupeSentinel(u8, src, 0);
            const want = tabState(t.m);
            var repl: std.ArrayList([]const u8) = .empty;
            for (want) |v| try repl.append(a, try std.fmt.allocPrint(a, "{s}{s},{s}", .{ try spaces(a, ind), if (v) "true" else "false", cr }));
            try lines.replaceRange(a, i + 1, j - i - 1, repl.items);
        },
    }
    const joined = try std.mem.join(a, "\n", lines.items);
    _ = nl;
    return a.dupeSentinel(u8, joined, 0);
}

/// True when a fix deletes whole lines of data (a character, a disc, an entry). Those are never
/// applied by Fix all - only when you click them.
fn removesBlock(f: Fix) bool {
    return switch (f) {
        .replace_range => |r| r.text.len == 0,
        .multi => |list| for (list) |x| {
            if (removesBlock(x)) break true;
        } else false,
        else => false,
    };
}

fn fixLine(f: Fix) u32 {
    return switch (f) {
        .multi => 0,
        .replace_range => |r| r.first,
        inline else => |x| x.line,
    };
}

fn spaces(a: std.mem.Allocator, n: u32) ![]u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

/// Applies fixable problems one at a time (re-checking after each) until none are left.
pub const FixResult = struct { text: [:0]u8, applied: u32 };

pub fn fixAll(gpa: std.mem.Allocator, a: std.mem.Allocator, source: []const u8) !FixResult {
    return fixAllWith(gpa, a, source, null);
}

/// Applies every automatic fix (never ones marked manual: removals, adding new characters).
pub fn fixAllWith(gpa: std.mem.Allocator, a: std.mem.Allocator, source: []const u8, original: ?[]const u8) error{OutOfMemory}!FixResult {
    var text: [:0]u8 = try a.dupeSentinel(u8, source, 0);
    var applied: u32 = 0;
    while (applied < 500) {
        var r = try checkWith(gpa, text, original);
        defer r.deinit();
        const fx = for (r.problems) |p| {
            if (p.manual) continue;
            if (p.fix) |f| break f;
        } else break;
        // copy strings out of the report arena before it is freed
        const own: Fix = switch (fx) {
            .rename => |rn| .{ .rename = .{ .line = rn.line, .from = try a.dupe(u8, rn.from), .to = try a.dupe(u8, rn.to) } },
            else => fx,
        };
        const next = try applyFix(a, text, own);
        if (std.mem.eql(u8, next, text)) break;
        text = next;
        applied += 1;
    }
    return .{ .text = text, .applied = applied };
}

// ---------------- tests ----------------

const tt = std.testing;

fn problemsFor(src: []const u8) !Report {
    return check(tt.allocator, src);
}

const good_avatar =
    \\.{
    \\    .role = .{
    \\        .avatar = "Belle",
    \\        .control_avatar = "Belle",
    \\        .control_guise_avatar = "Miyabi",
    \\    },
    \\    .main_city = .{ .section = "Video Store" },
    \\    .time = .{ .day = .friday, .period = .morning },
    \\    .avatars = .{
    \\        .{
    \\            .name = "Lucia",
    \\            .level = 60,
    \\            .rank = 6,
    \\            .favorite = false,
    \\            .unlocked_mindscape = 0,
    \\            .mindscape_tab_state = .{
    \\                false,
    \\                false,
    \\                false,
    \\                false,
    \\                false,
    \\                false,
    \\            },
    \\            .show_weapon_status = .locked,
    \\            .weapon = .{ .name = "Dreamlit Hearth", .refine = 1 },
    \\            .equipment = .{
    \\                .@"1" = .{
    \\                    .id = .{ .name = "Bloodwing Nocturne [1]", .rarity = .s },
    \\                    .main_property = .{ .key = "HP" },
    \\                    .sub_properties = .{
    \\                        .@"1" = .{ .key = "DEF", .@"+" = 1 },
    \\                        .@"2" = null,
    \\                        .@"3" = null,
    \\                        .@"4" = null,
    \\                    },
    \\                },
    \\                .@"2" = null,
    \\                .@"3" = null,
    \\                .@"4" = null,
    \\                .@"5" = null,
    \\                .@"6" = null,
    \\            },
    \\            .awake = .{ .level = 0, .enabled = false },
    \\        },
    \\    },
    \\    .weapons_undressed = .{
    \\        .{ .name = "Dreamlit Hearth", .refine = 1 },
    \\    },
    \\    .equipment_undressed = .{},
    \\}
;

test "clean file has no problems" {
    var r = try problemsFor(good_avatar);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 0), r.errorCount());
}

test "rules: names, refine, tabs, slot main stat" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "\"Dreamlit Hearth\", .refine = 1", "\"Dreamlit Hearth\", .refine = 7");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    // the sample has the W-Engine equipped and in the inventory: both refines are wrong
    try tt.expectEqual(@as(usize, 2), r.errorCount());
    try tt.expect(r.problems[0].fix.? == .refine and r.problems[1].fix.? == .refine);

    const bad2 = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "Bloodwing Nocturne [1]", "Bloodwing Nocturne [2]");
    defer tt.allocator.free(bad2);
    var r2 = try problemsFor(bad2);
    defer r2.deinit();
    // a [2] piece in slot 1: the wrong slot
    try tt.expect(r2.problems.len >= 1);
}

test "disc spelling fix and fix-all" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".@\"2\" = null,\n                .@\"3\" = null,", ".@\"2\" = .{\n                    .id = .{ .name = \"Bloodwing Nocturne[2]\", .rarity = .s },\n                    .main_property = .{ .key = \"ATK\" },\n                    .sub_properties = .{\n                        .@\"1\" = null,\n                        .@\"2\" = null,\n                        .@\"3\" = null,\n                        .@\"4\" = null,\n                    },\n                },\n                .@\"3\" = null,");
    defer tt.allocator.free(bad);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqual(@as(u32, 1), res.applied);
    // spelled the server's way: "Bloodwing Nocturne [2]" (the newer Remielle puts a space before every [n])
    try tt.expect(std.mem.indexOf(u8, res.text, "\"Bloodwing Nocturne [2]\"") != null);
    var r = try problemsFor(res.text);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 0), r.errorCount());
}

test "missing }, is traced to its real cause" {
    // remove the "}," that closes the sub_properties of slot 1
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "                        .@\"4\" = null,\n                    },\n", "                        .@\"4\" = null,\n");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 1), r.problems.len);
    try tt.expect(r.problems[0].fix != null and r.problems[0].fix.? == .brace);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
}

test "user files (put them in testdata/)" {
    const io = tt.io;
    const broken = std.Io.Dir.cwd().readFileAlloc(io, "testdata/broken-1.zon", tt.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer tt.allocator.free(broken);
    var r = try problemsFor(broken);
    defer r.deinit();
    // the server says 1563:9 expected field initializer
    try tt.expectEqual(@as(u32, 1563), r.problems[0].line);
    try tt.expectEqual(@as(u32, 9), r.problems[0].col);
    std.debug.print("\n  broken-1.zon: {d}:{d} {s}\n", .{ r.problems[0].line, r.problems[0].col, r.problems[0].msg });
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), broken);
    var r2 = try problemsFor(res.text);
    defer r2.deinit();
    for (r2.problems) |p| std.debug.print("  after fix-all: {s} {d}:{d} {s}\n", .{ @tagName(p.sev), p.line, p.col, p.msg });
    try tt.expectEqual(@as(usize, 0), r2.errorCount());
}


test "the game's own file has no errors" {
    const io = tt.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, "testdata/template.zon", tt.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer tt.allocator.free(src);
    var r = try problemsFor(src);
    defer r.deinit();
    for (r.problems) |p| std.debug.print("\n  template: {s} {d}:{d} {s}\n", .{ @tagName(p.sev), p.line, p.col, p.msg });
    try tt.expectEqual(@as(usize, 0), r.errorCount());
}

test "missing comma mid-file gets the comma fix" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".level = 60,", ".level = 60");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expect(r.problems[0].fix != null and r.problems[0].fix.? == .comma);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
}


test "extra } is found and removed" {
    // an extra "}," right after slot 1's substats closes the disc too early
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "                        .@\"4\" = null,\n                    },\n", "                        .@\"4\" = null,\n                    },\n                    },\n");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 1), r.problems.len);
    try tt.expect(r.problems[0].fix != null);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
}

test "stress: random single mistakes in the game's own file (prints results)" {
    const io = tt.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, "testdata/template.zon", tt.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer tt.allocator.free(src);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(tt.allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(tt.allocator, l);
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var exact: u32 = 0;
    var parses: u32 = 0;
    var none: u32 = 0;
    const N = 60; // full run with 800: 736 restored exactly (incl. 128/128 misspelled fields), 48 valid as written, 16 deleted lines re-added with defaults at the end of their block: 281 exact + 19 valid-as-written, 0 wrong
    var kinds: [8][3]u32 = @splat(@splat(0));
    var done: u32 = 0;
    var harmless: u32 = 0;
    var silent_wrong: u32 = 0;
    var flagged: u32 = 0;
    while (done < N) {
        var arena = std.heap.ArenaAllocator.init(tt.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const li = rnd.uintLessThan(usize, lines.items.len);
        const l = lines.items[li];
        const tr = std.mem.trim(u8, l, " ");
        const kind = rnd.uintLessThan(u8, 8);
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(a, lines.items);
        switch (kind) {
            0 => { // delete a closing-brace line
                if (!std.mem.eql(u8, tr, "},")) continue;
                _ = out.orderedRemove(li);
            },
            1 => { // duplicate a closing-brace line
                if (!std.mem.eql(u8, tr, "},")) continue;
                try out.insert(a, li, l);
            },
            2 => { // drop the comma at the end of a line
                if (tr.len < 3 or tr[tr.len - 1] != ',' or tr[0] == '}') continue;
                out.items[li] = l[0 .. l.len - 1];
            },
            3 => { // delete a ".{" line
                if (!std.mem.eql(u8, tr, ".{")) continue;
                _ = out.orderedRemove(li);
            },
            4 => { // duplicate a ".{" line
                if (!std.mem.eql(u8, tr, ".{")) continue;
                try out.insert(a, li, l);
            },
            5 => { // drop the ".{" at the end of a "= .{" line
                if (!std.mem.endsWith(u8, l, " = .{")) continue;
                out.items[li] = l[0 .. l.len - 3];
            },
            6 => { // misspell a field name: drop one letter (like main_propert)
                const d = std.mem.indexOf(u8, l, ".") orelse continue;
                const e = std.mem.indexOfPos(u8, l, d, " =") orelse continue;
                if (e - d < 5 or l[d + 1] == '@' or l[d + 1] == '{') continue;
                const cut = d + 1 + rnd.uintLessThan(usize, e - d - 1);
                out.items[li] = try std.mem.concat(a, u8, &.{ l[0..cut], l[cut + 1 ..] });
            },
            7 => { // delete a whole simple field line (one that has a default)
                if (!(std.mem.startsWith(u8, tr, ".favorite =") or std.mem.startsWith(u8, tr, ".show_weapon_status =") or std.mem.startsWith(u8, tr, ".awake =") or std.mem.startsWith(u8, tr, ".level = 60") or std.mem.startsWith(u8, tr, ".rank ="))) continue;
                _ = out.orderedRemove(li);
            },
            else => unreachable,
        }
        done += 1;
        const bad = try std.mem.join(a, "\n", out.items);
        const res = try fixAll(tt.allocator, a, bad);
        if (std.mem.eql(u8, res.text, src)) {
            exact += 1;
            kinds[kind][0] += 1;
        } else if (parsesClean(tt.allocator, res.text)) {
            parses += 1;
            kinds[kind][1] += 1;
            var rr = try check(tt.allocator, res.text);
            defer rr.deinit();
            var orig_r = try check(tt.allocator, bad);
            defer orig_r.deinit();
            if (orig_r.problems.len == 0) harmless += 1 else if (rr.errorCount() == 0) silent_wrong += 1 else flagged += 1;
        } else {
            none += 1;
            kinds[kind][2] += 1;
        }
    }
    std.debug.print("\n  stress {d}: restored exactly {d}, parses but differs {d}, not fixed {d}\n", .{ N, exact, parses, none });
    std.debug.print("    of the 'differs': {d} were never an error (valid as written), {d} still flagged by the rules, {d} wrong but not flagged\n", .{ harmless, flagged, silent_wrong });
    const names_k = [_][]const u8{ "missing },", "extra },", "missing comma", "missing .{ line", "extra .{ line", "= without .{", "misspelled field", "deleted field line" };
    for (kinds, 0..) |k, i| std.debug.print("    {s}: exact {d}, differs {d}, not fixed {d}\n", .{ names_k[i], k[0], k[1], k[2] });
}

test "misspelled field gets the server's message and a rename fix" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".main_property = .{ .key = \"HP\" },", ".main_propert = .{ .key = \"HP\" },");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expect(r.problems.len >= 1);
    try tt.expect(std.mem.startsWith(u8, r.problems[0].msg, "unexpected field 'main_propert' (supported: 'id', 'main_property', 'sub_properties')"));
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
}

test "wrong kind of value: expected struct" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".main_property = .{ .key = \"HP\" },", ".main_property = \"HP\",");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 1), r.problems.len);
    try tt.expect(std.mem.startsWith(u8, r.problems[0].msg, "expected struct"));
    const bad2 = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".level = 60,", ".level = \"60\",");
    defer tt.allocator.free(bad2);
    var r2 = try problemsFor(bad2);
    defer r2.deinit();
    try tt.expect(std.mem.startsWith(u8, r2.problems[0].msg, "expected integer"));
}

test "wrong enum value gets a fix" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".show_weapon_status = .locked,", ".show_weapon_status = .lockd,");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    try tt.expect(std.mem.startsWith(u8, r.problems[0].msg, "unexpected enum literal '.lockd'"));
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
}

test "Potential: only the 13 characters that have it" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".awake = .{ .level = 0, .enabled = false },", ".awake = .{ .level = 6, .enabled = true },");
    defer tt.allocator.free(bad);
    var r = try problemsFor(bad);
    defer r.deinit();
    // Lucia has no Potential: both the level and enabled are wrong
    try tt.expectEqual(@as(usize, 2), r.errorCount());
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    try tt.expectEqualStrings(good_avatar, res.text);
    // Vivian has Potential: level 6 enabled is fine
    const ok = try std.mem.replaceOwned(u8, tt.allocator, bad, "\"Lucia\"", "\"Vivian\"");
    defer tt.allocator.free(ok);
    var r2 = try problemsFor(ok);
    defer r2.deinit();
    try tt.expectEqual(@as(usize, 0), r2.errorCount());
}

test "every kind of value mistake is fixed (game's own file)" {
    const io = tt.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, "testdata/template.zon", tt.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer tt.allocator.free(src);
    const Case = struct { name: []const u8, from: []const u8, to: []const u8, exact: bool };
    const cases = [_]Case{
        .{ .name = "character typo", .from = ".name = \"Vivian\"", .to = ".name = \"Vivain\"", .exact = true },
        .{ .name = "W-Engine typo", .from = "\"Flight of Fancy\"", .to = "\"Flight of Fency\"", .exact = true },
        .{ .name = "disc typo", .from = "\"Astral Voice [1]\"", .to = "\"Astral Vioce [1]\"", .exact = true },
        .{ .name = "disc in wrong slot", .from = "\"Astral Voice [2]\"", .to = "\"Astral Voice [3]\"", .exact = true },
        .{ .name = "rarity", .from = "\"Astral Voice [1]\", .rarity = .s", .to = "\"Astral Voice [1]\", .rarity = .x", .exact = true },
        .{ .name = "level out of range", .from = ".level = 60,", .to = ".level = 99,", .exact = true },
        .{ .name = "rank out of range", .from = ".rank = 6,", .to = ".rank = 9,", .exact = true },
        .{ .name = "mindscape out of range", .from = ".unlocked_mindscape = 6,", .to = ".unlocked_mindscape = 9,", .exact = true },
        .{ .name = "refine", .from = ".refine = 5 }", .to = ".refine = 9 }", .exact = true },
        .{ .name = "substat +", .from = ".@\"+\" = 0 }", .to = ".@\"+\" = 9 }", .exact = false },
        .{ .name = "substat key typo", .from = ".{ .key = \"CRIT DMG\", .@\"+\" = 0 }", .to = ".{ .key = \"CRIT DMGG\", .@\"+\" = 0 }", .exact = true },
        .{ .name = "slot 1 main stat", .from = ".main_property = .{ .key = \"HP\" }", .to = ".main_property = .{ .key = \"ATK\" }", .exact = true },
        .{ .name = "quoted number", .from = ".level = 60,", .to = ".level = \"60\",", .exact = true },
        .{ .name = "quoted bool", .from = ".favorite = false,", .to = ".favorite = \"false\",", .exact = true },
        .{ .name = "enum as text", .from = ".show_weapon_status = .locked,", .to = ".show_weapon_status = \"locked\",", .exact = true },
        .{ .name = "enum typo", .from = ".show_weapon_status = .locked,", .to = ".show_weapon_status = .lockd,", .exact = true },
        .{ .name = "main_property as text", .from = ".main_property = .{ .key = \"HP\" }", .to = ".main_property = \"HP\"", .exact = true },
        .{ .name = "weapon garbage", .from = ".weapon = null,", .to = ".weapon = 5,", .exact = true },
        .{ .name = "role avatar", .from = ".avatar = \"Wise\"", .to = ".avatar = \"Wiise\"", .exact = true },
        .{ .name = "guise typo", .from = ".control_guise_avatar = \"Remielle\"", .to = ".control_guise_avatar = \"Remiele\"", .exact = true },
        .{ .name = "potential on wrong char", .from = ".awake = .{ .level = 0, .enabled = false }", .to = ".awake = .{ .level = 3, .enabled = true }", .exact = true },
        .{ .name = "slot 7", .from = ".@\"6\" = null,", .to = ".@\"7\" = null,", .exact = true },
        .{ .name = "field typo", .from = ".unlocked_mindscape = 6,", .to = ".unlocked_mindscap = 6,", .exact = true },
        .{ .name = "duplicate field", .from = ".favorite = false,", .to = ".favorite = false,\n            .favorite = false,", .exact = true },
    };
    var failed: usize = 0;
    for (cases) |cs| {
        var arena = std.heap.ArenaAllocator.init(tt.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const i = std.mem.indexOf(u8, src, cs.from) orelse {
            std.debug.print("\n  [{s}] pattern not found in the file\n", .{cs.name});
            failed += 1;
            continue;
        };
        const bad = try std.mem.concat(a, u8, &.{ src[0..i], cs.to, src[i + cs.from.len ..] });
        var r0 = try check(tt.allocator, bad);
        const found = r0.errorCount();
        r0.deinit();
        const res = try fixAll(tt.allocator, a, bad);
        var r = try check(tt.allocator, res.text);
        defer r.deinit();
        const exact = std.mem.eql(u8, res.text, src);
        const ok = found > 0 and r.errorCount() == 0 and (exact or !cs.exact);
        if (!ok) failed += 1;
        std.debug.print("\n  [{s}] found {d} error(s); after Fix all: {d} errors{s}{s}", .{ cs.name, found, r.errorCount(), if (exact) ", file restored exactly" else "", if (ok) "" else "   <-- FAILED" });
        if (!ok) for (r.problems) |p| std.debug.print("\n      left: {s} {d}:{d} {s}", .{ @tagName(p.sev), p.line, p.col, p.msg });
    }
    std.debug.print("\n", .{});
    try tt.expectEqual(@as(usize, 0), failed);
}

test "a character that went missing is reported and brought back exactly" {
    const io = tt.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, "testdata/template.zon", tt.allocator, .limited(16 << 20)) catch return error.SkipZigTest;
    defer tt.allocator.free(src);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // remove Vivian's whole block
    var blocks = try characterBlocks(a, src);
    const viv = blocks.get("Vivian").?;
    const i = std.mem.indexOf(u8, src, viv).?;
    const cut = try std.mem.concat(a, u8, &.{ src[0..i], src[i + viv.len + 1 ..] });
    var r = try checkWith(tt.allocator, cut, src);
    defer r.deinit();
    var found = false;
    for (r.problems) |p| if (std.mem.startsWith(u8, p.msg, "Vivian was in the file you opened")) {
        found = true;
    };
    try tt.expect(found);
    const res = try fixAllWith(tt.allocator, a, cut, src);
    var blocks2 = try characterBlocks(a, res.text);
    try tt.expectEqualStrings(viv, blocks2.get("Vivian").?);
    var r2 = try checkWith(tt.allocator, res.text, src);
    defer r2.deinit();
    try tt.expectEqual(@as(usize, 0), r2.errorCount());
}

test "Fix all never removes a character" {
    const bad = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "    .weapons_undressed", "        .{\n            .name = \"Lucia\",\n            .level = 60,\n            .rank = 6,\n            .favorite = false,\n            .unlocked_mindscape = 0,\n            .mindscape_tab_state = .{ false, false, false, false, false, false },\n            .show_weapon_status = .locked,\n            .weapon = null,\n            .equipment = .{ .@\"1\" = null, .@\"2\" = null, .@\"3\" = null, .@\"4\" = null, .@\"5\" = null, .@\"6\" = null },\n            .awake = .{ .level = 0, .enabled = false },\n        },\n    .weapons_undressed");
    defer tt.allocator.free(bad);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), bad);
    // the duplicate is still flagged, but both copies are still in the file
    try tt.expectEqual(@as(usize, 2), std.mem.count(u8, res.text, ".name = \"Lucia\""));
}

test "skin_id and form (newer Remielle fields)" {
    const with = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, ".awake = .{ .level = 0, .enabled = false },", ".awake = .{ .level = 0, .enabled = false },\n            .skin_id = 0,\n            .form = null,");
    defer tt.allocator.free(with);
    // no skin, no form: fine; and files without the two fields get no notice either
    var r0 = try problemsFor(with);
    defer r0.deinit();
    try tt.expectEqual(@as(usize, 0), r0.errorCount());
    var r1 = try problemsFor(good_avatar);
    defer r1.deinit();
    try tt.expectEqual(r0.problems.len, r1.problems.len);
    // Lucia's own skin (1451 -> 3114510): fine
    const own = try std.mem.replaceOwned(u8, tt.allocator, with, ".skin_id = 0,", ".skin_id = 3114510,");
    defer tt.allocator.free(own);
    var r2 = try problemsFor(own);
    defer r2.deinit();
    try tt.expectEqual(@as(usize, 0), r2.errorCount());
    // Sunbringer as Eldreda, her own skin (the line from the game): fine
    const sb0 = try std.mem.replaceOwned(u8, tt.allocator, with, "\"Lucia\"", "\"Sunbringer\"");
    defer tt.allocator.free(sb0);
    const sb1 = try std.mem.replaceOwned(u8, tt.allocator, sb0, ".skin_id = 0,", ".skin_id = 3116011,");
    defer tt.allocator.free(sb1);
    const sb = try std.mem.replaceOwned(u8, tt.allocator, sb1, ".form = null,", ".form = \"Eldreda\",");
    defer tt.allocator.free(sb);
    var r5 = try problemsFor(sb);
    defer r5.deinit();
    try tt.expectEqual(@as(usize, 0), r5.errorCount());
    // a typo in her form: error, fixed to the closest name
    const sbt = try std.mem.replaceOwned(u8, tt.allocator, sb, "\"Eldreda\"", "\"Eldrda\"");
    defer tt.allocator.free(sbt);
    var r6 = try problemsFor(sbt);
    defer r6.deinit();
    try tt.expectEqual(@as(usize, 1), r6.errorCount());
    var arena6 = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena6.deinit();
    try tt.expectEqualStrings(sb, (try fixAll(tt.allocator, arena6.allocator(), sbt)).text);
    // Ellen's skin on Lucia: error, fixed to 0
    const other = try std.mem.replaceOwned(u8, tt.allocator, with, ".skin_id = 0,", ".skin_id = 3111911,");
    defer tt.allocator.free(other);
    var r3 = try problemsFor(other);
    defer r3.deinit();
    try tt.expectEqual(@as(usize, 1), r3.errorCount());
    for (r3.problems) |p| {
        if (p.sev == .err) try tt.expect(std.mem.indexOf(u8, p.msg, "Ellen's skin") != null);
    }
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const res = try fixAll(tt.allocator, arena.allocator(), other);
    try tt.expectEqualStrings(with, res.text);
    // a form on a character without forms: only a check
    const txt = try std.mem.replaceOwned(u8, tt.allocator, with, ".form = null,", ".form = \"Eldreda\",");
    defer tt.allocator.free(txt);
    var r4 = try problemsFor(txt);
    defer r4.deinit();
    try tt.expectEqual(@as(usize, 0), r4.errorCount());
    try tt.expect(r4.problems.len == r0.problems.len + 1);
    // a form written as a name (.Eldreda) instead of text: error
    const en = try std.mem.replaceOwned(u8, tt.allocator, sb, "\"Eldreda\"", ".Eldreda");
    defer tt.allocator.free(en);
    var r7 = try problemsFor(en);
    defer r7.deinit();
    try tt.expectEqual(@as(usize, 1), r7.errorCount());
}

test "names renamed in the newer Remielle are fixed to the new ones" {
    const old = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "Bloodwing Nocturne [1]", "Crimson Wing Nocturne [1]");
    defer tt.allocator.free(old);
    var r = try problemsFor(old);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 1), r.errorCount());
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    try tt.expectEqualStrings(good_avatar, (try fixAll(tt.allocator, arena.allocator(), old)).text);
    try tt.expectEqualStrings("Monument of the Star [2]", (try renamedTo(arena.allocator(), "Rank Stele[2]")).?);
    try tt.expectEqualStrings("Avatar_Female_Size03_Kafka_En", (try renamedTo(arena.allocator(), "Kafka")).?);
}

test "keymap section (newer Remielle) is accepted" {
    const with = try std.mem.replaceOwned(u8, tt.allocator, good_avatar, "    .weapons_undressed", "    .keymap = .{\n        .keyboard = .{},\n        .mouse = .{},\n    },\n    .weapons_undressed");
    defer tt.allocator.free(with);
    try tt.expect(!std.mem.eql(u8, with, good_avatar));
    var r = try problemsFor(with);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 0), r.errorCount());
}
