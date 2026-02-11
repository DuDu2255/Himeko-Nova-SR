const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Position = struct {
    plane_id: u32,
    floor_id: u32,
    entry_id: u32,
    teleport_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    use_coordinates: bool = false,
};
pub const Gender = enum { male, female };
pub const Path = enum { warrior, knight, shaman, memory };
pub const MarchPath = enum { knight, rogue };
pub const CustomBattleMode = struct {
    enabled: bool = false,
    enemy_max_hp_override: u32 = 0,
    stage_id: u32 = 0,
    cycle_count: u32 = 0,
};

pub const Player = struct {
    uid: u32,
    level: u32,
    world_level: u32,
    stamina: u32,
    mcoin: u32,
    hcoin: u32,
    scoin: u32,
    lineup: []u32,
    funmode_lineup: []u32,
    skins: []u32,
    player_outfits: []u32,
    position: Position,
};

pub const MiscDefaults = struct {
    player: Player,
    mc_gender: Gender,
    mc_path: Path,
    m7th_path: MarchPath,
    enhanced_ids: []u32,
    costom_battlemode: CustomBattleMode,

    pub fn deinit(self: *MiscDefaults, allocator: Allocator) void {
        allocator.free(self.player.lineup);
        allocator.free(self.player.funmode_lineup);
        allocator.free(self.player.skins);
        allocator.free(self.player.player_outfits);
        allocator.free(self.enhanced_ids);
    }
};

const ParsedPaths = struct {
    mc_gender: Gender,
    mc_path: Path,
    m7th_path: MarchPath,
};

fn parseU32(node: std.json.Value, default_value: u32) u32 {
    return switch (node) {
        .integer => |v| if (v < 0) default_value else @intCast(v),
        .float => |v| if (v <= 0) default_value else @intFromFloat(v),
        else => default_value,
    };
}

fn parseI32(node: std.json.Value, default_value: i32) i32 {
    return switch (node) {
        .integer => |v| @intCast(v),
        .float => |v| @intFromFloat(v),
        else => default_value,
    };
}

fn parseBool(node: std.json.Value, default_value: bool) bool {
    return switch (node) {
        .bool => |v| v,
        .integer => |v| v != 0,
        .float => |v| v != 0,
        .string => |s| blk: {
            if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "on") or std.ascii.eqlIgnoreCase(s, "yes")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "no")) break :blk false;
            break :blk default_value;
        },
        else => default_value,
    };
}

fn parseArrayU32(allocator: Allocator, node: std.json.Value) ![]u32 {
    if (node != .array) return error.InvalidArray;
    var list = try allocator.alloc(u32, node.array.items.len);
    for (node.array.items, 0..) |val, i| {
        list[i] = parseU32(val, 0);
    }
    return list;
}

fn parseArrayU32OrEmpty(allocator: Allocator, node: ?std.json.Value) ![]u32 {
    if (node) |n| {
        if (n == .array) return parseArrayU32(allocator, n);
    }
    return allocator.alloc(u32, 0);
}

fn parsePositionLegacy(node: std.json.Value) Position {
    if (node != .object) return .{ .plane_id = 0, .floor_id = 0, .entry_id = 0 };
    const pos_obj = node.object;
    return .{
        .plane_id = if (pos_obj.get("plane_id")) |v| parseU32(v, 0) else 0,
        .floor_id = if (pos_obj.get("floor_id")) |v| parseU32(v, 0) else 0,
        .entry_id = if (pos_obj.get("entry_id")) |v| parseU32(v, 0) else 0,
        .teleport_id = if (pos_obj.get("teleport_id")) |v| parseU32(v, 0) else 0,
        .x = if (pos_obj.get("x")) |v| parseI32(v, 0) else 0,
        .y = if (pos_obj.get("y")) |v| parseI32(v, 0) else 0,
        .z = if (pos_obj.get("z")) |v| parseI32(v, 0) else 0,
        .use_coordinates = if (pos_obj.get("use_coordinates")) |v| (v == .bool and v.bool) else false,
    };
}

fn parsePositionFromSceneAndPosition(scene_node: ?std.json.Value, pos_node: ?std.json.Value) Position {
    var out = Position{ .plane_id = 0, .floor_id = 0, .entry_id = 0 };

    if (scene_node) |scene| {
        if (scene == .object) {
            out.plane_id = if (scene.object.get("plane_id")) |v| parseU32(v, out.plane_id) else out.plane_id;
            out.floor_id = if (scene.object.get("floor_id")) |v| parseU32(v, out.floor_id) else out.floor_id;
            out.entry_id = if (scene.object.get("entry_id")) |v| parseU32(v, out.entry_id) else out.entry_id;
            out.teleport_id = if (scene.object.get("teleport_id")) |v| parseU32(v, out.teleport_id) else out.teleport_id;
        }
    }

    if (pos_node) |pos| {
        if (pos == .object) {
            out.x = if (pos.object.get("x")) |v| parseI32(v, out.x) else out.x;
            out.y = if (pos.object.get("y")) |v| parseI32(v, out.y) else out.y;
            out.z = if (pos.object.get("z")) |v| parseI32(v, out.z) else out.z;
            out.teleport_id = if (pos.object.get("teleport_id")) |v| parseU32(v, out.teleport_id) else out.teleport_id;
            out.use_coordinates = if (pos.object.get("use_coordinates")) |v| (v == .bool and v.bool) else false;
        }
    }

    return out;
}

