const std = @import("std");
const protocol = @import("protocol");
const Session = @import("../Session.zig");
const Packet = @import("../Packet.zig");
const LineupManager = @import("../manager/lineup_mgr.zig");
const PlayerStateMod = @import("../player_state.zig");
const SceneManager = @import("../manager/scene_mgr.zig");
const ConfigManager = @import("../manager/config_mgr.zig");
const ItemService = @import("item.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const CmdID = protocol.CmdID;

const log = std.log.scoped(.scene_service);
pub var scene_debug_enabled: bool = false;
var position_log_counter: u32 = 0;

const entrance_config = &ConfigManager.global_game_config_cache.map_entrance_config;
const res_config = &ConfigManager.global_game_config_cache.res_config;

pub fn onGetCurSceneInfo(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var scene_manager = SceneManager.SceneManager.init(allocator);

    // 优先使用存档/默认配置里的 position，避免 position 配置“不生效”
    var entry_id: u32 = 2042201;
    var plane_id: u32 = 20422;
    var floor_id: u32 = 20422001;

    // 选择一个能匹配到的 teleport_id，否则角色实体不会被放入场景
    var teleport_id: u32 = 1025;
    var spawn_override_pos: ?protocol.Vector = null;
    if (session.player_state) |state| {
        entry_id = state.position.entry_id;
        plane_id = state.position.plane_id;
        floor_id = state.position.floor_id;
        if (state.position.teleport_id != 0) teleport_id = state.position.teleport_id;
        if (state.position.use_coordinates) {
            spawn_override_pos = .{ .x = state.position.x, .y = state.position.y, .z = state.position.z };
        }
    }

    for (res_config.scene_config.items) |sceneConf| {
        if (sceneConf.planeID == plane_id and sceneConf.entryID == entry_id) {
            if (sceneConf.teleports.items.len > 0) {
                if (teleport_id == 0) teleport_id = sceneConf.teleports.items[0].teleportId;
            }
            break;
        }
    }

    if (scene_debug_enabled) {
        log.info("[SceneDebug] GetCurSceneInfo: plane_id={} floor_id={} entry_id={} teleport_id={}", .{ plane_id, floor_id, entry_id, teleport_id });
    }
    const scene_info = try scene_manager.createSceneWithSpawn(plane_id, floor_id, entry_id, teleport_id, spawn_override_pos, null);

    try session.send(CmdID.CmdGetCurSceneInfoScRsp, protocol.GetCurSceneInfoScRsp{
        .scene = scene_info,
        .retcode = 0,
    });
}
pub fn onSceneEntityMove(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.SceneEntityMoveCsReq, allocator);
    defer req.deinit();
    for (req.entity_motion_list.items) |entity_motion| {
        if (entity_motion.motion) |motion| {
            if (scene_debug_enabled and (entity_motion.entity_id > 99999 and entity_motion.entity_id < 1000000 or entity_motion.entity_id == 0)) {
                position_log_counter +%= 1;
                if (position_log_counter % 20 == 0) {
                    // Use info so it shows up even in Release builds (std_options.log_level=.info).
                    log.info("[SceneDebug][Position] entity_id={} motion={}", .{ entity_motion.entity_id, motion });
                }
            }
        }
    }
    try session.send(CmdID.CmdSceneEntityMoveScRsp, protocol.SceneEntityMoveScRsp{
        .retcode = 0,
        .entity_motion_list = req.entity_motion_list,
        .download_data = null,
    });
}

