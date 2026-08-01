//! KCP reliable-UDP transport, ported from ikcp.c (MIT, skywind3000).
//!
//! The wire format is NOT vanilla ikcp: Star Rail (and March7thHoney's KcpSharp)
//! prefix every segment with a 64-bit BIG-endian conversation id instead of
//! ikcp's 32-bit little-endian one, giving a 28-byte header:
//!
//!     conv u64 BE | cmd u8 | frg u8 | wnd u16 LE | ts u32 LE | sn u32 LE | una u32 LE | len u32 LE
//!
//! Everything below the framing is stock KCP.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const OVERHEAD: u32 = 28;

const RTO_NDL: u32 = 30;
const RTO_MIN: u32 = 100;
const RTO_DEF: u32 = 200;
const RTO_MAX: u32 = 60000;

const CMD_PUSH: u8 = 81;
const CMD_ACK: u8 = 82;
const CMD_WASK: u8 = 83;
const CMD_WINS: u8 = 84;

const ASK_SEND: u32 = 1;
const ASK_TELL: u32 = 2;

const WND_SND: u32 = 32;
const WND_RCV: u32 = 128;
const MTU_DEF: u32 = 1400;
const INTERVAL: u32 = 100;
const DEADLINK: u32 = 20;
const THRESH_INIT: u32 = 2;
const THRESH_MIN: u32 = 2;
const PROBE_INIT: u32 = 7000;
const PROBE_LIMIT: u32 = 120000;
const FASTACK_LIMIT: u32 = 5;

/// Signed distance between two wrapping timestamps/serial numbers.
inline fn diff(later: u32, earlier: u32) i32 {
    return @bitCast(later -% earlier);
}

inline fn boundRto(rto: u32, minrto: u32) u32 {
    return std.math.clamp(rto, minrto, RTO_MAX);
}

const Segment = struct {
    cmd: u8 = 0,
    frg: u8 = 0,
    wnd: u16 = 0,
    ts: u32 = 0,
    sn: u32 = 0,
    una: u32 = 0,
    resendts: u32 = 0,
    rto: u32 = 0,
    fastack: u32 = 0,
    xmit: u32 = 0,
    data: []u8 = &.{},

    fn create(allocator: Allocator, size: usize) !*Segment {
        const seg = try allocator.create(Segment);
        seg.* = .{ .data = if (size > 0) try allocator.alloc(u8, size) else &.{} };
        return seg;
    }

    fn destroy(self: *Segment, allocator: Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        allocator.destroy(self);
    }
};

const Ack = struct { sn: u32, ts: u32 };

pub const OutputFn = *const fn (ctx: ?*anyopaque, data: []const u8) void;

