//! UDP listener speaking the Star Rail KCP handshake, replacing the old TCP
//! listener. Mirrors March7thHoney's `KcpSharp/Listener.cs`.
//!
//! Handshake datagrams are exactly 20 bytes, all big-endian:
//!     code u32 | conv_hi u32 | conv_lo u32 | enet u32 | magic u32
//! Anything else is a KCP segment stream and goes to `Kcp.input`.

const std = @import("std");
const kcp = @import("kcp.zig");
const Session = @import("../Session.zig");
const Packet = @import("../Packet.zig");
const handlers = @import("../handlers.zig");
const ConfigManager = @import("../manager/config_mgr.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const log = std.log.scoped(.kcp);

pub const PORT: u16 = 23301;

pub const HANDSHAKE_SIZE = 20;

const CODE_CONNECT: u32 = 0x000000FF;
/// The client also opens with this value (-934149376 as a signed int).
const CODE_CONNECT_ALT: u32 = 0xC8447A00;
const CODE_ESTABLISH: u32 = 0x00000145;
const CODE_DISCONNECT: u32 = 0x00000194;

const MAGIC_ESTABLISH: u32 = 0x14514545;
const MAGIC_DISCONNECT: u32 = 0x19419494;

const MTU: u32 = 1400;
const WINDOW: u32 = 256;

/// Largest reassembled KCP message we will accept from a client.
const MAX_MESSAGE = 1 << 20;

pub const Connection = struct {
    allocator: Allocator,
    socket: posix.socket_t,
    addr: std.net.Address,
    conv: u64,
    kcp: kcp.Kcp,
    session: *Session,
    /// Scratch buffer for reassembled KCP messages.
    recv_buf: []u8,
    alive: bool = true,

    fn output(ctx: ?*anyopaque, data: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        _ = posix.sendto(
            self.socket,
            data,
            0,
            &self.addr.any,
            self.addr.getOsSockLen(),
        ) catch |err| {
            log.warn("sendto {} failed: {}", .{ self.addr, err });
            return;
        };
    }

    /// Queues one framed game packet for reliable delivery.
    pub fn send(self: *Connection, data: []const u8) !void {
        try self.kcp.send(data);
        // Push it out now rather than waiting for the next update tick.
        try self.kcp.flush();
    }

    /// Adapter installed into `Session.transport_send`.
    fn sendOpaque(handle: *Session.Connection, data: []const u8) anyerror!void {
        const self: *Connection = @ptrCast(@alignCast(handle));
        try self.send(data);
    }
};

const Server = struct {
    allocator: Allocator,
    socket: posix.socket_t,
    connections: std.ArrayList(*Connection),

    fn findByAddr(self: *Server, addr: std.net.Address) ?*Connection {
        for (self.connections.items) |conn| {
            if (conn.addr.eql(addr)) return conn;
        }
        return null;
    }

    fn nextConvId(self: *Server) u64 {
        var candidate: u64 = 1;
        outer: while (true) : (candidate += 1) {
            for (self.connections.items) |conn| {
                if (conn.conv == candidate) continue :outer;
            }
            return candidate;
        }
    }

    fn accept(self: *Server, addr: std.net.Address, enet: u32) !void {
        const conv = self.nextConvId();

        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        const recv_buf = try self.allocator.alloc(u8, MAX_MESSAGE);
        errdefer self.allocator.free(recv_buf);

        conn.* = .{
            .allocator = self.allocator,
            .socket = self.socket,
            .addr = addr,
            .conv = conv,
            .kcp = undefined,
            .session = session,
            .recv_buf = recv_buf,
        };

        conn.kcp = try kcp.Kcp.init(self.allocator, conv, conn, Connection.output);
        conn.kcp.setNoDelay(true, 100, 0, false);
        conn.kcp.setWndSize(WINDOW, WINDOW);
        try conn.kcp.setMtu(MTU);

        session.* = Session.init(
            addr,
            @ptrCast(conn),
            self.allocator,
            ConfigManager.global_main_allocator,
            &ConfigManager.global_game_config_cache,
        );

        try self.connections.append(conn);

        log.info("accepting game handshake from {}. conv_id={} enet={}", .{ addr, conv, enet });
        try self.sendHandshake(addr, CODE_ESTABLISH, conv, enet, MAGIC_ESTABLISH);
    }

    fn sendHandshake(self: *Server, addr: std.net.Address, code: u32, conv: u64, value: u32, magic: u32) !void {
        var buf: [HANDSHAKE_SIZE]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], code, .big);
        std.mem.writeInt(u32, buf[4..8], @intCast(conv >> 32), .big);
        std.mem.writeInt(u32, buf[8..12], @truncate(conv), .big);
        std.mem.writeInt(u32, buf[12..16], value, .big);
        std.mem.writeInt(u32, buf[16..20], magic, .big);
        _ = try posix.sendto(self.socket, &buf, 0, &addr.any, addr.getOsSockLen());
    }

    fn disconnect(self: *Server, conn: *Connection, code: u32) void {
        self.sendHandshake(conn.addr, CODE_DISCONNECT, conn.conv, code, MAGIC_DISCONNECT) catch {};
        self.remove(conn);
    }

    fn remove(self: *Server, conn: *Connection) void {
        for (self.connections.items, 0..) |item, i| {
            if (item == conn) {
                _ = self.connections.orderedRemove(i);
                break;
            }
        }
        log.info("connection with {} has been closed", .{conn.addr});
        conn.kcp.deinit();
        self.allocator.free(conn.recv_buf);
        self.allocator.destroy(conn.session);
        self.allocator.destroy(conn);
    }

    fn handleHandshake(self: *Server, addr: std.net.Address, data: []const u8) !void {
        const code = std.mem.readInt(u32, data[0..4], .big);
        const enet = std.mem.readInt(u32, data[12..16], .big);

        switch (code) {
            CODE_CONNECT, CODE_CONNECT_ALT => {
                if (self.findByAddr(addr)) |existing| {
                    // The client retries the handshake if our reply was lost;
                    // drop the stale session and hand out a fresh conv id.
                    log.info("duplicate handshake from {}, resetting session", .{existing.addr});
                    self.remove(existing);
                }
                try self.accept(addr, enet);
            },
            CODE_DISCONNECT => {
                if (self.findByAddr(addr)) |conn| {
                    self.disconnect(conn, 5);
                } else {
                    log.info("inexistent connection asked for disconnect from {}", .{addr});
                }
            },
            else => log.warn("invalid handshake code received {x}", .{code}),
        }
    }

    /// Drains every fully reassembled game packet and dispatches it.
    fn drain(conn: *Connection) void {
        while (true) {
            const size = conn.kcp.recv(conn.recv_buf) catch |err| {
                log.warn("kcp recv failed for {}: {}", .{ conn.addr, err });
                conn.alive = false;
                return;
            } orelse return;

            var rest: []const u8 = conn.recv_buf[0..size];
            while (rest.len > 0) {
                var packet = Packet.decode(rest, conn.session.allocator) catch |err| {
                    log.warn("malformed packet from {}: {}", .{ conn.addr, err });
                    conn.alive = false;
                    return;
                };
                defer packet.deinit();

                rest = rest[packet.frame_len..];

                ConfigManager.config_lock.lock();
                defer ConfigManager.config_lock.unlock();

                handlers.handle(conn.session, &packet) catch |err| {
                    log.err("handler for packet {} failed: {}", .{ packet.cmd_id, err });
                };
            }
        }
    }
};

