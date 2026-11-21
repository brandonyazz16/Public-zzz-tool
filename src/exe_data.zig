//! Reads character base stats straight out of remielle.exe.
//!
//! Remielle bakes the game's character tables into its .exe as columns of
//! little-endian u32 values. Two tables sit side by side, field by field:
//!   A: one row per character id   (e.g. 120 rows: 1011, 1021, ...)
//!   T: one row per character variant (e.g. 109 rows, ids repeat for skins)
//! Layout: [A ids][T template ids] then for every field [A values][T values],
//! followed by [T character ids]. A separate ascension table holds, for every
//! character and rank 1..6, the HP / ATK / DEF added at that rank.
//!
//! Nothing here uses fixed addresses: the tables are found by their shape,
//! and every field is checked (A and T must agree for every variant row), so a
//! new Remielle build either decodes correctly or is reported as unreadable.

const std = @import("std");

pub const Stats = struct {
    id: u32,
    hp: u32,
    atk: u32,
    def: u32,
    impact: u32,
    crit_rate: u32, // in 1/100 %, 500 = 5%
    crit_dmg: u32, // in 1/100 %, 5000 = 50%
    anomaly_mastery: u32,
    anomaly_proficiency: u32,
    energy_regen: u32, // in 1/100, 120 = 1.2 ; 0 = uses Adrenaline (Rupture)

    pub fn isRupture(s: Stats) bool {
        return s.energy_regen == 0;
    }
};

// Field indexes inside the A/T column pairs (confirmed against in-game numbers).
const F_HP = 0;
const F_HP_GROWTH = 1;
const F_ATK = 2;
const F_ATK_GROWTH = 3;
const F_DEF = 4;
const F_DEF_GROWTH = 5;
const F_CRIT_RATE = 6;
const F_CRIT_DMG = 7;
const F_IMPACT = 14;
const F_AM = 15;
const F_ENERGY = 16;
const F_AP = 18;
const FIELD_COUNT = 23;

pub const DecodeError = error{ TableNotFound, AscensionNotFound, TableMismatch, OutOfMemory };

fn word(bytes: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, bytes[i..][0..4], .little);
}

fn isCharId(v: u32) bool {
    return v >= 1000 and v < 100_000;
}

/// Finds the per-character table (A). Returns the byte offset of its id column.
fn findMainTable(bytes: []const u8) ?struct { a_off: usize, n: usize, m: usize } {
    var i: usize = 0;
    while (i + 12 <= bytes.len) : (i += 4) {
        if (word(bytes, i) != 1011 or word(bytes, i + 4) != 1021 or word(bytes, i + 8) != 1031) continue;
        // run of ids
        var n: usize = 0;
        while (i + 4 * (n + 1) <= bytes.len and isCharId(word(bytes, i + 4 * n))) n += 1;
        // followed by template ids (>= 1,000,000)
        const t_off = i + 4 * n;
        var m: usize = 0;
        while (t_off + 4 * (m + 1) <= bytes.len) : (m += 1) {
            const v = word(bytes, t_off + 4 * m);
            if (v < 1_000_000 or v >= 100_000_000) break;
        }
        if (n >= 20 and m >= 20 and m <= n) return .{ .a_off = i, .n = n, .m = m };
    }
    return null;
}

/// Finds the ascension table: ids where each character repeats 6 times, then a rank column 1..6.
fn findAscension(bytes: []const u8) ?struct { off: usize, rows: usize } {
    var i: usize = 0;
    outer: while (i + 4 * 12 <= bytes.len) : (i += 4) {
        for (0..6) |k| if (word(bytes, i + 4 * k) != 1011) continue :outer;
        if (word(bytes, i + 4 * 6) != 1021) continue;
        var rows: usize = 0;
        while (i + 4 * (rows + 1) <= bytes.len and isCharId(word(bytes, i + 4 * rows))) rows += 1;
        if (rows % 6 != 0 or rows < 60) continue;
        // rank column right after must read 1,2,3,4,5,6
        const r_off = i + 4 * rows;
        if (r_off + 4 * 6 > bytes.len) continue;
        for (0..6) |k| if (word(bytes, r_off + 4 * k) != k + 1) continue :outer;
        // HP added per rank (column after rank): 0 at rank 1, then rising to a few thousand at rank 6
        const hp_off = i + 8 * rows;
        if (hp_off + 4 * 6 > bytes.len) continue;
        if (word(bytes, hp_off) != 0) continue;
        var prev: u32 = 0;
        for (1..6) |k| {
            const v = word(bytes, hp_off + 4 * k);
            if (v <= prev) continue :outer;
            prev = v;
        }
        if (prev < 500 or prev > 20_000) continue;
        return .{ .off = i, .rows = rows };
    }
    return null;
}