pub const Kcp = struct {
    allocator: Allocator,
    conv: u64,

    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    rcv_nxt: u32 = 0,

    ssthresh: u32 = THRESH_INIT,

    rx_rttval: i32 = 0,
    rx_srtt: i32 = 0,
    rx_rto: u32 = RTO_DEF,
    rx_minrto: u32 = RTO_MIN,

    snd_wnd: u32 = WND_SND,
    rcv_wnd: u32 = WND_RCV,
    rmt_wnd: u32 = WND_RCV,
    cwnd: u32 = 0,
    probe: u32 = 0,

    mtu: u32 = MTU_DEF,
    mss: u32 = MTU_DEF - OVERHEAD,

    current: u32 = 0,
    interval: u32 = INTERVAL,
    ts_flush: u32 = INTERVAL,
    xmit: u32 = 0,

    nodelay: bool = false,
    nocwnd: bool = false,
    stream: bool = false,
    updated: bool = false,

    ts_probe: u32 = 0,
    probe_wait: u32 = 0,

    dead_link: u32 = DEADLINK,
    incr: u32 = 0,

    fastresend: u32 = 0,
    fastlimit: u32 = FASTACK_LIMIT,

    /// Set once the peer stops responding for `dead_link` retransmits.
    dead: bool = false,

    snd_queue: ArrayList(*Segment),
    snd_buf: ArrayList(*Segment),
    rcv_queue: ArrayList(*Segment),
    rcv_buf: ArrayList(*Segment),
    acklist: ArrayList(Ack),

    buffer: []u8,

    output_ctx: ?*anyopaque,
    output_fn: OutputFn,

    const Self = @This();

    pub fn init(allocator: Allocator, conv: u64, ctx: ?*anyopaque, output_fn: OutputFn) !Self {
        return .{
            .allocator = allocator,
            .conv = conv,
            .snd_queue = ArrayList(*Segment).init(allocator),
            .snd_buf = ArrayList(*Segment).init(allocator),
            .rcv_queue = ArrayList(*Segment).init(allocator),
            .rcv_buf = ArrayList(*Segment).init(allocator),
            .acklist = ArrayList(Ack).init(allocator),
            .buffer = try allocator.alloc(u8, (MTU_DEF + OVERHEAD) * 3),
            .output_ctx = ctx,
            .output_fn = output_fn,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.snd_queue.items) |seg| seg.destroy(self.allocator);
        for (self.snd_buf.items) |seg| seg.destroy(self.allocator);
        for (self.rcv_queue.items) |seg| seg.destroy(self.allocator);
        for (self.rcv_buf.items) |seg| seg.destroy(self.allocator);
        self.snd_queue.deinit();
        self.snd_buf.deinit();
        self.rcv_queue.deinit();
        self.rcv_buf.deinit();
        self.acklist.deinit();
        self.allocator.free(self.buffer);
    }

    /// Matches ikcp_nodelay(). `resend` is the fast-retransmit threshold.
    pub fn setNoDelay(self: *Self, nodelay: bool, interval: u32, resend: u32, nocwnd: bool) void {
        self.nodelay = nodelay;
        self.rx_minrto = if (nodelay) RTO_NDL else RTO_MIN;
        self.interval = std.math.clamp(interval, 10, 5000);
        self.fastresend = resend;
        self.nocwnd = nocwnd;
    }

    pub fn setWndSize(self: *Self, sndwnd: u32, rcvwnd: u32) void {
        if (sndwnd > 0) self.snd_wnd = sndwnd;
        // The receive window must be able to hold a full out-of-order burst.
        if (rcvwnd > 0) self.rcv_wnd = @max(rcvwnd, WND_RCV);
    }

    pub fn setMtu(self: *Self, mtu: u32) !void {
        if (mtu < 50 or mtu < OVERHEAD) return error.InvalidMtu;
        const buffer = try self.allocator.alloc(u8, (mtu + OVERHEAD) * 3);
        self.allocator.free(self.buffer);
        self.buffer = buffer;
        self.mtu = mtu;
        self.mss = mtu - OVERHEAD;
    }

    // ---------------------------------------------------------------- header

    fn encodeSeg(self: *const Self, dst: []u8, seg: *const Segment) usize {
        std.mem.writeInt(u64, dst[0..8], self.conv, .big);
        dst[8] = seg.cmd;
        dst[9] = seg.frg;
        std.mem.writeInt(u16, dst[10..12], seg.wnd, .little);
        std.mem.writeInt(u32, dst[12..16], seg.ts, .little);
        std.mem.writeInt(u32, dst[16..20], seg.sn, .little);
        std.mem.writeInt(u32, dst[20..24], seg.una, .little);
        std.mem.writeInt(u32, dst[24..28], @intCast(seg.data.len), .little);
        return OVERHEAD;
    }

    // -------------------------------------------------------------- receiving

    /// Bytes of the next complete message, or null when none is ready.
    pub fn peekSize(self: *const Self) ?usize {
        if (self.rcv_queue.items.len == 0) return null;

        const first = self.rcv_queue.items[0];
        if (first.frg == 0) return first.data.len;
        if (self.rcv_queue.items.len < @as(usize, first.frg) + 1) return null;

        var length: usize = 0;
        for (self.rcv_queue.items) |seg| {
            length += seg.data.len;
            if (seg.frg == 0) break;
        }
        return length;
    }

    /// Pops one complete message into `dst`. Returns the byte count written.
    pub fn recv(self: *Self, dst: []u8) !?usize {
        const peek = self.peekSize() orelse return null;
        if (peek > dst.len) return error.BufferTooSmall;

        const recover = self.rcv_queue.items.len >= self.rcv_wnd;

        var written: usize = 0;
        while (self.rcv_queue.items.len > 0) {
            const seg = self.rcv_queue.orderedRemove(0);
            @memcpy(dst[written..][0..seg.data.len], seg.data);
            written += seg.data.len;
            const done = seg.frg == 0;
            seg.destroy(self.allocator);
            if (done) break;
        }

        try self.moveToRcvQueue();

        // The window re-opened; tell the peer so it stops stalling.
        if (self.rcv_queue.items.len < self.rcv_wnd and recover) {
            self.probe |= ASK_TELL;
        }

        return written;
    }

    fn moveToRcvQueue(self: *Self) !void {
        while (self.rcv_buf.items.len > 0) {
            const seg = self.rcv_buf.items[0];
            if (seg.sn != self.rcv_nxt or self.rcv_queue.items.len >= self.rcv_wnd) break;
            _ = self.rcv_buf.orderedRemove(0);
            try self.rcv_queue.append(seg);
            self.rcv_nxt +%= 1;
        }
    }

    // ---------------------------------------------------------------- sending

    pub fn send(self: *Self, buffer: []const u8) !void {
        if (buffer.len == 0) return error.EmptyPayload;

        var data = buffer;

        // Stream mode appends into the tail segment; message mode never does.
        if (self.stream and self.snd_queue.items.len > 0) {
            const last = self.snd_queue.items[self.snd_queue.items.len - 1];
            if (last.data.len < self.mss) {
                const capacity = self.mss - @as(u32, @intCast(last.data.len));
                const extend = @min(data.len, capacity);
                const merged = try self.allocator.alloc(u8, last.data.len + extend);
                @memcpy(merged[0..last.data.len], last.data);
                @memcpy(merged[last.data.len..], data[0..extend]);
                self.allocator.free(last.data);
                last.data = merged;
                last.frg = 0;
                data = data[extend..];
                if (data.len == 0) return;
            }
        }

        var count = (data.len + self.mss - 1) / self.mss;
        if (count > 255) return error.PayloadTooLarge;
        if (count == 0) count = 1;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const size = @min(data.len, self.mss);
            const seg = try Segment.create(self.allocator, size);
            errdefer seg.destroy(self.allocator);
            @memcpy(seg.data, data[0..size]);
            seg.frg = if (self.stream) 0 else @intCast(count - i - 1);
            try self.snd_queue.append(seg);
            data = data[size..];
        }
    }

    // ------------------------------------------------------------------ input

    /// Feeds one raw UDP datagram (which may carry several KCP segments).
    pub fn input(self: *Self, packet: []const u8) !void {
        if (packet.len < OVERHEAD) return error.ShortPacket;

        const prev_una = self.snd_una;
        var maxack: u32 = 0;
        var latest_ts: u32 = 0;
        var has_ack = false;

        var rest = packet;
        while (rest.len >= OVERHEAD) {
            const conv = std.mem.readInt(u64, rest[0..8], .big);
            if (conv != self.conv) return error.ConversationMismatch;

            const cmd = rest[8];
            const frg = rest[9];
            const wnd = std.mem.readInt(u16, rest[10..12], .little);
            const ts = std.mem.readInt(u32, rest[12..16], .little);
            const sn = std.mem.readInt(u32, rest[16..20], .little);
            const una = std.mem.readInt(u32, rest[20..24], .little);
            const len = std.mem.readInt(u32, rest[24..28], .little);

            rest = rest[OVERHEAD..];
            if (len > rest.len) return error.TruncatedSegment;

            switch (cmd) {
                CMD_PUSH, CMD_ACK, CMD_WASK, CMD_WINS => {},
                else => return error.UnknownCommand,
            }

            self.rmt_wnd = wnd;
            self.parseUna(una);
            self.shrinkBuf();

            switch (cmd) {
                CMD_ACK => {
                    const rtt = diff(self.current, ts);
                    if (rtt >= 0) self.updateAck(rtt);
                    self.parseAck(sn);
                    self.shrinkBuf();

                    if (!has_ack) {
                        has_ack = true;
                        maxack = sn;
                        latest_ts = ts;
                    } else if (diff(sn, maxack) > 0) {
                        maxack = sn;
                        latest_ts = ts;
                    }
                },
                CMD_PUSH => {
                    if (diff(sn, self.rcv_nxt +% self.rcv_wnd) < 0) {
                        try self.acklist.append(.{ .sn = sn, .ts = ts });
                        if (diff(sn, self.rcv_nxt) >= 0) {
                            const seg = try Segment.create(self.allocator, len);
                            seg.cmd = cmd;
                            seg.frg = frg;
                            seg.wnd = wnd;
                            seg.ts = ts;
                            seg.sn = sn;
                            seg.una = una;
                            if (len > 0) @memcpy(seg.data, rest[0..len]);
                            try self.parseData(seg);
                        }
                    }
                },
                CMD_WASK => self.probe |= ASK_TELL,
                CMD_WINS => {},
                else => unreachable,
            }

            rest = rest[len..];
        }

        if (has_ack) self.parseFastAck(maxack, latest_ts);

        // Congestion window growth on newly acknowledged data.
        if (diff(self.snd_una, prev_una) > 0 and self.cwnd < self.rmt_wnd) {
            const mss = self.mss;
            if (self.cwnd < self.ssthresh) {
                self.cwnd += 1;
                self.incr += mss;
            } else {
                if (self.incr < mss) self.incr = mss;
                self.incr += (mss * mss) / self.incr + (mss / 16);
                if ((self.cwnd + 1) * mss <= self.incr) {
                    self.cwnd = if (mss > 0) (self.incr + mss - 1) / mss else self.cwnd + 1;
                }
            }
            if (self.cwnd > self.rmt_wnd) {
                self.cwnd = self.rmt_wnd;
                self.incr = self.rmt_wnd * mss;
            }
        }
    }

    fn updateAck(self: *Self, rtt: i32) void {
        if (self.rx_srtt == 0) {
            self.rx_srtt = rtt;
            self.rx_rttval = @divTrunc(rtt, 2);
        } else {
            var delta = rtt - self.rx_srtt;
            if (delta < 0) delta = -delta;
            self.rx_rttval = @divTrunc(3 * self.rx_rttval + delta, 4);
            self.rx_srtt = @divTrunc(7 * self.rx_srtt + rtt, 8);
            if (self.rx_srtt < 1) self.rx_srtt = 1;
        }
        const rto: i32 = self.rx_srtt + @max(@as(i32, @intCast(self.interval)), 4 * self.rx_rttval);
        self.rx_rto = boundRto(@intCast(@max(rto, 0)), self.rx_minrto);
    }

    fn shrinkBuf(self: *Self) void {
        self.snd_una = if (self.snd_buf.items.len > 0) self.snd_buf.items[0].sn else self.snd_nxt;
    }

    fn parseAck(self: *Self, sn: u32) void {
        if (diff(sn, self.snd_una) < 0 or diff(sn, self.snd_nxt) >= 0) return;

        for (self.snd_buf.items, 0..) |seg, i| {
            if (seg.sn == sn) {
                _ = self.snd_buf.orderedRemove(i);
                seg.destroy(self.allocator);
                return;
            }
            if (diff(sn, seg.sn) < 0) return;
        }
    }

    fn parseUna(self: *Self, una: u32) void {
        while (self.snd_buf.items.len > 0) {
            const seg = self.snd_buf.items[0];
            if (diff(una, seg.sn) <= 0) break;
            _ = self.snd_buf.orderedRemove(0);
            seg.destroy(self.allocator);
        }
    }

    fn parseFastAck(self: *Self, sn: u32, ts: u32) void {
        if (diff(sn, self.snd_una) < 0 or diff(sn, self.snd_nxt) >= 0) return;

        for (self.snd_buf.items) |seg| {
            if (diff(sn, seg.sn) < 0) break;
            if (sn != seg.sn and diff(ts, seg.ts) >= 0) seg.fastack += 1;
        }
    }

    fn parseData(self: *Self, newseg: *Segment) !void {
        const sn = newseg.sn;

        if (diff(sn, self.rcv_nxt +% self.rcv_wnd) >= 0 or diff(sn, self.rcv_nxt) < 0) {
            newseg.destroy(self.allocator);
            return;
        }

        // rcv_buf is kept sorted by sn; scan from the back where new data lands.
        var insert_at: usize = 0;
        var repeat = false;
        var i: usize = self.rcv_buf.items.len;
        while (i > 0) {
            i -= 1;
            const seg = self.rcv_buf.items[i];
            if (seg.sn == sn) {
                repeat = true;
                break;
            }
            if (diff(sn, seg.sn) > 0) {
                insert_at = i + 1;
                break;
            }
            insert_at = i;
        }

        if (repeat) {
            newseg.destroy(self.allocator);
        } else {
            try self.rcv_buf.insert(insert_at, newseg);
        }

        try self.moveToRcvQueue();
    }

    // ------------------------------------------------------------------ flush

    fn unusedWnd(self: *const Self) u16 {
        const used = self.rcv_queue.items.len;
        if (used >= self.rcv_wnd) return 0;
        return @intCast(self.rcv_wnd - used);
    }

    pub fn flush(self: *Self) !void {
        if (!self.updated) return;

        const current = self.current;
        var seg = Segment{
            .cmd = CMD_ACK,
            .wnd = self.unusedWnd(),
            .una = self.rcv_nxt,
        };

        var size: usize = 0;

        // A local closure would need a captured self; keep it explicit instead.
        const flushBuffer = struct {
            fn call(kcp: *Self, len: *usize) void {
                if (len.* > 0) {
                    kcp.output_fn(kcp.output_ctx, kcp.buffer[0..len.*]);
                    len.* = 0;
                }
            }
        }.call;

        // 1. acknowledgements
        for (self.acklist.items) |ack| {
            if (size + OVERHEAD > self.mtu) flushBuffer(self, &size);
            seg.sn = ack.sn;
            seg.ts = ack.ts;
            size += self.encodeSeg(self.buffer[size..], &seg);
        }
        self.acklist.clearRetainingCapacity();

        // 2. window probing
        if (self.rmt_wnd == 0) {
            if (self.probe_wait == 0) {
                self.probe_wait = PROBE_INIT;
                self.ts_probe = current +% self.probe_wait;
            } else if (diff(current, self.ts_probe) >= 0) {
                if (self.probe_wait < PROBE_INIT) self.probe_wait = PROBE_INIT;
                self.probe_wait += self.probe_wait / 2;
                if (self.probe_wait > PROBE_LIMIT) self.probe_wait = PROBE_LIMIT;
                self.ts_probe = current +% self.probe_wait;
                self.probe |= ASK_SEND;
            }
        } else {
            self.ts_probe = 0;
            self.probe_wait = 0;
        }

        if (self.probe & ASK_SEND != 0) {
            seg.cmd = CMD_WASK;
            seg.sn = 0;
            seg.ts = 0;
            if (size + OVERHEAD > self.mtu) flushBuffer(self, &size);
            size += self.encodeSeg(self.buffer[size..], &seg);
        }
        if (self.probe & ASK_TELL != 0) {
            seg.cmd = CMD_WINS;
            seg.sn = 0;
            seg.ts = 0;
            if (size + OVERHEAD > self.mtu) flushBuffer(self, &size);
            size += self.encodeSeg(self.buffer[size..], &seg);
        }
        self.probe = 0;

        // 3. move send queue into the send buffer, bounded by the window
        var cwnd = @min(self.snd_wnd, self.rmt_wnd);
        if (!self.nocwnd) cwnd = @min(self.cwnd, cwnd);

        while (diff(self.snd_nxt, self.snd_una +% cwnd) < 0) {
            if (self.snd_queue.items.len == 0) break;
            const newseg = self.snd_queue.orderedRemove(0);
            newseg.cmd = CMD_PUSH;
            newseg.wnd = seg.wnd;
            newseg.ts = current;
            newseg.sn = self.snd_nxt;
            self.snd_nxt +%= 1;
            newseg.una = self.rcv_nxt;
            newseg.resendts = current;
            newseg.rto = self.rx_rto;
            newseg.fastack = 0;
            newseg.xmit = 0;
            try self.snd_buf.append(newseg);
        }

        // 4. data segments
        const resent: u32 = if (self.fastresend > 0) self.fastresend else std.math.maxInt(u32);
        const rtomin: u32 = if (!self.nodelay) self.rx_rto >> 3 else 0;

        var lost = false;
        var change = false;

        for (self.snd_buf.items) |segment| {
            var needsend = false;

            if (segment.xmit == 0) {
                needsend = true;
                segment.xmit += 1;
                segment.rto = self.rx_rto;
                segment.resendts = current +% segment.rto +% rtomin;
            } else if (diff(current, segment.resendts) >= 0) {
                needsend = true;
                segment.xmit += 1;
                self.xmit += 1;
                if (!self.nodelay) {
                    segment.rto += @max(segment.rto, self.rx_rto);
                } else {
                    segment.rto += segment.rto / 2;
                }
                segment.resendts = current +% segment.rto;
                lost = true;
            } else if (segment.fastack >= resent and
                (segment.xmit <= self.fastlimit or self.fastlimit == 0))
            {
                needsend = true;
                segment.xmit += 1;
                segment.fastack = 0;
                segment.resendts = current +% segment.rto;
                change = true;
            }

            if (!needsend) continue;

            segment.ts = current;
            segment.wnd = seg.wnd;
            segment.una = self.rcv_nxt;

            const need = OVERHEAD + segment.data.len;
            if (size + need > self.mtu) flushBuffer(self, &size);

            size += self.encodeSeg(self.buffer[size..], segment);
            if (segment.data.len > 0) {
                @memcpy(self.buffer[size..][0..segment.data.len], segment.data);
                size += segment.data.len;
            }

            if (segment.xmit >= self.dead_link) self.dead = true;
        }

        flushBuffer(self, &size);

        // 5. congestion control
        if (change) {
            const inflight = self.snd_nxt -% self.snd_una;
            self.ssthresh = @max(inflight / 2, THRESH_MIN);
            self.cwnd = self.ssthresh + resent;
            self.incr = self.cwnd * self.mss;
        }

        if (lost) {
            self.ssthresh = @max(cwnd / 2, THRESH_MIN);
            self.cwnd = 1;
            self.incr = self.mss;
        }

        if (self.cwnd < 1) {
            self.cwnd = 1;
            self.incr = self.mss;
        }
    }

    /// Call repeatedly with a millisecond clock; drives retransmission.
    pub fn update(self: *Self, current: u32) !void {
        self.current = current;

        if (!self.updated) {
            self.updated = true;
            self.ts_flush = current;
        }

        var slap = diff(current, self.ts_flush);
        if (slap >= 10000 or slap < -10000) {
            self.ts_flush = current;
            slap = 0;
        }

        if (slap >= 0) {
            self.ts_flush +%= self.interval;
            if (diff(current, self.ts_flush) >= 0) self.ts_flush = current +% self.interval;
            try self.flush();
        }
    }

    /// Earliest millisecond at which `update` must run again.
    pub fn check(self: *const Self, current: u32) u32 {
        if (!self.updated) return current;

        var ts_flush = self.ts_flush;
        if (diff(current, ts_flush) >= 10000 or diff(current, ts_flush) < -10000) ts_flush = current;
        if (diff(current, ts_flush) >= 0) return current;

        var minimal: u32 = @intCast(@max(diff(ts_flush, current), 0));

        for (self.snd_buf.items) |seg| {
            const delta = diff(seg.resendts, current);
            if (delta <= 0) return current;
            if (@as(u32, @intCast(delta)) < minimal) minimal = @intCast(delta);
        }

        if (minimal > self.interval) minimal = self.interval;
        return current +% minimal;
    }

    /// Segments still waiting to be sent or acknowledged.
    pub fn waitSnd(self: *const Self) usize {
        return self.snd_buf.items.len + self.snd_queue.items.len;
    }
};