fn parseGender(node: ?std.json.Value) Gender {
    if (node) |n| switch (n) {
        .string => |s| {
            if (std.ascii.eqlIgnoreCase(s, "male")) return .male;
            if (std.ascii.eqlIgnoreCase(s, "female")) return .female;
        },
        else => {},
    };
    return .female;
}

fn parsePath(node: ?std.json.Value) Path {
    if (node) |n| switch (n) {
        .string => |s| {
            if (std.ascii.eqlIgnoreCase(s, "warrior")) return .warrior;
            if (std.ascii.eqlIgnoreCase(s, "knight")) return .knight;
            if (std.ascii.eqlIgnoreCase(s, "shaman")) return .shaman;
            if (std.ascii.eqlIgnoreCase(s, "memory")) return .memory;
            if (std.ascii.eqlIgnoreCase(s, "destruction")) return .warrior;
            if (std.ascii.eqlIgnoreCase(s, "preservation")) return .knight;
            if (std.ascii.eqlIgnoreCase(s, "harmony")) return .shaman;
            if (std.ascii.eqlIgnoreCase(s, "remembrance")) return .memory;
        },
        else => {},
    };
    return .memory;
}

fn parseMarchPath(node: ?std.json.Value) MarchPath {
    if (node) |n| switch (n) {
        .string => |s| {
            if (std.ascii.eqlIgnoreCase(s, "knight")) return .knight;
            if (std.ascii.eqlIgnoreCase(s, "rogue")) return .rogue;
            if (std.ascii.eqlIgnoreCase(s, "preservation")) return .knight;
            if (std.ascii.eqlIgnoreCase(s, "the hunt") or std.ascii.eqlIgnoreCase(s, "hunt")) return .rogue;
        },
        else => {},
    };
    return .rogue;
}

fn parseMainPathAvatar(main_id: u32, fallback_gender: Gender, fallback_path: Path) struct { gender: Gender, path: Path } {
    if (main_id < 8001 or main_id > 8008) {
        return .{ .gender = fallback_gender, .path = fallback_path };
    }
    const gender: Gender = if ((main_id % 2) == 1) .male else .female;
    const path_index = (main_id - 8001) / 2;
    const path: Path = switch (path_index) {
        0 => .warrior,
        1 => .knight,
        2 => .shaman,
        else => .memory,
    };
    return .{ .gender = gender, .path = path };
}

fn parsePaths(root_obj: std.json.ObjectMap) ParsedPaths {
    var out = ParsedPaths{
        .mc_gender = parseGender(root_obj.get("mc_gender")),
        .mc_path = parsePath(root_obj.get("mc_path")),
        .m7th_path = parseMarchPath(root_obj.get("m7th_path")),
    };

    if (root_obj.get("char_path")) |char_path_node| {
        if (char_path_node == .object) {
            if (char_path_node.object.get("main")) |main_node| {
                switch (main_node) {
                    .string => out.mc_path = parsePath(main_node),
                    else => {
                        const parsed = parseMainPathAvatar(parseU32(main_node, 0), out.mc_gender, out.mc_path);
                        out.mc_gender = parsed.gender;
                        out.mc_path = parsed.path;
                    },
                }
            }
            if (char_path_node.object.get("march_7")) |march_node| {
                switch (march_node) {
                    .string => out.m7th_path = parseMarchPath(march_node),
                    else => {
                        const mid = parseU32(march_node, 0);
                        out.m7th_path = if (mid == 1001) .knight else .rogue;
                    },
                }
            }
        }
    }

    if (root_obj.get("paths")) |paths_node| {
        if (paths_node == .object) {
            if (paths_node.object.get("trailblazer")) |tb| out.mc_path = parsePath(tb)
            else if (paths_node.object.get("main")) |tb| out.mc_path = parsePath(tb);

            if (paths_node.object.get("march_7")) |m7| out.m7th_path = parseMarchPath(m7)
            else if (paths_node.object.get("march7")) |m7| out.m7th_path = parseMarchPath(m7);
        }
    }

    return out;
}

