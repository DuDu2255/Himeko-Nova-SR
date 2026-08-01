//! Lua scripts served from the `lua/` directory instead of a compile-time
//! Base64 blob, so they can be edited without rebuilding the server.
//!
//! Delivery is the same mechanism March7thHoney uses (its confusingly named
//! `HandshakePacket`): a `ClientDownloadData` payload, either riding along on
//! the heartbeat response or pushed on demand by `/windy`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.lua);

pub const ROOT = "lua";
pub const WATERMARK = "watermark.lua";

/// Used when `lua/watermark.lua` is missing so a fresh checkout still boots.
const DEFAULT_WATERMARK =
    \\local function setTextComponent(path, newText)
    \\    local obj = CS.UnityEngine.GameObject.Find(path)
    \\    if obj then
    \\        local textComponent = obj:GetComponentInChildren(typeof(CS.RPG.Client.LocalizedText))
    \\        if textComponent then
    \\            textComponent.text = newText
    \\        end
    \\    end
    \\end
    \\
    \\setTextComponent("UIRoot/AboveDialog/BetaHintDialog(Clone)", "<color=#E81E39>Himeko•NovaSR is a free and open source software.</color>")
;

var watermark: []const u8 = DEFAULT_WATERMARK;
var watermark_owned = false;

/// Monotonic version handed to the client so it treats each push as new.
var version_counter: u32 = 50;

pub fn init(allocator: Allocator) !void {
    watermark = read(allocator, WATERMARK) catch |err| {
        log.warn("could not read {s}/{s} ({}), using built-in watermark", .{ ROOT, WATERMARK, err });
        return;
    };
    watermark_owned = true;
    log.info("loaded {s}/{s} ({d} bytes)", .{ ROOT, WATERMARK, watermark.len });
}

pub fn deinit(allocator: Allocator) void {
    if (watermark_owned) allocator.free(watermark);
    watermark = DEFAULT_WATERMARK;
    watermark_owned = false;
}

pub fn watermarkScript() []const u8 {
    return watermark;
}

pub fn nextVersion() u32 {
    version_counter +%= 1;
    return version_counter;
}

/// Reads `lua/<relative_path>`.
pub fn read(allocator: Allocator, relative_path: []const u8) ![]u8 {
    var dir = try std.fs.cwd().openDir(ROOT, .{});
    defer dir.close();

    return try dir.readFileAlloc(allocator, relative_path, std.math.maxInt(usize));
}

test "version counter always advances" {
    const a = nextVersion();
    const b = nextVersion();
    try std.testing.expect(b != a);
}
