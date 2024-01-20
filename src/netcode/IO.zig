const std = @import("std");
const Protocol = @import("../Protocol.zig");
const Packet = Protocol.Packet;
const Self = @This();
const Allocator = std.mem.Allocator;
const os = std.os;
const Serializer = Protocol.Serializer;
const Deserializer = Protocol.Deserializer;
const log = std.log.scoped(.netcode_io);

pub const ConnectionId = u64;
pub const Connection = struct {
    id: ConnectionId,
    sock: os.pollfd,
};

const TransmissionProtocol = enum {
    tcp,
};

const max_packets = 100;
const PacketSlot = u16;

allocator: Allocator,
packet_buffers: [max_packets]([2048]u8),
// TODO: this can be static
free_packet_buffers_slots: std.ArrayList(PacketSlot),
connections: std.MultiArrayList(Connection),
next_connection_id: ConnectionId = 0,

pub fn init(allocator: Allocator) Allocator.Error!Self {
    var free_packet_buffers_slots = std.ArrayList(PacketSlot).init(allocator);
    for (0..max_packets) |i| {
        try free_packet_buffers_slots.append(@intCast(i));
    }
    return .{
        .allocator = allocator,
        .packet_buffers = undefined,
        .free_packet_buffers_slots = free_packet_buffers_slots,
        .connections = std.MultiArrayList(Connection){},
    };
}

fn allocPacketSlot(self: *Self) ReceivedPacket {
    const slot = self.free_packet_buffers_slots.pop();
    return .{
        .parent = self,
        .slot = slot,
        .buf = &self.packet_buffers[slot],
        .packet = undefined,
        .connection_id = undefined,
    };
}

fn freePacketSlot(self: *Self, slot: PacketSlot) void {
    self.free_packet_buffers_slots.append(slot) catch {
        // Probably a double-free
        unreachable;
    };
}

pub fn addConnection(self: *Self, sock: os.socket_t) Allocator.Error!void {
    defer self.next_connection_id += 1;
    try self.connections.append(self.allocator, .{
        .id = self.next_connection_id,
        .sock = .{ .fd = sock, .events = os.POLL.IN, .revents = 0 },
    });
}

//enum SendTarget = Connnnnnnnnnnnnnnnnnnnnnnnnnn
// Target??
// Blocks if tcp
pub fn broadcast(self: *Self, packet: Packet) !void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ser = Serializer.init(fba.allocator());
    ser.serialize(packet) catch |err| {
        std.debug.panic("{}", .{err});
    };
    const conns = self.connections.items(.sock);

    for (conns) |conn| {
        _ = try os.write(conn.fd, ser.buf.items);
    }

    log.debug("Packet broadcasted {} to {} connections", .{ packet, conns.len });
}

pub fn send(self: *Self, packet: Packet, target: ConnectionId) !void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ser = Serializer.init(fba.allocator());
    ser.serialize(packet) catch |err| {
        std.debug.panic("{}", .{err});
    };
    const socks = self.connections.items(.sock);
    const ids = self.connections.items(.id);

    for (ids, 0..) |id, i| {
        if (id == target) {
            _ = try os.write(socks[i].fd, ser.buf.items);
            log.debug("Packet sent {} to connection {}", .{ packet, target });
            return;
        }
    }

    log.debug("{} {any} {any}", .{ packet, target, ids });

    unreachable;
}

pub const ReceivedPacket = struct {
    parent: *Self,
    slot: PacketSlot,
    buf: []u8,
    packet: *Packet,
    connection_id: ConnectionId,

    pub fn deinit(self: ReceivedPacket) void {
        self.parent.freePacketSlot(self.slot);
    }
};

// Blocks until a packet is received
pub fn receive(self: *Self) !ReceivedPacket {
    var received_packet = self.allocPacketSlot();
    var fba = std.heap.FixedBufferAllocator.init(received_packet.buf);
    received_packet.packet = fba.allocator().create(Packet) catch unreachable;

    received_packet.packet.* = blk: {
        while (true) {
            var conns: []os.pollfd = self.connections.items(.sock);
            const ready_connections = try os.poll(conns, 1000);
            log.debug("ready_connections {}/{}", .{ ready_connections, conns.len });

            if (ready_connections > 0) {
                var n = self.connections.items(.sock).len;
                while (n > 0) : (n -= 1) {
                    var i = n - 1;
                    var conn = conns[i];
                    if ((conn.revents & os.POLL.HUP) != 0) {
                        unreachable;
                        // Remove connection
                        //os.close(conn.fd);
                        //server_context.remove_client(i);
                    } else if ((conn.revents & os.POLL.IN) != 0) {
                        var buf: [1024]u8 = undefined;
                        var rd = try os.read(conn.fd, &buf);
                        var des = Deserializer.init(self.allocator, (&buf)[0..rd]);
                        const packet = try des.deserialize(Packet);
                        std.debug.assert(des.buf.len == 0); // TODO: buffering
                        received_packet.connection_id = i;
                        break :blk packet;
                    } else if (conn.revents != 0) {
                        log.warn("SERVER: unhandled pool revent 0x{x}", .{conn.revents});
                    }
                }
            }
        }
    };

    log.debug("Packet received {}", .{received_packet.packet.*});

    return received_packet;
}
