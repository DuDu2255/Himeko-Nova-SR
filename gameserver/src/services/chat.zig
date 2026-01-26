const std = @import("std");
const protocol = @import("protocol");
const Session = @import("../Session.zig");
const Packet = @import("../Packet.zig");
const commandhandler = @import("../command.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const CmdID = protocol.CmdID;

const B64Decoder = std.base64.standard.Decoder;

const EmojiList = [_]u32{};
const log = std.log.scoped(.chat);

pub fn onGetFriendListInfo(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var rsp = protocol.GetFriendListInfoScRsp.init(allocator);
    rsp.retcode = 0;

    var assist_list = ArrayList(protocol.AssistSimpleInfo).init(allocator);
    try assist_list.appendSlice(&[_]protocol.AssistSimpleInfo{
        .{ .pos = 0, .level = 80, .avatar_id = 1409, .dressed_skin_id = 0 },
        .{ .pos = 1, .level = 80, .avatar_id = 1415, .dressed_skin_id = 0 },
        .{ .pos = 2, .level = 80, .avatar_id = 1407, .dressed_skin_id = 0 },
    });

    var friend = protocol.FriendSimpleInfo.init(allocator);
    friend.playing_state = .PLAYING_CHALLENGE_PEAK;
    friend.create_time = 0; //timestamp
    friend.remark_name = .{ .Const = "HyacineLover" }; //friend_custom_nickname
    friend.is_marked = true;
    friend.player_info = protocol.PlayerSimpleInfo{
        .personal_card = 253001,
        .signature = .{ .Const = "DBKAHHK" },
        .nickname = .{ .Const = "CastoricePS" },
        .level = 99,
        .uid = 2000,
        .head_icon = 200139,
        .head_frame_info = .{
            .head_frame_expire_time = 4294967295,
            .head_frame_item_id = 226004,
        },
        .chat_bubble_id = 220008,
        .assist_simple_info_list = assist_list,
        .platform = protocol.PlatformType.ANDROID,
        .online_status = protocol.FriendOnlineStatus.FRIEND_ONLINE_STATUS_ONLINE,
    };
    try rsp.friend_list.append(friend);
    try session.send(CmdID.CmdGetFriendListInfoScRsp, rsp);
}
pub fn onChatEmojiList(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var rsp = protocol.GetChatEmojiListScRsp.init(allocator);

    rsp.retcode = 0;
    try rsp.chat_emoji_list.appendSlice(&EmojiList);

    try session.send(CmdID.CmdGetChatEmojiListScRsp, rsp);
}
pub fn onPrivateChatHistory(session: *Session, _: *const Packet, allocator: Allocator) !void {
    var rsp = protocol.GetPrivateChatHistoryScRsp.init(allocator);

    rsp.retcode = 0;
    rsp.target_side = 1;
    rsp.contact_side = 2000;
    try rsp.chat_message_list.appendSlice(&[_]protocol.ChatMessageData{
        .{
            .message_data = .{
                .message_type = .MSG_TYPE_CUSTOM_TEXT,
                .chat_data = .{
                    .GHLBBDKIJKK = .{
                        .message_text = .{ .Const = "Use https://srtools.neonteam.dev/ to setup config" },
                    },
                },
            },
            .BOFJJHIKIJL = .{
                .EEDAADMACAP = .{
                    .uid = 2000,
                },
            },
        },
        .{
            .message_data = .{
                .message_type = .MSG_TYPE_CUSTOM_TEXT,
                .chat_data = .{
                    .GHLBBDKIJKK = .{
                        .message_text = .{ .Const = "/help for command list" },
                    },
                },
            },
            .BOFJJHIKIJL = .{
                .EEDAADMACAP = .{
                    .uid = 2000,
                },
            },
        },
        .{
            .message_data = .{
                .message_type = .MSG_TYPE_CUSTOM_TEXT,
                .chat_data = .{
                    .GHLBBDKIJKK = .{
                        .message_text = .{ .Const = "to use command, use '/' first" },
                    },
                },
            },
            .BOFJJHIKIJL = .{
                .EEDAADMACAP = .{
                    .uid = 2000,
                },
            },
        },
    });

    try session.send(CmdID.CmdGetPrivateChatHistoryScRsp, rsp);
}
pub fn onSendMsg(session: *Session, packet: *const Packet, allocator: Allocator) !void {
    std.debug.print("Received packet: {any}\n", .{packet});
    const req = protocol.SendMsgCsReq.init(allocator);
    defer req.deinit();

    std.debug.print("Decoded request: {any}\n", .{req});
    std.debug.print("Raw packet body: {any}\n", .{packet.body});
    const msg_text = switch (req.message_text) {
        .Empty => "",
        .Owned => |owned| owned.str,
        .Const => |const_str| const_str,
    };
    var msg_text2: []const u8 = "";
    if (packet.body.len > 9 and packet.body[9] == 47) {
        msg_text2 = packet.body[9 .. packet.body.len - 6];
    }
    std.debug.print("Manually extracted message text: '{s}'\n", .{msg_text2});

    std.debug.print("Message Text 1: {any}\n", .{msg_text});

    if (msg_text2.len > 0) {
        if (std.mem.indexOf(u8, msg_text2, "/") != null) {
            std.debug.print("Message contains a '/'\n", .{});
            try commandhandler.handleCommand(session, msg_text2, allocator);
        } else {
            std.debug.print("Message does not contain a '/'\n", .{});
            try commandhandler.sendMessage(session, msg_text2, allocator);
        }
    } else {
        std.debug.print("Empty message received\n", .{});
    }

    var rsp = protocol.SendMsgScRsp.init(allocator);
    rsp.retcode = 0;
    try session.send(CmdID.CmdSendMsgScRsp, rsp);
}