fn parseLineupObject(allocator: Allocator, node: std.json.Value) ![]u32 {
    if (node != .object) return error.InvalidLineupObject;
    var list = try allocator.alloc(u32, 4);
    errdefer allocator.free(list);
    @memset(list, 0);

    if (node.object.get("0")) |v| list[0] = parseU32(v, 0);
    if (node.object.get("1")) |v| list[1] = parseU32(v, 0);
    if (node.object.get("2")) |v| list[2] = parseU32(v, 0);
    if (node.object.get("3")) |v| list[3] = parseU32(v, 0);
    return list;
}

fn parseSkinDataObject(allocator: Allocator, node: std.json.Value) ![]u32 {
    if (node != .object) return error.InvalidSkinDataObject;
    var list = try allocator.alloc(u32, node.object.count());
    var i: usize = 0;
    var it = node.object.iterator();
    while (it.next()) |entry| {
        list[i] = parseU32(entry.value_ptr.*, 0);
        i += 1;
    }
    return list;
}

fn parseEnhancedIds(allocator: Allocator, root_obj: std.json.ObjectMap) ![]u32 {
    const source_node = root_obj.get("enhanced") orelse root_obj.get("char_enhanced") orelse return allocator.alloc(u32, 0);
    if (source_node != .object) return allocator.alloc(u32, 0);

    var ids = std.ArrayList(u32).init(allocator);
    defer ids.deinit();

    var it = source_node.object.iterator();
    while (it.next()) |entry| {
        const id = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch continue;
        const enabled = parseBool(entry.value_ptr.*, false);
        if (!enabled) continue;

        var dup = false;
        for (ids.items) |x| {
            if (x == id) {
                dup = true;
                break;
            }
        }
        if (!dup) try ids.append(id);
    }

    return ids.toOwnedSlice();
}

