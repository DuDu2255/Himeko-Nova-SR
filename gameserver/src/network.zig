const kcp_server = @import("net/kcp_server.zig");

/// Entry point for the game transport. Star Rail speaks KCP over UDP; the
/// former TCP listener is gone along with `GateServer.use_tcp`.
pub fn listen() !void {
    try kcp_server.listen();
}
