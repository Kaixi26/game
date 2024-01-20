const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("netcode.zig");
const Packet = @import("../Protocol.zig").Packet;

const Self = @This();

const SendPacketKindEnum = enum {
    broadcast,
    target,
};

const SendPacketKind = union(SendPacketKindEnum) {
    broadcast: void,
    target: nc.IO.ConnectionId,
};

const SendPacket = struct {
    packet: Packet,
    kind: SendPacketKind,
};

allocator: Allocator,
send_packets: std.ArrayListUnmanaged(SendPacket) = .{},
send_packets_lock: std.Thread.Mutex = .{},
send_packets_cond: std.Thread.Condition = .{},

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

// TODO: encode these or it will fuck shit up because of changed pointers
pub fn safeAppendSendPacket(self: *Self, packet: SendPacket) !void {
    self.send_packets_lock.lock();
    defer self.send_packets_lock.unlock();

    try self.send_packets.append(self.allocator, packet);
}

pub fn getSendPacketOrWait(self: *Self) !SendPacket {
    self.send_packets_lock.lock();
    defer self.send_packets_lock.unlock();

    while (self.send_packets.items.len == 0) {
        self.send_packets_cond.wait(&self.send_packets_lock);
    }

    return self.send_packets.pop();
}

pub fn signalPacketsAdded(self: *Self) void {
    self.send_packets_cond.signal();
}

pub fn handle(self: *Self, nc_io: *nc.IO) !void {
    while (true) {
        const send_packet = try self.getSendPacketOrWait();
        switch (send_packet.kind) {
            .broadcast => {
                _ = try nc_io.broadcast(send_packet.packet);
            },
            .target => |target| {
                _ = try nc_io.send(send_packet.packet, target);
            },
        }
    }
}