pub fn onEnterScene(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.EnterSceneCsReq, allocator);
    defer req.deinit();

    if (scene_debug_enabled) {
        log.info("[SceneDebug] EnterSceneCsReq: entry_id={} teleport_id={}", .{ req.entry_id, req.teleport_id });
    }

    // Apply saved lineup from player_state if available
    if (session.player_state) |*state| {
        // we ignore errors here to avoid killing the scene entry 鈥?failure will be logged by caller
        _ = PlayerStateMod.applySavedLineup(state) catch |err| {
            std.debug.print("applySavedLineup failed: {any}\n", .{err});
        };
    }

    var lineup_mgr = LineupManager.LineupManager.init(allocator);
    const lineup = try lineup_mgr.createLineup();
    var scene_manager = SceneManager.SceneManager.init(allocator);
    var floorID: u32 = 0;
    var planeID: u32 = 0;
    var teleportID: u32 = 0;
    for (entrance_config.map_entrance_config.items) |entrConf| {
        if (entrConf.id == req.entry_id) {
            floorID = entrConf.floor_id;
            planeID = entrConf.plane_id;
            teleportID = req.teleport_id;
        }
    }

    var spawn_override_pos: ?protocol.Vector = null;
    var spawn_override_rot: ?protocol.Vector = null;
    // Client may provide a direct spawn transform; treat it as highest priority.
    if (req.BGMJIJPIJDM) |pos| {
        spawn_override_pos = pos;
    }
    if (req.rot) |rot| {
        spawn_override_rot = rot;
    }
    // Fallback: use saved coordinates (misc.json) for this entry.
    if (spawn_override_pos == null) {
        if (session.player_state) |state| {
            if (state.position.use_coordinates and state.position.entry_id == req.entry_id) {
                spawn_override_pos = .{ .x = state.position.x, .y = state.position.y, .z = state.position.z };
            }
        }
    }

    try session.send(CmdID.CmdEnterSceneScRsp, protocol.EnterSceneScRsp{
        .retcode = 0,
        .game_story_line_id = req.game_story_line_id,
        .is_close_map = req.is_close_map,
        .content_id = req.content_id,
        .is_over_map = false,
    });
    const scene_info = try scene_manager.createSceneWithSpawn(planeID, floorID, req.entry_id, teleportID, spawn_override_pos, spawn_override_rot);
    if (scene_debug_enabled) {
        log.info("[SceneDebug] EnterScene: entry_id={} plane_id={} floor_id={} teleport_id={}", .{ req.entry_id, planeID, floorID, teleportID });
    }
    try session.send(CmdID.CmdEnterSceneByServerScNotify, protocol.EnterSceneByServerScNotify{
        .lineup = lineup,
        .reason = protocol.EnterSceneReason.ENTER_SCENE_REASON_NONE,
        .scene = scene_info,
    });
}