/// Decodes level-60 (rank 6) base stats for every character in the exe.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]Stats {
    const t = findMainTable(bytes) orelse return error.TableNotFound;
    const n = t.n;
    const m = t.m;
    const field_base = t.a_off + 4 * n + 4 * m; // after [A ids][T template ids]
    const pair = 4 * (n + m);
    // The variant table's character-id column: a run of exactly m ids starting with 1011, after the fields.
    const t_ids_off = blk: {
        var i: usize = field_base + pair * FIELD_COUNT;
        const stop = @min(bytes.len, i + pair * 4);
        while (i + 4 * m <= stop) : (i += 4) {
            if (word(bytes, i) != 1011 or isCharId(word(bytes, i - 4))) continue;
            var len: usize = 0;
            while (i + 4 * (len + 1) <= bytes.len and isCharId(word(bytes, i + 4 * len))) len += 1;
            if (len == m) break :blk i;
        }
        return error.TableMismatch;
    };

    // Validate every field: each variant row (T) must equal its character's row (A).
    // (A few variant ids may have no row in A; those are skipped, but most must match.)
    var checked: usize = 0;
    for (0..FIELD_COUNT) |f| {
        const a_col = field_base + pair * f;
        const t_col = a_col + 4 * n;
        for (0..m) |r| {
            const cid = word(bytes, t_ids_off + 4 * r);
            const ai = for (0..n) |k| {
                if (word(bytes, t.a_off + 4 * k) == cid) break k;
            } else continue;
            if (word(bytes, a_col + 4 * ai) != word(bytes, t_col + 4 * r)) return error.TableMismatch;
            checked += 1;
        }
    }
    if (checked < FIELD_COUNT * m * 9 / 10) return error.TableMismatch;

    const asc = findAscension(bytes) orelse return error.AscensionNotFound;
    const R = asc.rows;

    var out: std.ArrayList(Stats) = .empty;
    errdefer out.deinit(gpa);
    for (0..n) |k| {
        const id = word(bytes, t.a_off + 4 * k);
        // rank-6 ascension bonus
        var add_hp: u32 = 0;
        var add_atk: u32 = 0;
        var add_def: u32 = 0;
        for (0..R) |r| {
            if (word(bytes, asc.off + 4 * r) != id) continue;
            if (word(bytes, asc.off + 4 * R + 4 * r) != 6) continue;
            add_hp = word(bytes, asc.off + 8 * R + 4 * r);
            add_atk = word(bytes, asc.off + 12 * R + 4 * r);
            add_def = word(bytes, asc.off + 16 * R + 4 * r);
        }
        const lv60 = struct {
            // base + growth * 59 / 10000 + ascension, rounded down (the game's formula)
            fn f(base: u32, growth: u32, add: u32) u32 {
                return base + @as(u32, @intCast((@as(u64, growth) * 59) / 10_000)) + add;
            }
        }.f;
        try out.append(gpa, .{
            .id = id,
            .hp = lv60(word(bytes, field_base + pair * F_HP + 4 * k), word(bytes, field_base + pair * F_HP_GROWTH + 4 * k), add_hp),
            .atk = lv60(word(bytes, field_base + pair * F_ATK + 4 * k), word(bytes, field_base + pair * F_ATK_GROWTH + 4 * k), add_atk),
            .def = lv60(word(bytes, field_base + pair * F_DEF + 4 * k), word(bytes, field_base + pair * F_DEF_GROWTH + 4 * k), add_def),
            .impact = word(bytes, field_base + pair * F_IMPACT + 4 * k),
            .crit_rate = word(bytes, field_base + pair * F_CRIT_RATE + 4 * k),
            .crit_dmg = word(bytes, field_base + pair * F_CRIT_DMG + 4 * k),
            .anomaly_mastery = word(bytes, field_base + pair * F_AM + 4 * k),
            .anomaly_proficiency = word(bytes, field_base + pair * F_AP + 4 * k),
            .energy_regen = word(bytes, field_base + pair * F_ENERGY + 4 * k),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn find(list: []const Stats, id: u32) ?Stats {
    for (list) |s| if (s.id == id) return s;
    return null;
}

// Numbers confirmed in game (screenshots), used to prove the decoder.
const Confirmed = struct { id: u32, hp: u32, atk: u32, def: u32, impact: u32 };
const confirmed = [_]Confirmed{
    .{ .id = 1471, .hp = 8497, .atk = 784, .def = 445, .impact = 95 }, // Banyue
    .{ .id = 1451, .hp = 8477, .atk = 683, .def = 594, .impact = 83 }, // Lucia
    .{ .id = 1461, .hp = 7673, .atk = 854, .def = 612, .impact = 93 }, // Seed
    .{ .id = 1481, .hp = 8250, .atk = 683, .def = 612, .impact = 110 }, // Dialyn
    .{ .id = 1311, .hp = 8609, .atk = 640, .def = 600, .impact = 83 }, // Astra Yao
};

test "decoder matches in-game numbers (put your remielle.exe in testdata/)" {
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "testdata/remielle.exe", std.testing.allocator, .limited(64 << 20)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    const list = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(list);
    for (confirmed) |c| {
        const s = find(list, c.id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.hp, s.hp);
        try std.testing.expectEqual(c.atk, s.atk);
        try std.testing.expectEqual(c.def, s.def);
        try std.testing.expectEqual(c.impact, s.impact);
    }
}


// ---------------- W-Engines ----------------

pub const WEngine = struct {
    id: u32,
    /// stat ids from the game: 12101 Base ATK, 13101 Base DEF, 11101 Base HP
    base_stat: u32,
    /// level-60 value of the base stat
    base: u32,
    /// the advanced stat's id (12102 ATK%, 20103 CRIT Rate, 30502 Energy Regen, ...)
    adv_stat: u32,
    /// level-60 value: percent stats in 1/100 % (3600 = 36%), flat stats as-is (75 = 75 AP)
    adv: u32,

    pub fn rarity(w: WEngine) u8 {
        return switch (w.id / 1000) {
            12 => 'B',
            13 => 'A',
            14 => 'S',
            else => '?',
        };
    }
};

/// Name and unit for a W-Engine stat id.
pub fn statName(id: u32) struct { name: []const u8, pct: bool } {
    return switch (id) {
        11101 => .{ .name = "Base HP", .pct = false },
        12101 => .{ .name = "Base ATK", .pct = false },
        13101 => .{ .name = "Base DEF", .pct = false },
        11102 => .{ .name = "HP", .pct = true },
        12102 => .{ .name = "ATK", .pct = true },
        13102 => .{ .name = "DEF", .pct = true },
        12202 => .{ .name = "Impact", .pct = true },
        20103 => .{ .name = "CRIT Rate", .pct = true },
        21103 => .{ .name = "CRIT DMG", .pct = true },
        23103 => .{ .name = "PEN Ratio", .pct = true },
        30502 => .{ .name = "Energy Regen", .pct = true },
        31203 => .{ .name = "Anomaly Proficiency", .pct = false },
        31402 => .{ .name = "Anomaly Mastery", .pct = true },
        else => .{ .name = "?", .pct = false },
    };
}

fn isWengId(v: u32) bool {
    return v >= 12000 and v < 15000;
}
fn isBaseStat(v: u32) bool {
    return v == 11101 or v == 12101 or v == 13101;
}

/// Reads every W-Engine's level-60 stats from remielle.exe.
///
/// Layout: a sorted list of W-Engine ids; after it, one (stat, value) pair per W-Engine for the
/// base stat, then one pair each for the advanced stat. The game turns the level-1 values into
/// level 60 with its level table (rate at level 60) and rank table (rate at max rank):
///   base at 60 = value x (10000 + level rate + rank rate) / 10000, rounded down
///   advanced at 60 = value x 2.5
pub fn decodeWEngines(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]WEngine {
    // 1. sorted id lists (runs of increasing W-Engine ids starting at 12001); 2. the one that is
    //    followed (within 64 KB) by one base-stat (stat, value) pair per W-Engine
    var best_off: usize = 0;
    var n: usize = 0;
    var pairs: usize = 0;
    var i: usize = 0;
    search: while (i + 4 <= bytes.len) : (i += 4) {
        if (word(bytes, i) != 12001) continue;
        var cnt: usize = 1;
        while (i + 4 * (cnt + 1) <= bytes.len and isWengId(word(bytes, i + 4 * cnt)) and word(bytes, i + 4 * cnt) > word(bytes, i + 4 * (cnt - 1))) cnt += 1;
        if (cnt < 30) continue;
        const ids_end = i + 4 * cnt;
        if (bytes.len < 16 * cnt) continue;
        var p = ids_end;
        const stop = @min(bytes.len - 16 * cnt, ids_end + 64 * 1024);
        while (p < stop) : (p += 4) {
            var ok = true;
            for (0..cnt) |k| if (!isBaseStat(word(bytes, p + 8 * k))) {
                ok = false;
                break;
            };
            if (ok and !isBaseStat(word(bytes, p - 8))) {
                best_off = i;
                n = cnt;
                pairs = p;
                break :search;
            }
        }
    }
    if (n == 0) return error.TableNotFound;
    // 3. level and rank rates
    const mult = try weaponMultiplier(bytes);

    var out = try gpa.alloc(WEngine, n);
    for (0..n) |k| {
        const bstat = word(bytes, pairs + 8 * k);
        const bval = word(bytes, pairs + 8 * k + 4);
        const astat = word(bytes, pairs + 8 * (n + k));
        const aval = word(bytes, pairs + 8 * (n + k) + 4);
        out[k] = .{
            .id = word(bytes, best_off + 4 * k),
            .base_stat = bstat,
            .base = @intCast(@as(u64, bval) * mult / 10_000),
            .adv_stat = astat,
            .adv = aval * 25 / 10,
        };
    }
    return out;
}

/// 10000 + level-60 rate + max-rank rate, from the game's W-Engine level and rank tables.
/// Level table: 61 values (levels 0..60) starting 0, 1568, 3136, ..., stored three times (per rarity).
/// Rank table: 0, x, 2x, ... 5x.
fn weaponMultiplier(bytes: []const u8) DecodeError!u64 {
    var level60: ?u32 = null;
    var i: usize = 0;
    while (i + 4 * 61 <= bytes.len) : (i += 4) {
        if (word(bytes, i) != 0) continue;
        const step = word(bytes, i + 4);
        if (step < 1000 or step > 5000) continue;
        var ok = true;
        for (1..61) |k| if (word(bytes, i + 4 * k) <= word(bytes, i + 4 * (k - 1))) {
            ok = false;
            break;
        };
        if (!ok) continue;
        // the real table is stored three times in a row (one per rarity)
        if (i + 4 * 61 * 3 > bytes.len) continue;
        var same = true;
        for (0..61) |k| if (word(bytes, i + 4 * 61 + 4 * k) != word(bytes, i + 4 * k) or word(bytes, i + 8 * 61 + 4 * k) != word(bytes, i + 4 * k)) {
            same = false;
            break;
        };
        if (!same) continue;
        level60 = word(bytes, i + 4 * 60);
        break;
    }
    const lv = level60 orelse return error.TableNotFound;
    // rank table: 0, x, 2x, 3x, 4x, 5x with x in the thousands, the first one after the level table
    i += 4 * 61 * 3;
    while (i + 4 * 6 <= bytes.len) : (i += 4) {
        if (word(bytes, i) != 0) continue;
        const x = word(bytes, i + 4);
        if (x < 3000 or x > 20000) continue;
        var ok = true;
        for (2..6) |k| if (word(bytes, i + 4 * k) != x * @as(u32, @intCast(k))) {
            ok = false;
            break;
        };
        if (ok) return 10_000 + @as(u64, lv) + 5 * @as(u64, x);
    }
    return error.TableNotFound;
}

// Level-60 numbers from the website, confirmed in game (base stat, advanced stat in 1/100 % or flat).
const WengConfirmed = struct { id: u32, base: u32, adv: u32 };
const weng_confirmed = [_]WengConfirmed{
    .{ .id = 13017, .base = 356, .adv = 4000 },
    .{ .id = 13018, .base = 594, .adv = 75 },
    .{ .id = 13020, .base = 594, .adv = 1500 },
    .{ .id = 13021, .base = 356, .adv = 2000 },
    .{ .id = 13022, .base = 356, .adv = 4000 },
    .{ .id = 14102, .base = 684, .adv = 2400 },
    .{ .id = 14104, .base = 684, .adv = 3000 },
    .{ .id = 14105, .base = 713, .adv = 3000 },
    .{ .id = 14107, .base = 713, .adv = 1800 },
    .{ .id = 14109, .base = 743, .adv = 2400 },
    .{ .id = 14110, .base = 684, .adv = 1800 },
    .{ .id = 14114, .base = 684, .adv = 1800 },
    .{ .id = 14116, .base = 713, .adv = 1800 },
    .{ .id = 14117, .base = 713, .adv = 3000 },
    .{ .id = 14118, .base = 684, .adv = 2400 },
    .{ .id = 14119, .base = 713, .adv = 2400 },
    .{ .id = 14120, .base = 713, .adv = 4800 },
    .{ .id = 14121, .base = 684, .adv = 2400 },
    .{ .id = 14122, .base = 713, .adv = 3000 },
    .{ .id = 14124, .base = 713, .adv = 4800 },
    .{ .id = 14125, .base = 713, .adv = 1800 },
    .{ .id = 14126, .base = 713, .adv = 90 },
    .{ .id = 14129, .base = 713, .adv = 2400 },
    .{ .id = 14130, .base = 713, .adv = 6000 },
    .{ .id = 14131, .base = 713, .adv = 3000 },
    .{ .id = 14132, .base = 713, .adv = 2400 },
    .{ .id = 14133, .base = 713, .adv = 90 },
    .{ .id = 14134, .base = 713, .adv = 3000 },
    .{ .id = 14136, .base = 713, .adv = 2400 },
    .{ .id = 14137, .base = 743, .adv = 3000 },
    .{ .id = 14138, .base = 713, .adv = 4800 },
    .{ .id = 14139, .base = 713, .adv = 3000 },
    .{ .id = 14140, .base = 713, .adv = 3000 },
    .{ .id = 14141, .base = 713, .adv = 6000 },
    .{ .id = 14143, .base = 743, .adv = 4800 },
    .{ .id = 14145, .base = 713, .adv = 3000 },
    .{ .id = 14146, .base = 713, .adv = 2400 },
    .{ .id = 14147, .base = 713, .adv = 3000 },
    .{ .id = 14148, .base = 713, .adv = 2400 },
    .{ .id = 14149, .base = 713, .adv = 6000 },
    .{ .id = 14150, .base = 713, .adv = 3000 },
    .{ .id = 14151, .base = 713, .adv = 3000 },
    .{ .id = 14152, .base = 713, .adv = 6000 },
    .{ .id = 14153, .base = 713, .adv = 3000 },
    .{ .id = 14154, .base = 713, .adv = 3000 },
    .{ .id = 14155, .base = 713, .adv = 3000 },
    .{ .id = 14156, .base = 713, .adv = 6000 },
    .{ .id = 14157, .base = 713, .adv = 2400 },
    .{ .id = 14158, .base = 743, .adv = 3600 },
    .{ .id = 14159, .base = 713, .adv = 4800 },
    .{ .id = 14160, .base = 446, .adv = 4800 },
    .{ .id = 14161, .base = 431, .adv = 4800 },
    .{ .id = 14162, .base = 713, .adv = 6000 },
    .{ .id = 14163, .base = 713, .adv = 2400 },
    .{ .id = 14164, .base = 713, .adv = 3000 },
    .{ .id = 14165, .base = 713, .adv = 6000 },
    .{ .id = 14166, .base = 713, .adv = 3000 },
};

test "W-Engine decoder matches all confirmed W-Engines (put your remielle.exe in testdata/)" {
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "testdata/remielle.exe", std.testing.allocator, .limited(64 << 20)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    const list = try decodeWEngines(std.testing.allocator, bytes);
    defer std.testing.allocator.free(list);
    var checked: usize = 0;
    for (weng_confirmed) |c| {
        const w = for (list) |x| {
            if (x.id == c.id) break x;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.base, w.base);
        try std.testing.expectEqual(c.adv, w.adv);
        checked += 1;
    }
    try std.testing.expectEqual(weng_confirmed.len, checked);
}

// ---------------- Skins ----------------

/// One skin: its id (the .zon's skin_id) and the character (or form / Proxy) it belongs to.
pub const Skin = struct { id: u32, owner: u32 };

/// Is `skin` one of `owner`'s skin ids? They're <prefix><owner><n>, e.g. Ellen (1191):
/// 3111910, 3111911 (prefix 31).
fn skinOf(skin: u32, owner: u32) bool {
    if (skin < 1_000_000 or skin > 99_999_999 or owner < 1000) return false;
    // the Proxies (Wise / Belle, ids 2xxx) number theirs on their own: 41201xx, 41202xx, ...
    if (owner >= 2000) return skin / 100_000 == 41;
    return (skin % 100_000) / 10 == owner;
}

/// The skin table: a column of skin ids right before a column of their owners' ids (sorted,
/// owners repeat once per skin). Found by that shape, like the other tables.
pub fn decodeSkins(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]Skin {
    const n = bytes.len / 4;
    var i: usize = 0;
    while (i < n) {
        // a run of owner ids, never going down
        if (!isCharId(word(bytes, i * 4)) or word(bytes, i * 4) >= 10_000) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < n and word(bytes, j * 4) >= 1000 and word(bytes, j * 4) < 10_000 and word(bytes, j * 4) >= word(bytes, (j - 1) * 4)) j += 1;
        const len = j - i;
        if (len >= 40 and i >= len) {
            // the column before must hold one skin id per owner
            const ok = for (0..len) |k| {
                if (!skinOf(word(bytes, (i - len + k) * 4), word(bytes, (i + k) * 4))) break false;
            } else true;
            if (ok) {
                const out = try gpa.alloc(Skin, len);
                for (0..len) |k| out[k] = .{ .id = word(bytes, (i - len + k) * 4), .owner = word(bytes, (i + k) * 4) };
                return out;
            }
        }
        i = j;
    }
    return error.TableNotFound;
}

test "skin table (put your remielle.exe in testdata/)" {
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "testdata/remielle.exe", std.testing.allocator, .limited(64 << 20)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    const skins = decodeSkins(std.testing.allocator, bytes) catch |e| {
        // remielle.exe builds before skins existed have no table
        if (e == error.TableNotFound) return error.SkipZigTest;
        return e;
    };
    defer std.testing.allocator.free(skins);
    var ellen: usize = 0;
    for (skins) |s| if (s.owner == 1191) {
        ellen += 1;
        try std.testing.expect(s.id == 3111910 or s.id == 3111911);
    };
    try std.testing.expectEqual(@as(usize, 2), ellen);
}

// ---------------- Names (for Check file) ----------------

/// The names in remielle.exe's text table, by kind, read from the "key, text" pairs the exe
/// stores one after the other: Item_Weapon_*_Name -> W-Engine, Item_Equipment_*_name -> disc
/// piece, SectionName_* -> place, Avatar_*_En -> character (also NPCs and forms). `all` holds
/// every text in the exe, to tell whether a name still exists at all.
pub const Names = struct {
    arena: std.heap.ArenaAllocator,
    w_engines: []const []const u8,
    discs: []const []const u8,
    sections: []const []const u8,
    avatars: []const []const u8,
    all: std.StringHashMapUnmanaged(void),

    pub fn deinit(n: *Names) void {
        n.arena.deinit();
    }
    pub fn has(n: *const Names, s: []const u8) bool {
        return n.all.contains(s);
    }
};

fn isKey(s: []const u8) bool {
    for ([_][]const u8{ "Item_", "Avatar_", "SectionName_", "AvatarSkin_", "AvatarForm_", "AvatarVersion_" }) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}
fn looksLikeName(s: []const u8) bool {
    if (s.len < 2 or s.len > 80) return false;
    var letters: usize = 0;
    for (s) |ch| {
        if (std.ascii.isAlphabetic(ch)) letters += 1;
    }
    return letters >= 2 and (std.ascii.isAlphanumeric(s[0]) or s[0] == '[');
}

pub fn decodeNames(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Names {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // the exe's texts: runs of printable characters (2+), in order
    var texts: std.ArrayList([]const u8) = .empty;
    var all: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] < 0x20 or bytes[i] > 0x7e) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] <= 0x7e) j += 1;
        if (j - i >= 2) {
            const t = bytes[i..j]; // points into `bytes`: copied below only for what's kept
            try texts.append(a, t);
        }
        i = j;
    }
    var w: std.ArrayList([]const u8) = .empty;
    var d: std.ArrayList([]const u8) = .empty;
    var s: std.ArrayList([]const u8) = .empty;
    var av: std.ArrayList([]const u8) = .empty;
    for (texts.items, 0..) |t, k| {
        try all.put(a, try a.dupe(u8, t), {});
        if (k + 1 >= texts.items.len) continue;
        const nx = texts.items[k + 1];
        const has_text = !isKey(nx) and looksLikeName(nx);
        const val = if (has_text) try a.dupe(u8, nx) else null;
        if (std.mem.startsWith(u8, t, "Item_Weapon_") and std.mem.endsWith(u8, t, "_Name")) {
            if (val) |v| try w.append(a, v);
        } else if (std.mem.startsWith(u8, t, "Item_Equipment_") and std.mem.endsWith(u8, t, "_name")) {
            if (val) |v| try d.append(a, v);
        } else if (std.mem.startsWith(u8, t, "SectionName_")) {
            if (val) |v| try s.append(a, v);
        } else if (std.mem.startsWith(u8, t, "Avatar_") and std.mem.endsWith(u8, t, "_En")) {
            // no text: the server uses the key itself (Avatar_Female_Size03_Kafka_En)
            try av.append(a, val orelse try a.dupe(u8, t));
        }
    }
    return .{ .arena = arena, .w_engines = w.items, .discs = d.items, .sections = s.items, .avatars = av.items, .all = all };
}

test "names from the exe (put your remielle.exe in testdata/)" {
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "testdata/remielle.exe", std.testing.allocator, .limited(64 << 20)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);
    var n = try decodeNames(std.testing.allocator, bytes);
    defer n.deinit();
    const has = struct {
        fn f(l: []const []const u8, x: []const u8) bool {
            for (l) |y| if (std.mem.eql(u8, x, y)) return true;
            return false;
        }
    }.f;
    try std.testing.expect(has(n.w_engines, "Plume of Rebirth"));
    try std.testing.expect(has(n.discs, "Astral Voice [1]"));
    try std.testing.expect(has(n.sections, "Video Store"));
    try std.testing.expect(has(n.avatars, "Miyabi"));
    try std.testing.expect(n.has("Anby"));
}
