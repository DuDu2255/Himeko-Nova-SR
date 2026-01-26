const std = @import("std");
const network = @import("network.zig");
const ConfigManager = @import("../src/manager/config_mgr.zig");
const scene_service = @import("services/scene.zig");
const handlers = @import("handlers.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Developer build defaults: keep logs verbose and never auto-disable.
    scene_service.scene_debug_enabled = true;
    handlers.trace_packets_enabled = true;

    try ConfigManager.initGameGlobals(allocator);
    defer ConfigManager.deinitGameGlobals();
    try network.listen();
    std.log.info("Server listening for connections.", .{});
}
