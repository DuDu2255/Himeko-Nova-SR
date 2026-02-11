const std = @import("std");
const protocol = @import("protocol");
const Config = @import("../data/game_config.zig");
const Session = @import("../Session.zig");
const Data = @import("../data.zig");
const Logic = @import("../utils/logic.zig");
const MiscDefaults = @import("../data/misc_defaults.zig");
const ConfigManager = @import("../manager/config_mgr.zig");
const Uid = @import("../utils/uid.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const CmdID = protocol.CmdID;

const config = &ConfigManager.global_game_config_cache.game_config;
const skill_config = &ConfigManager.global_game_config_cache.avatar_skill_config;

pub var m7th: u32 = 1224;
pub var mc_id: u32 = 0;

pub fn isMcPathAvatar(avatar_id: u32) bool {
    return avatar_id >= 8001 and avatar_id <= 8008;
}

pub fn isMarchPathAvatar(avatar_id: u32) bool {
    return avatar_id == 1001 or avatar_id == 1224;
}

fn m7thIdFromMisc() u32 {
    return switch (ConfigManager.global_misc_defaults.m7th_path) {
        .knight => 1001,
        .rogue => 1224,
    };
}

fn ensureM7thFromMisc() void {
    const desired = m7thIdFromMisc();
    if (m7th != desired) m7th = desired;
}

pub fn getM7thId() u32 {
    ensureM7thFromMisc();
    return m7th;
}

pub fn setM7thPath(path: MiscDefaults.MarchPath) void {
    m7th = switch (path) {
        .knight => 1001,
        .rogue => 1224,
    };
    ConfigManager.global_misc_defaults.m7th_path = path;
}

pub fn setM7thFromMultiPath(t: protocol.MultiPathAvatarType) void {
    switch (t) {
        .Mar_7thKnightType => setM7thPath(.knight),
        .Mar_7thRogueType => setM7thPath(.rogue),
        else => {},
    }
}

pub const MultiPathSelection = struct {
    has_mc_selected: bool,
    has_m7th_selected: bool,
};

pub fn getMultiPathSelection(config_in: *const Config.GameConfig) MultiPathSelection {
    const mc_selected = getMcId();
    const m7th_selected = getM7thId();
    var selection = MultiPathSelection{
        .has_mc_selected = false,
        .has_m7th_selected = false,
    };
    for (config_in.avatar_config.items) |avatarConf| {
        if (isMcPathAvatar(avatarConf.id) and avatarConf.id == mc_selected) {
            selection.has_mc_selected = true;
        }
        if (isMarchPathAvatar(avatarConf.id) and avatarConf.id == m7th_selected) {
            selection.has_m7th_selected = true;
        }
    }
    return selection;
}

pub fn shouldIncludeAvatarInList(avatar_id: u32, selection: MultiPathSelection) bool {
    if (isMcPathAvatar(avatar_id)) {
        if (selection.has_mc_selected and avatar_id != getMcId()) return false;
    } else if (isMarchPathAvatar(avatar_id)) {
        if (selection.has_m7th_selected and avatar_id != getM7thId()) return false;
    }
    return true;
}

fn stableItemUid(tag: []const u8, avatar_id: u32, tid: u32, slot: u32) u32 {
    var h = std.hash.Wyhash.init(0);
    h.update(tag);
    h.update(std.mem.asBytes(&avatar_id));
    h.update(std.mem.asBytes(&tid));
    h.update(std.mem.asBytes(&slot));
    const v: u64 = h.final();
    // keep it non-zero and inside u32
    const u: u32 = @intCast(@as(u64, 1) + (v % @as(u64, 0xFFFF_FFFE)));
    return u;
}

fn resolveItemUid(tag: []const u8, avatar_id: u32, tid: u32, slot: u32, internal_uid: u32) u32 {
    // `internal_uid` in freesr-data is treated as a type/config marker and may repeat.
    // Build a deterministic per-owner unique_id to avoid collisions in bag/equip display.
    const seed_tid = if (internal_uid != 0) internal_uid else tid;
    return stableItemUid(tag, avatar_id, seed_tid, slot);
}

fn mapMcId(gender: MiscDefaults.Gender, path: MiscDefaults.Path) u32 {
    const base: u32 = switch (path) {
        .warrior => 0,
        .knight => 1,
        .shaman => 2,
        .memory => 3,
    };
    const offset: u32 = if (gender == .male) 0 else 1;
    return 8001 + base * 2 + offset;
}

fn ensureMcFromMisc() void {
    mc_id = mapMcId(ConfigManager.global_misc_defaults.mc_gender, ConfigManager.global_misc_defaults.mc_path);
}

pub fn getMcId() u32 {
    if (mc_id < 8001 or mc_id > 8008) {
        ensureMcFromMisc();
    }
    return mc_id;
}

fn currentMultiPathAvatarId(avatar_id: u32) u32 {
    if (isMcPathAvatar(avatar_id)) return getMcId();
    if (isMarchPathAvatar(avatar_id)) return getM7thId();
    return avatar_id;
}

pub fn setMc(gender: MiscDefaults.Gender, path: MiscDefaults.Path) void {
    mc_id = mapMcId(gender, path);
    ConfigManager.global_misc_defaults.mc_gender = gender;
    ConfigManager.global_misc_defaults.mc_path = path;
}

fn mcIdFromMultiPath(t: protocol.MultiPathAvatarType) ?u32 {
    return switch (t) {
        .BoyWarriorType => 8001,
        .GirlWarriorType => 8002,
        .BoyKnightType => 8003,
        .GirlKnightType => 8004,
        .BoyShamanType => 8005,
        .GirlShamanType => 8006,
        .BoyMemoryType => 8007,
        .GirlMemoryType => 8008,
        else => null,
    };
}

pub fn setMcFromMultiPath(t: protocol.MultiPathAvatarType) void {
    if (mcIdFromMultiPath(t)) |id| {
        const gender: MiscDefaults.Gender = if ((id % 2) == 1) .male else .female;
        const path_index = (id - 8001) / 2;
        const path: MiscDefaults.Path = switch (path_index) {
            0 => .warrior,
            1 => .knight,
            2 => .shaman,
            else => .memory,
        };
        setMc(gender, path);
    }
}

pub fn createAvatar(
    allocator: Allocator,
    avatarConf: Config.Avatar,
) !protocol.Avatar {
    var avatar = protocol.Avatar.init(allocator);
    avatar.base_avatar_id = switch (avatarConf.id) {
        8001...8008 => 8001,
        1224 => 1001,
        else => avatarConf.id,
    };
    avatar.level = avatarConf.level;
    avatar.promotion = avatarConf.promotion;
    avatar.has_taken_promotion_reward_list = ArrayList(u32).init(allocator);
    for (1..6) |i| {
        try avatar.has_taken_promotion_reward_list.append(@intCast(i));
    }
    avatar.cur_multi_path_avatar_type = avatarConf.id;
    // 角色穿戴的光锥/遗器需要和 GetBag 返回的 unique_id 对得上；
    // 当 freesr-data 缺失 internal_uid 时，使用稳定派生的 uid，避免因生成顺序/重置导致不一致。
    avatar.equipment_unique_id = if (avatarConf.lightcone.id == 0)
        0
    else
        resolveItemUid("LC", avatarConf.id, avatarConf.lightcone.id, 0, avatarConf.lightcone.internal_uid);
    return avatar;
}
pub fn createAllAvatar(
    allocator: Allocator,
    Avatar_id: u32,
) !protocol.Avatar {
    var avatar = protocol.Avatar.init(allocator);
    avatar.base_avatar_id = Avatar_id;
    avatar.level = 80;
    avatar.promotion = 6;
    avatar.has_taken_promotion_reward_list = ArrayList(u32).init(allocator);
    for (1..6) |i| {
        try avatar.has_taken_promotion_reward_list.append(@intCast(i));
    }
    avatar.cur_multi_path_avatar_type = currentMultiPathAvatarId(Avatar_id);
    avatar.equipment_unique_id = 0;
    return avatar;
}

pub fn createAvatarPathData(
    allocator: Allocator,
    avatarConf: Config.Avatar,
) !protocol.AvatarPathData {
    var avatar = protocol.AvatarPathData.init(allocator);
    avatar.avatar_id = avatarConf.id;
    avatar.rank = avatarConf.rank;
    avatar.dressed_skin_id = getSkinId(avatar.avatar_id);
    if (Logic.inlist(avatar.avatar_id, &Data.EnhanceAvatarID)) {
        avatar.unk_enhanced_id = 1;
    }
    avatar.path_equipment_id = if (avatarConf.lightcone.id == 0)
        0
    else
        resolveItemUid("LC", avatarConf.id, avatarConf.lightcone.id, 0, avatarConf.lightcone.internal_uid);

    avatar.equip_relic_list = ArrayList(protocol.EquipRelic).init(allocator);
    const max_slots: usize = 6;
    const count: usize = @min(max_slots, avatarConf.relics.items.len);
    for (0..count) |slot| {
        const relic_conf = avatarConf.relics.items[slot];
        const relic_uid = if (relic_conf.id == 0)
            0
        else
            resolveItemUid("RELIC", avatarConf.id, relic_conf.id, @intCast(slot), relic_conf.internal_uid);
        try avatar.equip_relic_list.append(.{
            .relic_unique_id = relic_uid,
            .type = @intCast(slot),
        });
    }
    for (count..max_slots) |slot| {
        try avatar.equip_relic_list.append(.{
            .relic_unique_id = 0,
            .type = @intCast(slot),
        });
    }

    avatar.avatar_path_skill_tree = ArrayList(protocol.AvatarPathSkillTree).init(allocator);
    try createSkillTree(avatar.avatar_id, &avatar.avatar_path_skill_tree, avatarConf.skill_levels.items);
    return avatar;
}

pub fn createAllAvatarPathData(
    allocator: Allocator,
    Avatar_id: u32,
) !protocol.AvatarPathData {
    var avatar = protocol.AvatarPathData.init(allocator);
    avatar.avatar_id = Avatar_id;
    avatar.rank = 6;
    avatar.dressed_skin_id = getSkinId(avatar.avatar_id);
    if (Logic.inlist(avatar.avatar_id, &Data.EnhanceAvatarID)) {
        avatar.unk_enhanced_id = 1;
    }
    avatar.path_equipment_id = 0;
    avatar.equip_relic_list = ArrayList(protocol.EquipRelic).init(allocator);
    for (0..6) |slot| {
        try avatar.equip_relic_list.append(.{
            .relic_unique_id = 0,
            .type = @intCast(slot),
        });
    }
    avatar.avatar_path_skill_tree = ArrayList(protocol.AvatarPathSkillTree).init(allocator);
    try createSkillTree(avatar.avatar_id, &avatar.avatar_path_skill_tree, &[_]Config.SkillLevel{});
    return avatar;
}

fn createSkillTree(
    base_avatar_id: u32,
    skilltree_list: *std.ArrayList(protocol.AvatarPathSkillTree),
    overrides: []const Config.SkillLevel,
) !void {
    for (skill_config.avatar_skill_tree_config.items) |skill| {
        if (skill.avatar_id == base_avatar_id) {
            var level: ?u32 = null;
            for (overrides) |ov| {
                if (ov.point_id == skill.point_id) {
                    level = ov.level;
                    break;
                }
            }
            if (level == null and skill.level == skill.max_level) {
                level = skill.max_level;
            }
            if (level) |lv| {
                try skilltree_list.append(.{
                    .point_id = skill.anchor_type,
                    .level = lv,
                });
            }
        }
    }
}

pub fn createEquipment(
    lightconeConf: Config.Lightcone,
    dress_avatar_id: u32,
) !protocol.Equipment {
    return protocol.Equipment{
        .unique_id = resolveItemUid("LC", dress_avatar_id, lightconeConf.id, 0, lightconeConf.internal_uid),
        .tid = lightconeConf.id,
        .is_protected = true,
        .level = lightconeConf.level,
        .rank = lightconeConf.rank,
        .promotion = lightconeConf.promotion,
        .dress_avatar_id = dress_avatar_id,
    };
}

pub fn createRelic(
    allocator: Allocator,
    relicConf: Config.Relic,
    dress_avatar_id: u32,
    slot: u32,
) !protocol.Relic {
    var r = protocol.Relic{
        .tid = relicConf.id,
        .main_affix_id = relicConf.main_affix_id,
        .unique_id = resolveItemUid("RELIC", dress_avatar_id, relicConf.id, slot, relicConf.internal_uid),
        .exp = 0,
        .dress_avatar_id = dress_avatar_id,
        .is_protected = true,
        .level = relicConf.level,
        .sub_affix_list = ArrayList(protocol.RelicAffix).init(allocator),
        .reforge_sub_affix_list = ArrayList(protocol.RelicAffix).init(allocator),
        .AOLFKGGECNB = ArrayList(protocol.RelicAffix).init(allocator),
    };
    if (relicConf.stat1 != 0) try r.sub_affix_list.append(protocol.RelicAffix{ .affix_id = relicConf.stat1, .cnt = relicConf.cnt1, .step = relicConf.step1 });
    if (relicConf.stat2 != 0) try r.sub_affix_list.append(protocol.RelicAffix{ .affix_id = relicConf.stat2, .cnt = relicConf.cnt2, .step = relicConf.step2 });
    if (relicConf.stat3 != 0) try r.sub_affix_list.append(protocol.RelicAffix{ .affix_id = relicConf.stat3, .cnt = relicConf.cnt3, .step = relicConf.step3 });
    if (relicConf.stat4 != 0) try r.sub_affix_list.append(protocol.RelicAffix{ .affix_id = relicConf.stat4, .cnt = relicConf.cnt4, .step = relicConf.step4 });
    return r;
}

fn getAvatarType(id: u32) protocol.MultiPathAvatarType {
    return switch (id) {
        1001 => .Mar_7thKnightType,
        1224 => .Mar_7thRogueType,
        else => {
            if (id < 8001 or id > 8008) return .MultiPathAvatarTypeNone; // fallback
            const base = (id - 8001) / 2;
            const is_boy = (id % 2) == 1;

            return switch (base) {
                0 => if (is_boy) .BoyWarriorType else .GirlWarriorType,
                1 => if (is_boy) .BoyKnightType else .GirlKnightType,
                2 => if (is_boy) .BoyShamanType else .GirlShamanType,
                3 => if (is_boy) .BoyMemoryType else .GirlMemoryType,
                else => .GirlMemoryType,
            };
        },
    };
}
pub fn getSkinId(avatar_id: u32) u32 {
    for (Data.AvatarSkinMap) |entry| {
        if (entry.avatar_id == avatar_id) return entry.skin_id;
    }
    return 0;
}
pub fn updateSkinId(avatar_id: u32, new_skin_id: u32) void {
    for (&Data.AvatarSkinMap) |*entry| {
        if (entry.avatar_id == avatar_id) {
            entry.skin_id = new_skin_id;
            return;
        }
    }
}
pub fn syncAvatarData(session: *Session, allocator: Allocator) !void {
    var sync = protocol.PlayerSyncScNotify.init(allocator);
    defer sync.deinit();
    Uid.resetGlobalUidGens();
    var char = protocol.AvatarSync.init(allocator);
    const selection = getMultiPathSelection(config);
    for (Data.AllAvatars) |id| {
        const avatar = try createAllAvatar(allocator, id);
        try char.avatar_list.append(avatar);
    }
    for (Data.AllAvatars) |id| {
        const avatar = try createAllAvatarPathData(allocator, id);
        try char.avatar_path_data_info_list.append(avatar);
    }
    for (config.avatar_config.items) |avatarConf| {
        if (!shouldIncludeAvatarInList(avatarConf.id, selection)) continue;
        const avatar = try createAvatar(allocator, avatarConf);
        try char.avatar_list.append(avatar);
    }
    for (config.avatar_config.items) |avatarConf| {
        const avatar = try createAvatarPathData(allocator, avatarConf);
        try char.avatar_path_data_info_list.append(avatar);
    }
    sync.avatar_sync = char;
    try session.send(CmdID.CmdPlayerSyncScNotify, sync);
}
