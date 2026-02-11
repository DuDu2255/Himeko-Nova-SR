// gameserver/src/player_state.zig
const std = @import("std");
const Data = @import("data.zig");
const BattleManager = @import("./manager/battle_mgr.zig");
const Logic = @import("./utils/logic.zig");
const ConfigManager = @import("./manager/config_mgr.zig");

const Allocator = std.mem.Allocator;
const Position = struct {
    plane_id: u32,
    floor_id: u32,
    entry_id: u32,
    teleport_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    use_coordinates: bool = false,
};
const LineupManager = @import("./manager/lineup_mgr.zig");

pub const LineupSlots: usize = 4;
pub const MaxLineups: usize = 6;
pub const LineupPreset = [LineupSlots]u32;

pub const PlayerState = struct {
    uid: u32,
    level: u32,
    world_level: u32,
    stamina: u32,
    mcoin: u32,
    hcoin: u32,
    scoin: u32,
    position: Position,
    cur_lineup_index: u32,
    lineups: [MaxLineups]LineupPreset,

    pub fn init(_: Allocator, uid: u32) PlayerState {
        return .{
            .uid = uid,
            .level = 0,
            .world_level = 0,
            .stamina = 0,
            .mcoin = 0,
            .hcoin = 0,
            .scoin = 0,
            .position = .{ .plane_id = 0, .floor_id = 0, .entry_id = 0, .teleport_id = 0 },
            .cur_lineup_index = 0,
            .lineups = std.mem.zeroes([MaxLineups]LineupPreset),
        };
    }

    pub fn deinit(_: *PlayerState) void {}
};

fn getMainPathAvatarId() u32 {
    const gender = ConfigManager.global_misc_defaults.mc_gender;
    const path = ConfigManager.global_misc_defaults.mc_path;
    const base: u32 = switch (path) {
        .warrior => 0,
        .knight => 1,
        .shaman => 2,
        .memory => 3,
    };
    const offset: u32 = if (gender == .male) 0 else 1;
    return 8001 + base * 2 + offset;
}

fn getM7PathAvatarId() u32 {
    return switch (ConfigManager.global_misc_defaults.m7th_path) {
        .knight => 1001,
        .rogue => 1224,
    };
}

fn trailblazerPathName(path: @TypeOf(ConfigManager.global_misc_defaults.mc_path)) []const u8 {
    return switch (path) {
        .warrior => "Destruction",
        .knight => "Preservation",
        .shaman => "Harmony",
        .memory => "Remembrance",
    };
}

fn marchPathName(path: @TypeOf(ConfigManager.global_misc_defaults.m7th_path)) []const u8 {
    return switch (path) {
        .knight => "Preservation",
        .rogue => "The Hunt",
    };
}

fn isEnhancedAvatar(avatar_id: u32) bool {
    for (Data.EnhanceAvatarID) |id| {
        if (id == avatar_id) return true;
    }
    return false;
}

fn writeU32Array(writer: anytype, items: []const u32) !void {
    try writer.writeAll("[");
    for (items, 0..) |v, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{v});
    }
    try writer.writeAll("]");
}

fn writeLineupPresets(writer: anytype, presets: [MaxLineups]LineupPreset) !void {
    try writer.writeAll("[");
    for (presets, 0..) |preset, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeU32Array(writer, preset[0..]);
    }
    try writer.writeAll("]");
}