pub fn onGetSceneMapInfo(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.GetSceneMapInfoCsReq, allocator);
    defer req.deinit();

    const EntranceMatch = struct { entry_id: u32, plane_id: u32 };
    const findEntranceByFloorId = struct {
        fn f(floor_id: u32) ?EntranceMatch {
            for (entrance_config.map_entrance_config.items) |entrance| {
                if (entrance.floor_id == floor_id) {
                    return .{ .entry_id = entrance.id, .plane_id = entrance.plane_id };
                }
            }
            return null;
        }
    }.f;

    const ranges = [_][2]usize{
        .{ 0, 101 },
        .{ 10000, 10051 },
        .{ 20000, 20001 },
        .{ 30000, 30020 },
    };
    const chest_list = &[_]protocol.ChestInfo{
        .{ .chest_type = protocol.ChestType.MAP_INFO_CHEST_TYPE_NORMAL },
        .{ .chest_type = protocol.ChestType.MAP_INFO_CHEST_TYPE_CHALLENGE },
        .{ .chest_type = protocol.ChestType.MAP_INFO_CHEST_TYPE_PUZZLE },
    };
    var rsp = protocol.GetSceneMapInfoScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.content_id = req.content_id;
    rsp.entry_story_line_id = req.entry_story_line_id;
    rsp.is_monster_track = req.unk1;

    var floor_ids = std.ArrayList(u32).init(allocator);
    defer floor_ids.deinit();
    if (req.floor_id_list.items.len > 0) {
        try floor_ids.appendSlice(req.floor_id_list.items);
    } else if (req.entry_id_list.items.len > 0) {
        for (req.entry_id_list.items) |entry_id| {
            for (entrance_config.map_entrance_config.items) |entrance| {
                if (entrance.id == entry_id) {
                    try floor_ids.append(entrance.floor_id);
                    break;
                }
            }
        }
    }

    for (floor_ids.items) |floor_id_u32| {
        const match = findEntranceByFloorId(floor_id_u32);
        const plane_id: u32 = if (match) |m| m.plane_id else floor_id_u32 / 1000;
        const floor_suffix: u32 = floor_id_u32 % 100;
        const entry_id: u32 = if (match) |m| m.entry_id else (plane_id * 100 + floor_suffix);

        var map_info = protocol.SceneMapInfo.init(allocator);
        map_info.retcode = 0;
        map_info.dimension_id = plane_id;
        map_info.entry_id = entry_id;
        map_info.floor_id = floor_id_u32;
        map_info.cur_map_entry_id = entry_id;
        try map_info.chest_list.appendSlice(chest_list);

        for (ranges) |range| {
            for (range[0]..range[1]) |i| {
                try map_info.lighten_section_list.append(@intCast(i));
            }
        }

        var group_ids = std.AutoHashMap(u32, void).init(allocator);
        defer group_ids.deinit();

        for (res_config.scene_config.items) |sceneConf| {
            if (sceneConf.planeID != plane_id or sceneConf.entryID != entry_id) continue;

            try map_info.unlock_teleport_list.ensureUnusedCapacity(sceneConf.teleports.items.len);
            for (sceneConf.teleports.items) |teleConf| {
                try map_info.unlock_teleport_list.append(@intCast(teleConf.teleportId));
            }

            try map_info.maze_prop_list.ensureUnusedCapacity(sceneConf.props.items.len);
            for (sceneConf.props.items) |propConf| {
                try map_info.maze_prop_list.append(protocol.MazePropState{
                    .group_id = propConf.groupId,
                    .config_id = propConf.instId,
                    .state = propConf.propState,
                });
                _ = try group_ids.put(propConf.groupId, {});
            }

            break;
        }

        var iter = group_ids.keyIterator();
        while (iter.next()) |gid| {
            try map_info.maze_group_list.append(protocol.MazeGroup{
                .property_map = std.ArrayList(protocol.MazeGroup.PropertyMapEntry).init(allocator),
                .destory_monster_config_id_list = std.ArrayList(u32).init(allocator),
                .group_id = gid.*,
            });
        }

        try rsp.scene_map_info.append(map_info);
    }

    try session.send(protocol.CmdID.CmdGetSceneMapInfoScRsp, rsp);
}

pub fn onSceneUpdatePositionVersionNotify(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    _ = session;
    const req = try packet.getProto(protocol.SceneUpdatePositionVersionNotify, allocator);
    defer req.deinit();
}
pub fn onGetUnlockTeleport(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var rsp = protocol.GetUnlockTeleportScRsp.init(allocator);
    var total_tps: usize = 0;
    for (res_config.scene_config.items) |scene| {
        total_tps += scene.teleports.items.len;
    }
    try rsp.unlock_teleport_list.ensureTotalCapacity(total_tps);
    for (res_config.scene_config.items) |sceneCof| {
        for (sceneCof.teleports.items) |tp| {
            rsp.unlock_teleport_list.appendAssumeCapacity(tp.teleportId);
        }
    }
    rsp.retcode = 0;
    try session.send(CmdID.CmdGetUnlockTeleportScRsp, rsp);
}
pub fn onEnterSection(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.EnterSectionCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.EnterSectionScRsp.init(allocator);
    rsp.retcode = 0;
    std.debug.print("ENTER SECTION Id: {}\n", .{req.section_id});
    try session.send(CmdID.CmdEnterSectionScRsp, rsp);
}

