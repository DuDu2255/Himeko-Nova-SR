const std = @import("std");
const protocol = @import("protocol");
const Packet = @import("Packet.zig");
const ConfigManager = @import("../src/manager/config_mgr.zig");

const Allocator = std.mem.Allocator;
const Address = std.net.Address;

const Self = @This();
const log = std.log.scoped(.session);

/// Transport handle. Declared as an opaque pointer type here to keep
/// `kcp_server` -> `Session` -> `handlers` from forming an import cycle.
pub const Connection = opaque {};

/// Set by kcp_server at startup; sends one framed packet over the conversation.
pub var transport_send: *const fn (conn: *Connection, data: []const u8) anyerror!void = undefined;

address: Address,
conn: *Connection,
allocator: Allocator,
main_allocator: Allocator,
game_config_cache: *ConfigManager.GameConfigCache,

pub fn init(
    address: Address,
    conn: *Connection,
    session_allocator: Allocator,
    main_allocator: Allocator,
    game_config_cache: *ConfigManager.GameConfigCache,
) Self {
    return .{
        .address = address,
        .conn = conn,
        .allocator = session_allocator,
        .main_allocator = main_allocator,
        .game_config_cache = game_config_cache,
    };
}

pub fn send(self: *Self, cmd_id: protocol.CmdID, proto: anytype) !void {
    const data = try proto.encode(self.allocator);
    defer self.allocator.free(data);

    const packet = try Packet.encode(@intFromEnum(cmd_id), &.{}, data, self.allocator);
    defer self.allocator.free(packet);

    try transport_send(self.conn, packet);
}

pub fn send_empty(self: *Self, cmd_id: protocol.CmdID) !void {
    const packet = try Packet.encode(@intFromEnum(cmd_id), &.{}, &.{}, self.allocator);
    defer self.allocator.free(packet);

    try transport_send(self.conn, packet);
    log.debug("sent EMPTY packet with id {}", .{cmd_id});
}