pub fn save(state: *PlayerState) !void {
    const cwd = std.fs.cwd();
    const safe_idx: u32 = if (state.cur_lineup_index < MaxLineups) state.cur_lineup_index else 0;

    var file = try cwd.createFile("misc.json", .{ .truncate = true });
    defer file.close();
    var w = file.writer();

    try w.writeAll("{\n");
    try w.writeAll("  \"leader\": 0,\n");

    try w.writeAll("  \"lineup\": {\n");
    try w.print("    \"current_index\": {d},\n", .{safe_idx});
    try w.writeAll("    \"presets\": ");
    try writeLineupPresets(w, state.lineups);
    try w.writeAll("\n  },\n");

    try w.writeAll("  \"position\": {\n");
    try w.print("    \"x\": {d},\n", .{state.position.x});
    try w.print("    \"y\": {d},\n", .{state.position.y});
    try w.print("    \"z\": {d},\n", .{state.position.z});
    try w.writeAll("    \"rot_y\": 0,\n");
    try w.print("    \"use_coordinates\": {s}\n", .{if (state.position.use_coordinates) "true" else "false"});
    try w.writeAll("  },\n");

    try w.writeAll("  \"scene\": {\n");
    try w.print("    \"plane_id\": {d},\n", .{state.position.plane_id});
    try w.print("    \"floor_id\": {d},\n", .{state.position.floor_id});
    try w.print("    \"entry_id\": {d},\n", .{state.position.entry_id});
    try w.print("    \"teleport_id\": {d}\n", .{state.position.teleport_id});
    try w.writeAll("  },\n");

    try w.writeAll("  \"player_outfit\": ");
    try writeU32Array(w, ConfigManager.global_misc_defaults.player.player_outfits);
    try w.writeAll(",\n");

    try w.writeAll("  \"char_path\": {\n");
    try w.print("    \"main\": {d},\n", .{getMainPathAvatarId()});
    try w.print("    \"march_7\": {d}\n", .{getM7PathAvatarId()});
    try w.writeAll("  },\n");

    try w.writeAll("  \"paths\": {\n");
    try w.print("    \"trailblazer\": \"{s}\",\n", .{trailblazerPathName(ConfigManager.global_misc_defaults.mc_path)});
    try w.print("    \"march_7\": \"{s}\"\n", .{marchPathName(ConfigManager.global_misc_defaults.m7th_path)});
    try w.writeAll("  },\n");

    try w.writeAll("  \"enhanced\": {\n");
    try w.print("    \"1005\": {s},\n", .{if (isEnhancedAvatar(1005)) "true" else "false"});
    try w.print("    \"1006\": {s},\n", .{if (isEnhancedAvatar(1006)) "true" else "false"});
    try w.print("    \"1205\": {s},\n", .{if (isEnhancedAvatar(1205)) "true" else "false"});
    try w.print("    \"1212\": {s},\n", .{if (isEnhancedAvatar(1212)) "true" else "false"});
    try w.print("    \"1306\": {s},\n", .{if (isEnhancedAvatar(1306)) "true" else "false"});
    try w.print("    \"1307\": {s}\n", .{if (isEnhancedAvatar(1307)) "true" else "false"});
    try w.writeAll("  },\n");

    try w.writeAll("  \"costom_battlemode\": {\n");
    try w.print("    \"enabled\": {s},\n", .{if (Logic.FunMode().FunMode()) "true" else "false"});
    try w.print("    \"enemy_max_hp_override\": {d},\n", .{Logic.FunMode().GetHp()});
    try w.print("    \"stage_id\": {d},\n", .{ConfigManager.global_game_config_cache.game_config.battle_config.stage_id});
    try w.print("    \"cycle_count\": {d}\n", .{ConfigManager.global_game_config_cache.game_config.battle_config.cycle_count});
    try w.writeAll("  },\n");

    try w.print("  \"uid\": {d},\n", .{state.uid});
    try w.print("  \"level\": {d},\n", .{state.level});
    try w.print("  \"world_level\": {d},\n", .{state.world_level});
    try w.print("  \"stamina\": {d},\n", .{state.stamina});
    try w.print("  \"mcoin\": {d},\n", .{state.mcoin});
    try w.print("  \"hcoin\": {d},\n", .{state.hcoin});
    try w.print("  \"scoin\": {d},\n", .{state.scoin});

    try w.writeAll("  \"funmode_lineup\": ");
    try writeU32Array(w, BattleManager.funmodeAvatarID.items);
    try w.writeAll(",\n");

    try w.writeAll("  \"skins\": ");
    try writeU32Array(w, ConfigManager.global_misc_defaults.player.skins);
    try w.writeAll("\n}\n");
}

pub fn saveLineupToConfig(state: *PlayerState) !void {
    try save(state);
}

