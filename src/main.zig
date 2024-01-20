const std = @import("std");
const heap = std.heap;
const io = std.io;
const log = std.log;
const os = std.os;

const game = @import("game.zig");
const server = @import("server.zig");

pub const std_options = struct {
    pub const log_scope_levels = &@import("log.zig").scope_levels;
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var address = try std.net.Address.parseIp("0.0.0.0", 1337);

    var s = try std.Thread.spawn(.{}, server.start, .{ allocator, address });
    defer s.join();

    std.time.sleep(1E6);
    game.start(allocator, address) catch |err| {
        log.err("GAME: Failed to start game {}.", .{err});
    };
}

test "main" {
    const nc = @import("netcode/netcode.zig");
    std.testing.refAllDecls(@import("Protocol.zig"));
    std.testing.refAllDecls(nc.IO);

    var buf: [10240]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var nc_io = try nc.IO.init(fba.allocator());
    try nc_io.addConnection(69);
}
