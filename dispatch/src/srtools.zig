//! SRTools integration, wire-compatible with RobinSR's provider
//! (`sdkserver/src/services/sr_tools.rs`), which is what SRTools' "RobinSR"
//! entry expects on port 21000:
//!
//!   POST /srtools   { "data": { ...freesr-data.json... } }
//!   -> { "message": "OK", "status": 200 }   (always HTTP 200)
//!
//! A body without `data` is SRTools' liveness probe (the Connect button) and
//! must answer OK, otherwise the UI reports "Server Not Found / Not Active".

const std = @import("std");
const httpz = @import("httpz");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.srtools);

pub const FILENAME = "freesr-data.json";

/// The gameserver's own endpoint, used to nudge it after a sync and to export
/// the live config. Best-effort: a stopped gameserver is not an error here.
pub const GAMESERVER_HOST = "127.0.0.1";
pub const GAMESERVER_PORT: u16 = 21001;

/// Mirrors RobinSR's SrToolDataRsp.
fn envelope(res: *httpz.Response, status: u32, message: []const u8) !void {
    cors(res);
    res.status = 200;
    try res.json(.{ .message = message, .status = status }, .{});
}

fn cors(res: *httpz.Response) void {
    res.header("Access-Control-Allow-Origin", "*");
}

pub fn onPreflight(_: *httpz.Request, res: *httpz.Response) !void {
    res.status = 204;
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type");
    res.header("Access-Control-Max-Age", "86400");
}

pub fn onSave(req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        // No body at all is still a valid probe.
        log.info("srtools probe (empty body)", .{});
        return envelope(res, 200, "OK");
    };

    var tree = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch |err| {
        log.warn("srtools payload is not valid JSON: {}", .{err});
        return envelope(res, 500, "malformed json");
    };
    defer tree.deinit();

    if (tree.value != .object) return envelope(res, 500, "malformed json");

    // `data` absent or null => liveness probe, same as RobinSR's Option<FreesrData>.
    const data = tree.value.object.get("data") orelse return probeOk(res);
    if (data != .object) return probeOk(res);

    var out = std.ArrayList(u8).init(res.arena);
    std.json.stringify(data, .{ .whitespace = .indent_2 }, out.writer()) catch |err| {
        log.err("could not serialise srtools payload: {}", .{err});
        return envelope(res, 500, "malformed json");
    };

    std.fs.cwd().writeFile(.{ .sub_path = FILENAME, .data = out.items }) catch |err| {
        log.err("could not write {s}: {}", .{ FILENAME, err });
        return envelope(res, 500, "failed to write freesr-data.json");
    };

    log.info("saved {s} from srtools ({d} bytes)", .{ FILENAME, out.items.len });

    // Ask the gameserver to pick the file up so an export right after a sync
    // does not report stale data. It may legitimately be offline.
    if (poke(res.arena, "POST", "/reload", "")) |_| {
        log.info("gameserver reloaded the new config", .{});
    } else |err| {
        log.info("gameserver not reloaded ({}); use /sync in-game", .{err});
    }

    return envelope(res, 200, "OK");
}

fn probeOk(res: *httpz.Response) !void {
    log.info("srtools probe", .{});
    return envelope(res, 200, "OK");
}

/// Downloads the gameserver's live config as freesr-data.json. Falls back to
/// whatever is on disk when the gameserver is not running.
pub fn onExport(_: *httpz.Request, res: *httpz.Response) !void {
    cors(res);

    if (poke(res.arena, "GET", "/sr-tools-export", "")) |upstream| {
        res.status = upstream.status;
        res.header("Content-Type", upstream.content_type);
        res.header("Content-Disposition", "attachment; filename=freesr-data.json");
        res.body = upstream.body;
        return;
    } else |err| {
        log.info("gameserver unavailable for export ({}), serving the file on disk", .{err});
    }

    const file = std.fs.cwd().readFileAlloc(res.arena, FILENAME, std.math.maxInt(usize)) catch {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "No freesr-data.json yet. Start the game server, or sync once from SRTools.";
        return;
    };

    res.status = 200;
    res.content_type = .JSON;
    res.header("Content-Disposition", "attachment; filename=freesr-data.json");
    res.body = file;
}

/// Logs anything unmatched, like RobinSR's `errors::not_found`. Makes an
/// unknown SRTools provider easy to trace to the route it actually wants.
pub fn onUnmatched(req: *httpz.Request, res: *httpz.Response) !void {
    log.warn("unhandled http request: {s} {s}", .{ @tagName(req.method), req.url.raw });
    cors(res);
    res.status = 404;
    res.content_type = .TEXT;
    res.body = "not found";
}

// ------------------------------------------------------------ gameserver link

const Upstream = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

fn poke(allocator: Allocator, method: []const u8, path: []const u8, body: []const u8) !Upstream {
    const stream = try std.net.tcpConnectToHost(allocator, GAMESERVER_HOST, GAMESERVER_PORT);
    defer stream.close();

    const request = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ method, path, GAMESERVER_HOST, GAMESERVER_PORT, body.len });

    try stream.writeAll(request);
    if (body.len > 0) try stream.writeAll(body);

    var raw = std.ArrayList(u8).init(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const read = try stream.read(&buf);
        if (read == 0) break;
        try raw.appendSlice(buf[0..read]);
    }

    return parseResponse(raw.items);
}

fn parseResponse(raw: []const u8) !Upstream {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
    const headers = raw[0..header_end];
    const body = raw[header_end + 4 ..];

    const first_line_end = std.mem.indexOfScalar(u8, headers, '\r') orelse headers.len;
    const status_line = headers[0..first_line_end];
    const after_version = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidResponse;
    var status_it = std.mem.tokenizeScalar(u8, status_line[after_version + 1 ..], ' ');
    const status_text = status_it.next() orelse return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, status_text, 10) catch return error.InvalidResponse;

    var content_type: []const u8 = "text/plain";
    var line_it = std.mem.tokenizeSequence(u8, headers, "\r\n");
    while (line_it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            content_type = std.mem.trim(u8, line["content-type:".len..], " \t");
        }
    }

    return .{ .status = status, .content_type = content_type, .body = body };
}

test "parses an upstream response" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}";
    const parsed = try parseResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expectEqualStrings("application/json", parsed.content_type);
    try std.testing.expectEqualStrings("{}", parsed.body);
}

test "parses an error status without a content type" {
    const raw = "HTTP/1.1 400 Bad Request\r\n\r\nnope";
    const parsed = try parseResponse(raw);
    try std.testing.expectEqual(@as(u16, 400), parsed.status);
    try std.testing.expectEqualStrings("text/plain", parsed.content_type);
    try std.testing.expectEqualStrings("nope", parsed.body);
}