pub fn loadOrCreate(allocator: Allocator, uid: u32) !PlayerState {
    _ = uid;
    const defaults = ConfigManager.global_misc_defaults.player;
    var s = PlayerState.init(allocator, defaults.uid);
    s.level = defaults.level;
    s.world_level = defaults.world_level;
    s.stamina = defaults.stamina;
    s.mcoin = defaults.mcoin;
    s.hcoin = defaults.hcoin;
    s.scoin = defaults.scoin;
    s.position = .{
        .plane_id = defaults.position.plane_id,
        .floor_id = defaults.position.floor_id,
        .entry_id = defaults.position.entry_id,
        .teleport_id = defaults.position.teleport_id,
        .x = defaults.position.x,
        .y = defaults.position.y,
        .z = defaults.position.z,
        .use_coordinates = defaults.position.use_coordinates,
    };

    BattleManager.funmodeAvatarID.clearRetainingCapacity();
    try BattleManager.funmodeAvatarID.appendSlice(defaults.funmode_lineup);

    for (s.lineups[0][0..], 0..) |*slot, i| {
        slot.* = if (i < defaults.lineup.len) defaults.lineup[i] else 0;
    }
    for (s.lineups[1..]) |*preset| preset.* = std.mem.zeroes(LineupPreset);
    s.cur_lineup_index = 0;

    if (std.fs.cwd().openFile("misc.json", .{})) |file| {
        defer file.close();
        const file_size = file.getEndPos() catch 0;
        if (file_size > 0) {
            const buffer = file.readToEndAlloc(allocator, file_size) catch null;
            if (buffer) |buf| {
                defer allocator.free(buf);
                var json_tree = std.json.parseFromSlice(std.json.Value, allocator, buf, .{}) catch null;
                if (json_tree) |*tree| {
                    defer tree.deinit();
                    const root = tree.value;
                    if (root == .object) {
                        const lineup_root: std.json.Value = if (root.object.get("player")) |player_node| player_node else root;

                        if (lineup_root == .object) {
                            if (lineup_root.object.get("cur_lineup_index")) |idx_node| {
                                if (idx_node == .integer) {
                                    const idx: u32 = @intCast(idx_node.integer);
                                    if (idx < MaxLineups) s.cur_lineup_index = idx;
                                }
                            }

                            if (lineup_root.object.get("lineups")) |lineups_node| {
                                if (lineups_node == .array) {
                                    const count = @min(MaxLineups, lineups_node.array.items.len);
                                    var i: usize = 0;
                                    while (i < count) : (i += 1) {
                                        const preset_node = lineups_node.array.items[i];
                                        if (preset_node != .array) continue;
                                        const slots = @min(LineupSlots, preset_node.array.items.len);
                                        var j: usize = 0;
                                        while (j < slots) : (j += 1) {
                                            const v = preset_node.array.items[j];
                                            if (v == .integer) s.lineups[i][j] = @intCast(v.integer);
                                        }
                                        while (j < LineupSlots) : (j += 1) s.lineups[i][j] = 0;
                                    }
                                }
                            }
                        }

                        if (root.object.get("lineup")) |lineup_cfg| {
                            if (lineup_cfg == .object) {
                                if (lineup_cfg.object.get("current_index")) |idx_node| {
                                    if (idx_node == .integer) {
                                        const idx: u32 = @intCast(idx_node.integer);
                                        if (idx < MaxLineups) s.cur_lineup_index = idx;
                                    }
                                }

                                if (lineup_cfg.object.get("presets")) |presets_node| {
                                    if (presets_node == .array) {
                                        const count = @min(MaxLineups, presets_node.array.items.len);
                                        var i: usize = 0;
                                        while (i < count) : (i += 1) {
                                            const preset_node = presets_node.array.items[i];
                                            if (preset_node != .array) continue;
                                            const slots = @min(LineupSlots, preset_node.array.items.len);
                                            var j: usize = 0;
                                            while (j < slots) : (j += 1) {
                                                const v = preset_node.array.items[j];
                                                if (v == .integer) s.lineups[i][j] = @intCast(v.integer);
                                            }
                                            while (j < LineupSlots) : (j += 1) s.lineups[i][j] = 0;
                                        }
                                    }
                                } else if (lineup_cfg.object.get("active")) |active_node| {
                                    if (active_node == .array) {
                                        const idx = if (s.cur_lineup_index < MaxLineups) s.cur_lineup_index else 0;
                                        const slots = @min(LineupSlots, active_node.array.items.len);
                                        var j: usize = 0;
                                        while (j < slots) : (j += 1) {
                                            const v = active_node.array.items[j];
                                            if (v == .integer) s.lineups[@intCast(idx)][j] = @intCast(v.integer);
                                        }
                                        while (j < LineupSlots) : (j += 1) s.lineups[@intCast(idx)][j] = 0;
                                    }
                                }
                            }
                        }

                        if (root.object.get("lineup_presets")) |lineups_node| {
                            if (lineups_node == .array) {
                                const count = @min(MaxLineups, lineups_node.array.items.len);
                                var i: usize = 0;
                                while (i < count) : (i += 1) {
                                    const preset_node = lineups_node.array.items[i];
                                    if (preset_node != .array) continue;
                                    const slots = @min(LineupSlots, preset_node.array.items.len);
                                    var j: usize = 0;
                                    while (j < slots) : (j += 1) {
                                        const v = preset_node.array.items[j];
                                        if (v == .integer) s.lineups[i][j] = @intCast(v.integer);
                                    }
                                    while (j < LineupSlots) : (j += 1) s.lineups[i][j] = 0;
                                }
                            }
                        } else if (root.object.get("lineups")) |lineups_map| {
                            if (lineups_map == .object) {
                                const idx = if (s.cur_lineup_index < MaxLineups) s.cur_lineup_index else 0;
                                if (lineups_map.object.get("0")) |v| {
                                    if (v == .integer) s.lineups[@intCast(idx)][0] = @intCast(v.integer);
                                }
                                if (lineups_map.object.get("1")) |v| {
                                    if (v == .integer) s.lineups[@intCast(idx)][1] = @intCast(v.integer);
                                }
                                if (lineups_map.object.get("2")) |v| {
                                    if (v == .integer) s.lineups[@intCast(idx)][2] = @intCast(v.integer);
                                }
                                if (lineups_map.object.get("3")) |v| {
                                    if (v == .integer) s.lineups[@intCast(idx)][3] = @intCast(v.integer);
                                }
                            }
                        }
                    }
                }
            }
        }
    } else |_| {}

    var ids = std.ArrayList(u32).init(allocator);
    defer ids.deinit();
    for (s.lineups[@intCast(s.cur_lineup_index)]) |id| {
        if (id != 0) try ids.append(id);
    }
    try LineupManager.getSelectedAvatarID(allocator, ids.items);

    return s;
}

pub fn applySavedLineup(state: *PlayerState) !void {
    _ = state;
}