pub fn onGetEnteredScene(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var rsp = protocol.GetEnteredSceneScRsp.init(allocator);
    var noti = protocol.EnteredSceneChangeScNotify.init(allocator);
    for (entrance_config.map_entrance_config.items) |entrance| {
        try rsp.entered_scene_info_list.append(protocol.EnteredSceneInfo{
            .floor_id = entrance.floor_id,
            .plane_id = entrance.plane_id,
        });
        try noti.entered_scene_info_list.append(protocol.EnteredSceneInfo{
            .floor_id = entrance.floor_id,
            .plane_id = entrance.plane_id,
        });
    }
    rsp.retcode = 0;
    try session.send(CmdID.CmdEnteredSceneChangeScNotify, noti);
    try session.send(CmdID.CmdGetEnteredSceneScRsp, rsp);
}

pub fn onSceneEntityTeleport(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.SceneEntityTeleportCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.SceneEntityTeleportScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.entity_motion = req.entity_motion;
    std.debug.print("SCENE ENTITY TP ENTRY ID: {}\n", .{req.entry_id});
    try session.send(CmdID.CmdSceneEntityTeleportScRsp, rsp);
}

pub fn onGetFirstTalkNpc(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.GetFirstTalkNpcCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.GetFirstTalkNpcScRsp.init(allocator);
    rsp.retcode = 0;
    for (req.npc_id_list.items) |id| {
        try rsp.npc_meet_status_list.append(protocol.FirstNpcTalkInfo{ .npc_id = id, .is_meet = true });
    }
    try session.send(CmdID.CmdGetFirstTalkNpcScRsp, rsp);
}

pub fn onGetFirstTalkByPerformanceNp(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.GetFirstTalkByPerformanceNpcCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.GetFirstTalkByPerformanceNpcScRsp.init(allocator);
    rsp.retcode = 0;
    for (req.performance_id_list.items) |id| {
        try rsp.npc_meet_status_list.append(
            protocol.NpcMeetByPerformanceStatus{ .performance_id = id, .is_meet = true },
        );
    }
    try session.send(CmdID.CmdGetFirstTalkByPerformanceNpcScRsp, rsp);
}

pub fn onGetNpcTakenReward(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.GetNpcTakenRewardCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.GetNpcTakenRewardScRsp.init(allocator);
    const EventList = [_]u32{ 2136, 2134 };
    rsp.retcode = 0;
    rsp.npc_id = req.npc_id;
    try rsp.talk_event_list.appendSlice(&EventList);
    try session.send(CmdID.CmdGetNpcTakenRewardScRsp, rsp);
}
pub fn onUpdateGroupProperty(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.UpdateGroupPropertyCsReq, allocator);
    defer req.deinit();

    var rsp = protocol.UpdateGroupPropertyScRsp.init(allocator);
    rsp.retcode = 0;
    rsp.floor_id = req.floor_id;
    rsp.group_id = req.group_id;
    rsp.dimension_id = req.dimension_id;
    rsp.NOCBONMOOGC = req.NOCBONMOOGC;
    try session.send(CmdID.CmdUpdateGroupPropertyScRsp, rsp);
}
pub fn onChangePropTimeline(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.ChangePropTimelineInfoCsReq, allocator);
    defer req.deinit();

    try session.send(CmdID.CmdChangePropTimelineInfoScRsp, protocol.ChangePropTimelineInfoScRsp{
        .retcode = 0,
        .prop_entity_id = req.prop_entity_id,
    });
}
pub fn onDeactivateFarmElement(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.DeactivateFarmElementCsReq, allocator);
    defer req.deinit();

    std.debug.print("DeactivateFarmElement: entity_id={}\n", .{req.entity_id});

    var rsp = protocol.DeactivateFarmElementScRsp.init(allocator);
    rsp.entity_id = req.entity_id;
    rsp.retcode = 0;

    try session.send(CmdID.CmdDeactivateFarmElementScRsp, rsp);
}

