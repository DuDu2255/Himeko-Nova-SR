//! Reads the community `freesr-data.json` format (as produced by SRTools and
//! consumed by March7thHoney's `FreesrCalyxData`) and lowers it into this
//! server's existing `GameConfig`, so nothing downstream needs to change.
//!
//! Two shapes differ meaningfully from ours:
//!   * relics/lightcones are flat lists tagged with `equip_avatar`, whereas we
//!     nest them under each avatar;
//!   * `battle_config.monsters` carries an `amount` per entry, whereas our
//!     `monster_wave` is a plain list of repeated ids.
//!
//! Every field is optional on the wire, so this parser never uses `.?`.

const std = @import("std");
const GameConfigMod = @import("game_config.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const GameConfig = GameConfigMod.GameConfig;
const BattleConfig = GameConfigMod.BattleConfig;
const Avatar = GameConfigMod.Avatar;
const Lightcone = GameConfigMod.Lightcone;
const Relic = GameConfigMod.Relic;

const log = std.log.scoped(.freesr);

pub const FILENAME = "freesr-data.json";

/// Our BattleAvatar multiplies `sp` by 100 against a fixed 10000 max, while
/// freesr stores raw sp points; convert between the two scales.
const SP_SCALE = 100;
const DEFAULT_SP = 50;
const DEFAULT_HP = 100;
const DEFAULT_BATTLE_ID = 1;

fn getInt(obj: std.json.Value, key: []const u8, fallback: u32) u32 {
    if (obj != .object) return fallback;
    const value = obj.object.get(key) orelse return fallback;
    return switch (value) {
        .integer => |i| if (i < 0) fallback else @intCast(i),
        .float => |f| if (f < 0) fallback else @intFromFloat(f),
        else => fallback,
    };
}

fn getArray(obj: std.json.Value, key: []const u8) ?[]std.json.Value {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    if (value != .array) return null;
    return value.array.items;
}

fn getObject(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    if (value != .object) return null;
    return value;
}

/// freesr keys avatars by id-as-string; fall back to the inner `avatar_id`.
fn resolveAvatarId(key: []const u8, value: std.json.Value) ?u32 {
    const inner = getInt(value, "avatar_id", 0);
    if (inner != 0) return inner;
    return std.fmt.parseInt(u32, key, 10) catch null;
}

fn parseRelic(entry: std.json.Value) Relic {
    var relic = Relic{
        .id = getInt(entry, "relic_id", 0),
        .level = getInt(entry, "level", 0),
        .main_affix_id = getInt(entry, "main_affix_id", 0),
        .sub_count = 0,
        .stat1 = 0,
        .cnt1 = 0,
        .step1 = 0,
        .stat2 = 0,
        .cnt2 = 0,
        .step2 = 0,
        .stat3 = 0,
        .cnt3 = 0,
        .step3 = 0,
        .stat4 = 0,
        .cnt4 = 0,
        .step4 = 0,
    };

    const subs = getArray(entry, "sub_affixes") orelse return relic;
    relic.sub_count = @intCast(@min(subs.len, 4));

    for (subs, 0..) |sub, i| {
        const id = getInt(sub, "sub_affix_id", 0);
        const cnt = getInt(sub, "count", 0);
        const step = getInt(sub, "step", 0);
        switch (i) {
            0 => {
                relic.stat1 = id;
                relic.cnt1 = cnt;
                relic.step1 = step;
            },
            1 => {
                relic.stat2 = id;
                relic.cnt2 = cnt;
                relic.step2 = step;
            },
            2 => {
                relic.stat3 = id;
                relic.cnt3 = cnt;
                relic.step3 = step;
            },
            3 => {
                relic.stat4 = id;
                relic.cnt4 = cnt;
                relic.step4 = step;
            },
            else => break,
        }
    }

    return relic;
}

fn parseBattleConfig(root: std.json.Value, allocator: Allocator) !BattleConfig {
    var battle = BattleConfig{
        .battle_id = DEFAULT_BATTLE_ID,
        .stage_id = 0,
        .cycle_count = 30,
        .monster_wave = ArrayList(ArrayList(u32)).init(allocator),
        .monster_level = 80,
        .blessings = ArrayList(u32).init(allocator),
    };
    errdefer {
        for (battle.monster_wave.items) |*wave| wave.deinit();
        battle.monster_wave.deinit();
        battle.blessings.deinit();
    }

    const cfg = getObject(root, "battle_config") orelse return battle;

    battle.stage_id = getInt(cfg, "stage_id", 0);
    battle.cycle_count = getInt(cfg, "cycle_count", 30);

    // We only carry a single global monster level; take the first one given.
    var level_found = false;

    if (getArray(cfg, "monsters")) |waves| {
        for (waves) |wave_value| {
            if (wave_value != .array) continue;
            var wave = ArrayList(u32).init(allocator);
            errdefer wave.deinit();

            for (wave_value.array.items) |entry| {
                const monster_id = getInt(entry, "monster_id", 0);
                if (monster_id == 0) continue;

                if (!level_found) {
                    const level = getInt(entry, "level", 0);
                    if (level != 0) {
                        battle.monster_level = level;
                        level_found = true;
                    }
                }

                // `amount` collapses repeated monsters; expand it back out.
                const amount = @max(getInt(entry, "amount", 1), 1);
                var n: u32 = 0;
                while (n < amount) : (n += 1) try wave.append(monster_id);
            }

            try battle.monster_wave.append(wave);
        }
    }

    if (getArray(cfg, "blessings")) |blessings| {
        for (blessings) |blessing| {
            const id = getInt(blessing, "id", 0);
            if (id != 0) try battle.blessings.append(id);
        }
    }

    // Path resonance is just another battle buff for our purposes.
    const resonance = getInt(cfg, "path_resonance_id", 0);
    if (resonance != 0) try battle.blessings.append(resonance);

    return battle;
}

pub fn parseConfig(root: std.json.Value, allocator: Allocator) anyerror!GameConfig {
    var battle_config = try parseBattleConfig(root, allocator);
    errdefer {
        for (battle_config.monster_wave.items) |*wave| wave.deinit();
        battle_config.monster_wave.deinit();
        battle_config.blessings.deinit();
    }

    var avatar_config = ArrayList(Avatar).init(allocator);
    errdefer {
        for (avatar_config.items) |*avatar| avatar.relics.deinit();
        avatar_config.deinit();
    }

    // Avatar id -> index into avatar_config, for attaching gear afterwards.
    var index_of = std.AutoHashMap(u32, usize).init(allocator);
    defer index_of.deinit();

    if (getObject(root, "avatars")) |avatars| {
        var it = avatars.object.iterator();
        while (it.next()) |kv| {
            const avatar_id = resolveAvatarId(kv.key_ptr.*, kv.value_ptr.*) orelse {
                log.warn("skipping avatar with unparsable key '{s}'", .{kv.key_ptr.*});
                continue;
            };

            const extra = getObject(kv.value_ptr.*, "data");

            const sp_value = getInt(kv.value_ptr.*, "sp_value", DEFAULT_SP * SP_SCALE);
            const techniques = getArray(kv.value_ptr.*, "techniques");

            var avatar = Avatar{
                .id = avatar_id,
                .hp = DEFAULT_HP,
                .sp = sp_value / SP_SCALE,
                .level = getInt(kv.value_ptr.*, "level", 80),
                .promotion = getInt(kv.value_ptr.*, "promotion", 6),
                .rank = if (extra) |e| getInt(e, "rank", 0) else 0,
                .lightcone = .{ .id = 0, .rank = 1, .level = 80, .promotion = 6 },
                .relics = ArrayList(Relic).init(allocator),
                .use_technique = techniques != null and techniques.?.len > 0,
            };
            errdefer avatar.relics.deinit();

            try index_of.put(avatar_id, avatar_config.items.len);
            try avatar_config.append(avatar);
        }
    }

    if (getArray(root, "lightcones")) |lightcones| {
        for (lightcones) |entry| {
            const equip_avatar = getInt(entry, "equip_avatar", 0);
            const idx = index_of.get(equip_avatar) orelse continue;
            avatar_config.items[idx].lightcone = .{
                .id = getInt(entry, "item_id", 0),
                .rank = @max(getInt(entry, "rank", 1), 1),
                .level = getInt(entry, "level", 80),
                .promotion = getInt(entry, "promotion", 6),
            };
        }
    }

    if (getArray(root, "relics")) |relics| {
        for (relics) |entry| {
            const equip_avatar = getInt(entry, "equip_avatar", 0);
            const idx = index_of.get(equip_avatar) orelse continue;
            const relic = parseRelic(entry);
            if (relic.id == 0) continue;
            try avatar_config.items[idx].relics.append(relic);
        }
    }

    log.info("loaded {d} avatars from {s}", .{ avatar_config.items.len, FILENAME });

    return GameConfig{
        .battle_config = battle_config,
        .avatar_config = avatar_config,
    };
}

/// Serialises the in-memory config back out in freesr shape, so the data can
/// round-trip through SRTools. Mirrors `FreesrShared.ExportPlayerDataAsync`.
pub fn stringify(config: *const GameConfig, allocator: Allocator) ![]u8 {
    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\n  \"avatars\": {");
    for (config.avatar_config.items, 0..) |avatar, i| {
        if (i != 0) try w.writeAll(",");
        try w.print(
            \\
            \\    "{d}": {{
            \\      "avatar_id": {d},
            \\      "level": {d},
            \\      "promotion": {d},
            \\      "sp_value": {d},
            \\      "sp_max": 10000,
            \\      "data": {{ "rank": {d}, "skills": {{}} }}
        , .{ avatar.id, avatar.id, avatar.level, avatar.promotion, avatar.sp * SP_SCALE, avatar.rank });

        if (avatar.use_technique) {
            try w.print(",\n      \"techniques\": [{d}]", .{avatar.id * 100 + 1});
        }
        try w.writeAll("\n    }");
    }
    try w.writeAll("\n  },\n  \"lightcones\": [");

    var first = true;
    for (config.avatar_config.items) |avatar| {
        if (avatar.lightcone.id == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print(
            \\
            \\    {{ "item_id": {d}, "level": {d}, "rank": {d}, "promotion": {d}, "equip_avatar": {d} }}
        , .{ avatar.lightcone.id, avatar.lightcone.level, avatar.lightcone.rank, avatar.lightcone.promotion, avatar.id });
    }
    try w.writeAll("\n  ],\n  \"relics\": [");

    first = true;
    for (config.avatar_config.items) |avatar| {
        for (avatar.relics.items) |relic| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print(
                \\
                \\    {{ "relic_id": {d}, "level": {d}, "main_affix_id": {d}, "equip_avatar": {d}, "sub_affixes": [
            , .{ relic.id, relic.level, relic.main_affix_id, avatar.id });

            const subs = [_][3]u32{
                .{ relic.stat1, relic.cnt1, relic.step1 },
                .{ relic.stat2, relic.cnt2, relic.step2 },
                .{ relic.stat3, relic.cnt3, relic.step3 },
                .{ relic.stat4, relic.cnt4, relic.step4 },
            };
            var wrote_sub = false;
            for (subs) |sub| {
                if (sub[0] == 0) continue;
                if (wrote_sub) try w.writeAll(", ");
                wrote_sub = true;
                try w.print(
                    "{{ \"sub_affix_id\": {d}, \"count\": {d}, \"step\": {d} }}",
                    .{ sub[0], sub[1], sub[2] },
                );
            }
            try w.writeAll("] }");
        }
    }

    const battle = config.battle_config;
    try w.print(
        \\
        \\  ],
        \\  "battle_config": {{
        \\    "battle_type": "Custom",
        \\    "stage_id": {d},
        \\    "cycle_count": {d},
        \\    "path_resonance_id": 0,
        \\    "monsters": [
    , .{ battle.stage_id, battle.cycle_count });

    for (battle.monster_wave.items, 0..) |wave, wi| {
        if (wi != 0) try w.writeAll(",");
        try w.writeAll("\n      [");
        for (wave.items, 0..) |monster_id, mi| {
            if (mi != 0) try w.writeAll(", ");
            try w.print(
                "{{ \"monster_id\": {d}, \"amount\": 1, \"level\": {d} }}",
                .{ monster_id, battle.monster_level },
            );
        }
        try w.writeAll("]");
    }

    try w.writeAll("\n    ],\n    \"blessings\": [");
    for (battle.blessings.items, 0..) |blessing, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{{ \"id\": {d}, \"level\": 1 }}", .{blessing});
    }
    try w.writeAll("]\n  }\n}\n");

    return out.toOwnedSlice();
}

test "parses avatars, gear and battle config, expanding monster amounts" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "avatars": {
        \\    "1310": { "level": 80, "promotion": 6, "sp_value": 6000,
        \\              "techniques": [131001],
        \\              "data": { "rank": 6, "skills": { "1013101": 10 } } }
        \\  },
        \\  "lightcones": [
        \\    { "item_id": 23026, "level": 80, "rank": 5, "promotion": 6, "equip_avatar": 1310 }
        \\  ],
        \\  "relics": [
        \\    { "relic_id": 61011, "level": 15, "main_affix_id": 1, "equip_avatar": 1310,
        \\      "sub_affixes": [ { "sub_affix_id": 8, "count": 4, "step": 4 },
        \\                       { "sub_affix_id": 9, "count": 2, "step": 2 } ] },
        \\    { "relic_id": 61012, "level": 15, "main_affix_id": 1, "equip_avatar": 9999 }
        \\  ],
        \\  "battle_config": {
        \\    "stage_id": 201012311, "cycle_count": 20, "path_resonance_id": 122001,
        \\    "monsters": [ [ { "monster_id": 3011010, "amount": 3, "level": 95 } ] ],
        \\    "blessings": [ { "id": 12345, "level": 1 } ]
        \\  }
        \\}
    ;

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer tree.deinit();

    var config = try parseConfig(tree.value, allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.avatar_config.items.len);
    const avatar = config.avatar_config.items[0];
    try std.testing.expectEqual(@as(u32, 1310), avatar.id);
    try std.testing.expectEqual(@as(u32, 6), avatar.rank);
    try std.testing.expectEqual(@as(u32, 60), avatar.sp);
    try std.testing.expect(avatar.use_technique);
    try std.testing.expectEqual(@as(u32, 23026), avatar.lightcone.id);

    // The relic bound to an unknown avatar must be dropped, not misassigned.
    try std.testing.expectEqual(@as(usize, 1), avatar.relics.items.len);
    try std.testing.expectEqual(@as(u32, 2), avatar.relics.items[0].sub_count);
    try std.testing.expectEqual(@as(u32, 8), avatar.relics.items[0].stat1);
    try std.testing.expectEqual(@as(u32, 4), avatar.relics.items[0].step1);

    try std.testing.expectEqual(@as(u32, 201012311), config.battle_config.stage_id);
    try std.testing.expectEqual(@as(u32, 20), config.battle_config.cycle_count);
    try std.testing.expectEqual(@as(u32, 95), config.battle_config.monster_level);
    try std.testing.expectEqual(@as(usize, 3), config.battle_config.monster_wave.items[0].items.len);
    // blessings plus the path resonance id appended.
    try std.testing.expectEqual(@as(usize, 2), config.battle_config.blessings.items.len);
}

test "tolerates a nearly empty document" {
    const allocator = std.testing.allocator;

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer tree.deinit();

    var config = try parseConfig(tree.value, allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.avatar_config.items.len);
    try std.testing.expectEqual(@as(usize, 0), config.battle_config.monster_wave.items.len);
}

test "round-trips through stringify" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "avatars": { "1310": { "level": 78, "promotion": 6, "sp_value": 5000,
        \\                         "data": { "rank": 2 } } },
        \\  "lightcones": [ { "item_id": 23026, "level": 80, "rank": 5, "promotion": 6, "equip_avatar": 1310 } ],
        \\  "relics": [ { "relic_id": 61011, "level": 15, "main_affix_id": 1, "equip_avatar": 1310,
        \\                "sub_affixes": [ { "sub_affix_id": 8, "count": 4, "step": 4 } ] } ],
        \\  "battle_config": { "stage_id": 12345, "cycle_count": 11,
        \\                     "monsters": [ [ { "monster_id": 3011010, "amount": 2, "level": 90 } ] ],
        \\                     "blessings": [] }
        \\}
    ;

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer tree.deinit();

    var original = try parseConfig(tree.value, allocator);
    defer original.deinit();

    const text = try stringify(&original, allocator);
    defer allocator.free(text);

    var tree2 = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer tree2.deinit();

    var reparsed = try parseConfig(tree2.value, allocator);
    defer reparsed.deinit();

    try std.testing.expectEqual(original.avatar_config.items.len, reparsed.avatar_config.items.len);
    try std.testing.expectEqual(original.avatar_config.items[0].level, reparsed.avatar_config.items[0].level);
    try std.testing.expectEqual(original.avatar_config.items[0].sp, reparsed.avatar_config.items[0].sp);
    try std.testing.expectEqual(
        original.avatar_config.items[0].lightcone.id,
        reparsed.avatar_config.items[0].lightcone.id,
    );
    try std.testing.expectEqual(
        original.avatar_config.items[0].relics.items[0].stat1,
        reparsed.avatar_config.items[0].relics.items[0].stat1,
    );
    try std.testing.expectEqual(original.battle_config.stage_id, reparsed.battle_config.stage_id);
    try std.testing.expectEqual(original.battle_config.monster_level, reparsed.battle_config.monster_level);
    try std.testing.expectEqual(
        original.battle_config.monster_wave.items[0].items.len,
        reparsed.battle_config.monster_wave.items[0].items.len,
    );
}
