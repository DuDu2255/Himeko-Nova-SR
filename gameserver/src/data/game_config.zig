const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const BattleConfig = struct {
    battle_id: u32,
    stage_id: u32,
    cycle_count: u32,
    monster_wave: ArrayList(ArrayList(u32)),
    monster_level: u32,
    blessings: ArrayList(u32),
};

pub const Lightcone = struct {
    id: u32,
    rank: u32,
    level: u32,
    promotion: u32,
};

pub const Relic = struct {
    id: u32,
    level: u32,
    main_affix_id: u32,
    sub_count: u32,
    stat1: u32,
    cnt1: u32,
    step1: u32,
    stat2: u32,
    cnt2: u32,
    step2: u32,
    stat3: u32,
    cnt3: u32,
    step3: u32,
    stat4: u32,
    cnt4: u32,
    step4: u32,
};

pub const Avatar = struct {
    id: u32,
    hp: u32,
    sp: u32,
    level: u32,
    promotion: u32,
    rank: u32,
    lightcone: Lightcone,
    relics: ArrayList(Relic),
    use_technique: bool,
};

pub const GameConfig = struct {
    battle_config: BattleConfig,
    avatar_config: ArrayList(Avatar),

    pub fn deinit(self: *GameConfig) void {
        for (self.battle_config.monster_wave.items) |*wave| {
            wave.deinit();
        }
        self.battle_config.monster_wave.deinit();
        self.battle_config.blessings.deinit();

        for (self.avatar_config.items) |*avatar| {
            avatar.relics.deinit();
        }
        self.avatar_config.deinit();
    }
};