pub fn onActivateFarmElement(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.ActivateFarmElementCsReq, allocator);
    defer req.deinit();

    std.debug.print("ACTIVATE FARM ELEMENT ENTITY ID: {}\n", .{req.entity_id});
    try session.send(CmdID.CmdActivateFarmElementScRsp, protocol.ActivateFarmElementScRsp{
        .retcode = 0,
        .world_level = req.world_level,
        .entity_id = req.entity_id,
    });
}
pub fn onInteractProp(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.InteractPropCsReq, allocator);
    defer req.deinit();

    std.debug.print("InteractProp: entity_id={} interact_id={}\n", .{ req.prop_entity_id, req.interact_id });

    var rsp = protocol.InteractPropScRsp.init(allocator);
    rsp.prop_entity_id = req.prop_entity_id;
    rsp.retcode = 0;

    const interact_cfg = &ConfigManager.global_game_config_cache.interact_config;
    var is_chest_open: bool = false;
    for (interact_cfg.interact_config.items) |e| {
        if (e.interact_id == req.interact_id) {
            if (e.target_state) |t| {
                if (std.mem.indexOf(u8, t, "ChestUsed") != null or std.mem.indexOf(u8, t, "Open") != null) {
                    if (e.src_state) |s| {
                        if (std.mem.indexOf(u8, s, "Chest") != null) {
                            is_chest_open = true;
                            break;
                        }
                    } else if (std.mem.indexOf(u8, t, "Chest") != null) {
                        is_chest_open = true;
                        break;
                    }
                }
            }
        }
    }

    var new_prop_state: u32 = 0;
    if (is_chest_open) {
        // Always mark chest as opened on this interaction; no persistent opened_chests tracking.
        new_prop_state = 2;
    } else {
        // not a chest open action: leave default new_prop_state = 0
    }

    // send scene refresh so client updates prop visuals (add_entity with updated prop_state)
    if (new_prop_state != 0) {
        var grp_notify = protocol.SceneGroupRefreshScNotify.init(allocator);
        grp_notify.floor_id = 0;
        var g_list = std.ArrayList(protocol.GroupRefreshInfo).init(allocator);
        defer g_list.deinit();

        var g = protocol.GroupRefreshInfo.init(allocator);
        g.refresh_type = protocol.SceneGroupRefreshType.SCENE_GROUP_REFRESH_TYPE_LOADED;
        g.group_id = 0;

        var refresh_list = std.ArrayList(protocol.SceneEntityRefreshInfo).init(allocator);
        defer refresh_list.deinit();

        var r = protocol.SceneEntityRefreshInfo.init(allocator);
        // put add_entity = SceneEntityInfo{ .entity_id = req.prop_entity_id, .entity = .{ .prop = ScenePropInfo{ .prop_state = new_prop_state } } }
        var ent = protocol.SceneEntityInfo.init(allocator);
        ent.entity_id = req.prop_entity_id;
        var prop = protocol.ScenePropInfo.init(allocator);
        prop.prop_state = new_prop_state;
        ent.entity = .{ .prop = prop };
        r.AEMKIFPBBJM = .{ .add_entity = ent };
        try refresh_list.append(r);

        g.refresh_entity = refresh_list;
        try g_list.append(g);
        grp_notify.group_refresh_list = g_list;
        try session.send(CmdID.CmdSceneGroupRefreshScNotify, grp_notify);
    }

    // finally send the InteractProp response with the prop_state reflecting the change
    rsp.prop_state = new_prop_state;
    try session.send(CmdID.CmdInteractPropScRsp, rsp);
}

pub fn onChangeEraFlipperData(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.ChangeEraFlipperDataCsReq, allocator);
    defer req.deinit();

    try session.send(CmdID.CmdChangeEraFlipperDataScRsp, protocol.ChangeEraFlipperDataScRsp{
        .retcode = 0,
        .data = req.data,
    });
}
pub fn onSetTrainWorldId(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    const req = try packet.getProto(protocol.SetTrainWorldIdCsReq, allocator);
    defer req.deinit();

    try session.send(CmdID.CmdSetTrainWorldIdScRsp, protocol.SetTrainWorldIdScRsp{
        .retcode = 0,
        .IJGLDCNMELH = req.IJGLDCNMELH,
    });
}
