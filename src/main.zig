const std = @import("std");
const heap = std.heap;
const io = std.io;
const log = std.log;
const os = std.os;

const game = @import("game.zig");
const server = @import("server.zig");

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