/// Winsock's SO_RCVTIMEO takes a DWORD of milliseconds; POSIX takes a timeval.
/// Getting this wrong on Windows silently means "block forever", which would
/// stall the KCP update tick whenever the socket is idle.
fn setRecvTimeout(socket: posix.socket_t, millis: u32) !void {
    if (@import("builtin").os.tag == .windows) {
        const value: u32 = millis;
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&value));
    } else {
        const timeout = posix.timeval{
            .sec = @intCast(millis / std.time.ms_per_s),
            .usec = @intCast((millis % std.time.ms_per_s) * std.time.us_per_ms),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    }
}

pub fn listen() !void {
    const allocator = ConfigManager.global_main_allocator;

    Session.transport_send = Connection.sendOpaque;

    const addr = std.net.Address.parseIp4("0.0.0.0", PORT) catch unreachable;
    const socket = try posix.socket(
        addr.any.family,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    // Short timeout so the update loop still ticks on an idle socket.
    try setRecvTimeout(socket, 10);

    var server = Server{
        .allocator = allocator,
        .socket = socket,
        .connections = std.ArrayList(*Connection).init(allocator),
    };
    defer {
        while (server.connections.items.len > 0) server.remove(server.connections.items[0]);
        server.connections.deinit();
    }

    log.info("server is listening at {} (KCP/UDP)", .{addr});

    const start = std.time.milliTimestamp();
    var buf: [MTU * 2]u8 = undefined;

    while (true) {
        var src_addr: posix.sockaddr.storage = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const received = posix.recvfrom(
            socket,
            &buf,
            0,
            @ptrCast(&src_addr),
            &src_len,
        ) catch |err| switch (err) {
            error.WouldBlock => 0,
            // Windows reports ICMP port-unreachable on the *next* recv; ignore.
            error.ConnectionResetByPeer => 0,
            else => return err,
        };

        const now: u32 = @truncate(@as(u64, @intCast(std.time.milliTimestamp() - start)));

        if (received > 0) {
            const peer = std.net.Address.initPosix(@alignCast(@ptrCast(&src_addr)));
            const data = buf[0..received];

            if (received == HANDSHAKE_SIZE) {
                server.handleHandshake(peer, data) catch |err| {
                    log.err("failed to handle handshake: {}", .{err});
                };
            } else if (server.findByAddr(peer)) |conn| {
                conn.kcp.input(data) catch |err| {
                    log.warn("kcp input from {} rejected: {}", .{ peer, err });
                };
                Server.drain(conn);
            }
        }

        // Tick every conversation and reap the dead ones.
        var i: usize = 0;
        while (i < server.connections.items.len) {
            const conn = server.connections.items[i];
            conn.kcp.update(now) catch |err| {
                log.warn("kcp update for {} failed: {}", .{ conn.addr, err });
                conn.alive = false;
            };
            if (!conn.alive or conn.kcp.dead) {
                server.disconnect(conn, 5);
            } else {
                i += 1;
            }
        }
    }
}