test "send and receive a fragmented message over a lossless pair" {
    const allocator = std.testing.allocator;

    const Pipe = struct {
        var a_to_b: ArrayList([]u8) = undefined;
        var b_to_a: ArrayList([]u8) = undefined;
        var alloc: Allocator = undefined;

        fn outA(_: ?*anyopaque, data: []const u8) void {
            a_to_b.append(alloc.dupe(u8, data) catch unreachable) catch unreachable;
        }
        fn outB(_: ?*anyopaque, data: []const u8) void {
            b_to_a.append(alloc.dupe(u8, data) catch unreachable) catch unreachable;
        }
    };

    Pipe.alloc = allocator;
    Pipe.a_to_b = ArrayList([]u8).init(allocator);
    Pipe.b_to_a = ArrayList([]u8).init(allocator);
    defer {
        for (Pipe.a_to_b.items) |p| allocator.free(p);
        for (Pipe.b_to_a.items) |p| allocator.free(p);
        Pipe.a_to_b.deinit();
        Pipe.b_to_a.deinit();
    }

    var a = try Kcp.init(allocator, 0x1234_5678_9abc, null, Pipe.outA);
    defer a.deinit();
    var b = try Kcp.init(allocator, 0x1234_5678_9abc, null, Pipe.outB);
    defer b.deinit();

    a.setNoDelay(true, 100, 0, false);
    b.setNoDelay(true, 100, 0, false);
    a.setWndSize(256, 256);
    b.setWndSize(256, 256);

    // Larger than one MSS, so it must fragment and reassemble.
    const payload = try allocator.alloc(u8, 4000);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @intCast(i % 251);

    try a.send(payload);

    var clock: u32 = 1;
    var received: ?usize = null;
    const out = try allocator.alloc(u8, 8192);
    defer allocator.free(out);

    var round: usize = 0;
    while (round < 40 and received == null) : (round += 1) {
        try a.update(clock);
        try b.update(clock);

        for (Pipe.a_to_b.items) |p| try b.input(p);
        for (Pipe.a_to_b.items) |p| allocator.free(p);
        Pipe.a_to_b.clearRetainingCapacity();

        for (Pipe.b_to_a.items) |p| try a.input(p);
        for (Pipe.b_to_a.items) |p| allocator.free(p);
        Pipe.b_to_a.clearRetainingCapacity();

        received = try b.recv(out);
        clock += 10;
    }

    try std.testing.expectEqual(@as(?usize, payload.len), received);
    try std.testing.expectEqualSlices(u8, payload, out[0..payload.len]);
}

test "header uses big-endian conv followed by little-endian fields" {
    const allocator = std.testing.allocator;

    const Sink = struct {
        var last: [64]u8 = undefined;
        var len: usize = 0;
        fn out(_: ?*anyopaque, data: []const u8) void {
            @memcpy(last[0..data.len], data);
            len = data.len;
        }
    };

    var kcp = try Kcp.init(allocator, 0x0011_2233_4455_6677, null, Sink.out);
    defer kcp.deinit();
    kcp.setNoDelay(true, 100, 0, true);
    kcp.rmt_wnd = 32;

    try kcp.send("hi");
    try kcp.update(1);

    try std.testing.expectEqual(@as(usize, OVERHEAD + 2), Sink.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 }, Sink.last[0..8]);
    try std.testing.expectEqual(CMD_PUSH, Sink.last[8]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, Sink.last[24..28], .little));
    try std.testing.expectEqualSlices(u8, "hi", Sink.last[28..30]);
}
