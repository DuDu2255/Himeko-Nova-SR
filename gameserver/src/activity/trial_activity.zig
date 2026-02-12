const std = @import("std");
const protocol = @import("protocol");
const Session = @import("../Session.zig");
const Packet = @import("../Packet.zig");
const BattleManager = @import("../manager/battle_mgr.zig");
const AvatarManager = @import("../manager/avatar_mgr.zig");
const ConfigManager = @import("../manager/config_mgr.zig");
const PlayerStateMod = @import("../player_state.zig");
const Logic = @import("../utils/logic.zig");

const Allocator = std.mem.Allocator;
const CmdID = protocol.CmdID;
const MaxLineups = PlayerStateMod.MaxLineups;

const TrialState = struct {
    current_stage_id: u32,
    records: std.AutoHashMap(u32, bool), // stage_id -> taken_reward

    fn init(allocator: Allocator) TrialState {
        return .{
            .current_stage_id = 0,
            .records = std.AutoHashMap(u32, bool).init(allocator),
        };
    }
};

var trial_states = std.AutoHashMap(u32, TrialState).init(std.heap.page_allocator);

fn sessionUid(session: *Session) u32 {
    if (session.player_state) |state| return state.uid;
    return 1;
}

fn collectBattleAvatarIds(session: *Session, allocator: Allocator) !std.ArrayList(u32) {
    var ids = std.ArrayList(u32).init(allocator);

    if (Logic.FunMode().FunMode()) {
        try ids.appendSlice(BattleManager.funmodeAvatarID.items);
        if (ids.items.len == 0) try ids.append(AvatarManager.getMcId());
        return ids;
    }

    if (session.player_state) |state| {
        const idx: u32 = if (state.cur_lineup_index < MaxLineups) state.cur_lineup_index else 0;
        for (state.lineups[@intCast(idx)]) |id| {
            if (id != 0) try ids.append(id);
        }
    }

    if (ids.items.len == 0) {
        for (ConfigManager.global_misc_defaults.player.lineup) |id| {
            if (id != 0) try ids.append(id);
        }
    }
    if (ids.items.len == 0) try ids.append(AvatarManager.getMcId());
    return ids;
}

fn getState(uid: u32) !*TrialState {
    const gop = try trial_states.getOrPut(uid);
    if (!gop.found_existing) gop.value_ptr.* = TrialState.init(std.heap.page_allocator);
    return gop.value_ptr;
}

fn sendCurStatus(session: *Session, stage_id: u32, status: protocol.TrialActivityStatus) !void {
    try session.send(CmdID.CmdCurTrialActivityScNotify, protocol.CurTrialActivityScNotify{
        .activity_stage_id = stage_id,
        .status = status,
    });
}

pub fn onGetTrialActivityData(session: *Session, _: *const Packet, allocator: Allocator) !void {
    const uid = sessionUid(session);
    const state = try getState(uid);

    var rsp = protocol.GetTrialActivityDataScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.activity_stage_id = state.current_stage_id;

    var it = state.records.iterator();
    while (it.next()) |entry| {
        try rsp.trial_activity_info_list.append(.{
            .taken_reward = entry.value_ptr.*,
            .stage_id = entry.key_ptr.*,
        });
    }

    try session.send(CmdID.CmdGetTrialActivityDataScRsp, rsp);
}

pub fn onStartTrialActivity(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.StartTrialActivityCsReq, allocator);
    defer req.deinit();
    const uid = sessionUid(session);
    const state = try getState(uid);
    state.current_stage_id = req.stage_id;

    var rsp = protocol.StartTrialActivityScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.stage_id = req.stage_id;
    try session.send(CmdID.CmdStartTrialActivityScRsp, rsp);
    try sendCurStatus(session, req.stage_id, .TRIAL_ACTIVITY_STATUS_NONE);
}

pub fn onLeaveTrialActivity(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.LeaveTrialActivityCsReq, allocator);
    defer req.deinit();
    const uid = sessionUid(session);
    const state = try getState(uid);
    state.current_stage_id = 0;

    var rsp = protocol.LeaveTrialActivityScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.stage_id = req.stage_id;
    try session.send(CmdID.CmdLeaveTrialActivityScRsp, rsp);
    try sendCurStatus(session, 0, .TRIAL_ACTIVITY_STATUS_NONE);
}

pub fn onTakeTrialActivityReward(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.TakeTrialActivityRewardCsReq, allocator);
    defer req.deinit();
    const uid = sessionUid(session);
    const state = try getState(uid);

    var retcode: u32 = 0;
    if (state.records.getEntry(req.stage_id)) |entry| {
        entry.value_ptr.* = true;
    } else {
        retcode = 1;
    }

    var notify = protocol.TrialActivityDataChangeScNotify.init(allocator);
    notify.trial_activity_info = .{
        .taken_reward = retcode == 0,
        .stage_id = req.stage_id,
    };
    try session.send(CmdID.CmdTrialActivityDataChangeScNotify, notify);

    var rsp = protocol.TakeTrialActivityRewardScRsp.init(allocator);
    rsp.retcode = retcode;
    rsp.stage_id = req.stage_id;
    rsp.reward = protocol.ItemList.init(allocator);
    try session.send(CmdID.CmdTakeTrialActivityRewardScRsp, rsp);
}

pub fn onEnterTrialActivityStage(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.EnterTrialActivityStageCsReq, allocator);
    defer req.deinit();

    const uid = sessionUid(session);
    const state = try getState(uid);
    state.current_stage_id = req.stage_id;

    var avatar_ids = try collectBattleAvatarIds(session, allocator);
    defer avatar_ids.deinit();
    var battle_manager = BattleManager.BattleManager.init(allocator);
    const battle_info = try battle_manager.createBattle(avatar_ids.items);

    try session.send(CmdID.CmdEnterTrialActivityStageScRsp, protocol.EnterTrialActivityStageScRsp{
        .retcode = 0,
        .battle_info = battle_info,
    });
}

pub fn onBattleFinished(session: *Session, end_status: protocol.BattleEndStatus, battle_stage_id: u32, allocator: Allocator) !void {
    _ = battle_stage_id;
    if (end_status != .BATTLE_END_WIN) return;
    const uid = sessionUid(session);
    const state = try getState(uid);
    if (state.current_stage_id == 0) return;
    const stage_id = state.current_stage_id;
    if (!state.records.contains(stage_id)) {
        try state.records.put(stage_id, false);
    }

    var notify = protocol.TrialActivityDataChangeScNotify.init(allocator);
    notify.trial_activity_info = .{
        .taken_reward = false,
        .stage_id = stage_id,
    };
    try session.send(CmdID.CmdTrialActivityDataChangeScNotify, notify);
    try sendCurStatus(session, stage_id, .TRIAL_ACTIVITY_STATUS_FINISH);
    state.current_stage_id = 0;
}