fn parseCustomBattleMode(root_obj: std.json.ObjectMap) CustomBattleMode {
    var tc = CustomBattleMode{};
    if (root_obj.get("costom_battlemode")) |node| {
        if (node == .object) {
            const obj = node.object;
            if (obj.get("enabled")) |v| tc.enabled = parseBool(v, tc.enabled);
            if (obj.get("mode")) |v| tc.enabled = parseBool(v, tc.enabled);
            if (obj.get("enemy_max_hp_override")) |v| tc.enemy_max_hp_override = parseU32(v, tc.enemy_max_hp_override);
            if (obj.get("monster_hp_override")) |v| tc.enemy_max_hp_override = parseU32(v, tc.enemy_max_hp_override);
            if (obj.get("hp_override")) |v| tc.enemy_max_hp_override = parseU32(v, tc.enemy_max_hp_override);
            if (obj.get("stage_id")) |v| tc.stage_id = parseU32(v, tc.stage_id);
            if (obj.get("cycle_count")) |v| tc.cycle_count = parseU32(v, tc.cycle_count);

            if (tc.enemy_max_hp_override == 0) {
                if (obj.get("hp")) |hp_node| {
                    if (hp_node == .object) {
                        var it = hp_node.object.iterator();
                        while (it.next()) |e| {
                            if (e.value_ptr.* != .array) continue;
                            const arr = e.value_ptr.*.array.items;
                            if (arr.len == 0) continue;
                            if (arr[0] == .integer or arr[0] == .float) {
                                tc.enemy_max_hp_override = parseU32(arr[0], 0);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    return tc;
}

fn parseLineupReadable(allocator: Allocator, root_obj: std.json.ObjectMap) !?[]u32 {
    if (root_obj.get("lineup")) |lineup_node| {
        if (lineup_node == .object) {
            if (lineup_node.object.get("active")) |active| {
                if (active == .array) return try parseArrayU32(allocator, active);
            }
            if (lineup_node.object.get("presets")) |presets| {
                if (presets == .array and presets.array.items.len != 0) {
                    const first = presets.array.items[0];
                    if (first == .array) return try parseArrayU32(allocator, first);
                }
            }
        }
    }
    return null;
}

fn parseLegacyFormat(allocator: Allocator, root: std.json.Value, player_root: std.json.Value) !MiscDefaults {
    const lineup = if (player_root.object.get("lineup")) |v|
        try parseArrayU32(allocator, v)
    else if (try parseLineupReadable(allocator, root.object)) |v|
        v
    else
        try allocator.alloc(u32, 0);
    errdefer allocator.free(lineup);

    const funmode_lineup = try parseArrayU32OrEmpty(allocator, player_root.object.get("funmode_lineup"));
    errdefer allocator.free(funmode_lineup);

    const skins = try parseArrayU32OrEmpty(allocator, player_root.object.get("skins"));
    errdefer allocator.free(skins);

    const player_outfits = if (player_root.object.get("player_outfits")) |v|
        try parseArrayU32(allocator, v)
    else if (player_root.object.get("player_outfit")) |v|
        try parseArrayU32(allocator, v)
    else
        try allocator.alloc(u32, 0);
    errdefer allocator.free(player_outfits);

    const paths = parsePaths(root.object);
    const enhanced_ids = try parseEnhancedIds(allocator, root.object);
    errdefer allocator.free(enhanced_ids);
    const costom_battlemode = parseCustomBattleMode(root.object);

    return .{
        .player = .{
            .uid = if (player_root.object.get("uid")) |v| parseU32(v, 1) else 1,
            .level = if (player_root.object.get("level")) |v| parseU32(v, 70) else 70,
            .world_level = if (player_root.object.get("world_level")) |v| parseU32(v, 6) else 6,
            .stamina = if (player_root.object.get("stamina")) |v| parseU32(v, 300) else 300,
            .mcoin = if (player_root.object.get("mcoin")) |v| parseU32(v, 10000) else 10000,
            .hcoin = if (player_root.object.get("hcoin")) |v| parseU32(v, 10000) else 10000,
            .scoin = if (player_root.object.get("scoin")) |v| parseU32(v, 10000) else 10000,
            .lineup = lineup,
            .funmode_lineup = funmode_lineup,
            .skins = skins,
            .player_outfits = player_outfits,
            .position = if (player_root.object.get("position")) |v|
                parsePositionLegacy(v)
            else
                parsePositionFromSceneAndPosition(root.object.get("scene"), root.object.get("position")),
        },
        .mc_gender = paths.mc_gender,
        .mc_path = paths.mc_path,
        .m7th_path = paths.m7th_path,
        .enhanced_ids = enhanced_ids,
        .costom_battlemode = costom_battlemode,
    };
}

fn parseFireflyStyleFormat(allocator: Allocator, root: std.json.Value) !MiscDefaults {
    const lineup = if (try parseLineupReadable(allocator, root.object)) |v|
        v
    else if (root.object.get("lineups")) |v|
        try parseLineupObject(allocator, v)
    else if (root.object.get("lineup")) |v|
        try parseArrayU32(allocator, v)
    else
        try allocator.alloc(u32, 0);
    errdefer allocator.free(lineup);

    const funmode_lineup = try parseArrayU32OrEmpty(allocator, root.object.get("funmode_lineup"));
    errdefer allocator.free(funmode_lineup);

    const skins = if (root.object.get("skins")) |v|
        try parseArrayU32(allocator, v)
    else if (root.object.get("skin_data")) |v|
        try parseSkinDataObject(allocator, v)
    else
        try allocator.alloc(u32, 0);
    errdefer allocator.free(skins);

    const player_outfits = if (root.object.get("player_outfits")) |v|
        try parseArrayU32(allocator, v)
    else if (root.object.get("player_outfit")) |v|
        try parseArrayU32(allocator, v)
    else
        try allocator.alloc(u32, 0);
    errdefer allocator.free(player_outfits);

    const paths = parsePaths(root.object);
    const enhanced_ids = try parseEnhancedIds(allocator, root.object);
    errdefer allocator.free(enhanced_ids);
    const costom_battlemode = parseCustomBattleMode(root.object);

    return .{
        .player = .{
            .uid = if (root.object.get("uid")) |v| parseU32(v, 1) else 1,
            .level = if (root.object.get("level")) |v| parseU32(v, 70) else 70,
            .world_level = if (root.object.get("world_level")) |v| parseU32(v, 6) else 6,
            .stamina = if (root.object.get("stamina")) |v| parseU32(v, 300) else 300,
            .mcoin = if (root.object.get("mcoin")) |v| parseU32(v, 10000) else 10000,
            .hcoin = if (root.object.get("hcoin")) |v| parseU32(v, 10000) else 10000,
            .scoin = if (root.object.get("scoin")) |v| parseU32(v, 10000) else 10000,
            .lineup = lineup,
            .funmode_lineup = funmode_lineup,
            .skins = skins,
            .player_outfits = player_outfits,
            .position = parsePositionFromSceneAndPosition(root.object.get("scene"), root.object.get("position")),
        },
        .mc_gender = paths.mc_gender,
        .mc_path = paths.mc_path,
        .m7th_path = paths.m7th_path,
        .enhanced_ids = enhanced_ids,
        .costom_battlemode = costom_battlemode,
    };
}

pub fn loadFromFile(allocator: Allocator, path: []const u8) !MiscDefaults {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(buffer);

    var json_tree = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{});
    defer json_tree.deinit();

    const root = json_tree.value;
    if (root != .object) return error.InvalidRoot;

    if (root.object.get("player")) |player_root| {
        if (player_root == .object) {
            return parseLegacyFormat(allocator, root, player_root);
        }
    }

    return parseFireflyStyleFormat(allocator, root);
}
