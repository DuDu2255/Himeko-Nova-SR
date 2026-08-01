const std = @import("std");
const builtin = @import("builtin");
const network = @import("network.zig");
const web = @import("web.zig");
const ConfigManager = @import("../src/manager/config_mgr.zig");

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try ConfigManager.initGameGlobals(allocator);
    defer ConfigManager.deinitGameGlobals();

    // SRTools sync/export runs alongside the game loop; it is optional, so a
    // failure to spawn it must not take the server down.
    if (web.start(allocator)) |thread| {
        thread.detach();
    } else |err| {
        std.log.warn("sr-tools server unavailable: {}", .{err});
    }

    try network.listen();
}
