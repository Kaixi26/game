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

pub const GeneralPurposeAllocator = heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
    .retain_metadata = true,
    //.verbose_log = true,
});

pub fn main() !void {
    var gpa = GeneralPurposeAllocator{};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var address = try std.net.Address.parseIp("0.0.0.0", 1337);

    var s = try std.Thread.spawn(.{}, server.start, .{ allocator, address });
    defer s.join();

    std.time.sleep(1E6);
    game.start(allocator) catch |err| {
        log.err("GAME: Failed to start game {}.", .{err});
    };
}

test "main" {
    std.testing.refAllDeclsRecursive(@This());

    var x: i32 = 1;
    var y: c_int = 1;
    x = y;
    y = x;
}
