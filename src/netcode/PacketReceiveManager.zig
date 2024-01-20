const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("netcode.zig");

const Self = @This();

allocator: Allocator,
received_packets: std.ArrayListUnmanaged(nc.IO.ReceivedPacket) = .{},
mutex: std.Thread.Mutex = .{},

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn handle(self: *Self, nc_io: *nc.IO) !void {
    while (true) {
        const received_packet = try nc_io.receive();

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.received_packets.append(self.allocator, received_packet);
    }
}
