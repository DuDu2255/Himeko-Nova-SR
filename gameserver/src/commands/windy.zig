const std = @import("std");
const protocol = @import("protocol");
const commandhandler = @import("../command.zig");
const Session = @import("../Session.zig");
const Lua = @import("../lua.zig");

const Allocator = std.mem.Allocator;
const CmdID = protocol.CmdID;

/// `/windy <file>` pushes `lua/<file>` to the client, the same way
/// March7thHoney's CommandWindy does (a ClientDownloadDataScNotify).
pub fn handle(session: *Session, args: []const u8, allocator: Allocator) !void {
    const path = std.mem.trim(u8, args, " \t\r\n");
    if (path.len == 0) {
        return commandhandler.sendMessage(session, "Usage: /windy <file.lua>", allocator);
    }

    const script = Lua.read(allocator, path) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Read error: {s}/{s} ({s})", .{ Lua.ROOT, path, @errorName(err) });
        defer allocator.free(msg);
        return commandhandler.sendMessage(session, msg, allocator);
    };
    defer allocator.free(script);

    try send(session, script, allocator);

    const msg = try std.fmt.allocPrint(allocator, "Loaded: {s}/{s} ({d} bytes)", .{ Lua.ROOT, path, script.len });
    defer allocator.free(msg);
    try commandhandler.sendMessage(session, msg, allocator);
}

/// Wraps raw lua source in a ClientDownloadDataScNotify and sends it.
pub fn send(session: *Session, script: []const u8, allocator: Allocator) !void {
    const owned = try allocator.dupe(u8, script);

    const notify = protocol.ClientDownloadDataScNotify{
        .download_data = .{
            .version = Lua.nextVersion(),
            .time = @intCast(std.time.milliTimestamp()),
            .data = protocol.ManagedString.move(owned, allocator),
        },
    };

    try session.send(CmdID.CmdClientDownloadDataScNotify, notify);
}
