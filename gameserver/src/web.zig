//! Local HTTP endpoint the dispatch server talks to.
//!
//! SRTools itself uploads to dispatch on port 21000 (see
//! `dispatch/src/srtools.zig`), which writes `freesr-data.json` and then calls
//! `/reload` here so the live config matches the file.

const std = @import("std");
const httpz = @import("httpz");
const ConfigManager = @import("manager/config_mgr.zig");
const FreesrConfig = @import("data/freesr_config.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.web);

pub const PORT: u16 = 21001;

pub fn start(allocator: Allocator) !std.Thread {
    return std.Thread.spawn(.{}, run, .{allocator});
}

fn run(allocator: Allocator) void {
    var srv = httpz.Server(void).init(allocator, .{ .port = PORT }, {}) catch |err| {
        log.err("could not start the local endpoint on port {d}: {}", .{ PORT, err });
        return;
    };

    var router = srv.router(.{}) catch |err| {
        log.err("could not build the router: {}", .{err});
        return;
    };
    router.post("/reload", onReload, .{});
    router.get("/sr-tools-export", onExport, .{});

    log.info("local endpoint is listening at localhost:{d}", .{PORT});
    srv.listen() catch |err| {
        log.err("local endpoint stopped: {}", .{err});
    };
}

/// Re-reads the game config from disk (freesr-data.json, else config.json).
fn onReload(_: *httpz.Request, res: *httpz.Response) !void {
    ConfigManager.config_lock.lock();
    defer ConfigManager.config_lock.unlock();

    ConfigManager.UpdateGameConfig() catch |err| {
        log.err("reload failed: {}", .{err});
        res.status = 500;
        res.body = "reload failed";
        return;
    };

    log.info("game config reloaded", .{});
    res.status = 200;
    res.body = "OK";
}

/// Exports the live config in freesr shape, so a config.json-only setup can
/// still be opened in SRTools.
fn onExport(_: *httpz.Request, res: *httpz.Response) !void {
    ConfigManager.config_lock.lock();
    defer ConfigManager.config_lock.unlock();

    res.status = 200;
    res.content_type = .JSON;
    res.body = try FreesrConfig.stringify(&ConfigManager.global_game_config_cache.game_config, res.arena);
}
