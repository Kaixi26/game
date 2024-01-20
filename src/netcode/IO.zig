const std = @import("std");
const nc = @import("netcode.zig");
const Packet = nc.Packet;
const Allocator = std.mem.Allocator;
const os = std.os;
const Serializer = nc.Serializer;
const Deserializer = nc.Deserializer;
const log = nc.log;

const Self = @This();

pub const ConnectionId = u64;
pub const Connection = struct {
    id: ConnectionId,
    sock: os.socket_t,

    buffer: [2048]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn init(id: ConnectionId, sock: os.socket_t) Connection {
        return .{
            .id = id,
            .sock = sock,
        };
    }

    pub fn filledBuffer(self: *Connection) []u8 {
        return self.buffer[self.start..self.end];
    }

    pub fn freeBuffer(self: *Connection) []u8 {
        return self.buffer[self.end..];
    }

    pub fn skip(self: *Connection, n: usize) void {
        self.start += n;
        std.debug.assert(self.start <= self.end);
    }

    fn read(self: *Connection) os.ReadError!usize {
        { // TODO: don't do this every time
            const n = self.end - self.start;
            std.mem.copyForwards(u8, self.buffer[0..n], self.filledBuffer());
            self.start = 0;
            self.end = n;
        }

        const rd = try os.read(self.sock, self.freeBuffer());
        self.end += rd;
        std.debug.assert(self.end < self.buffer.len);
        return rd;
    }
};

pub const ConnectionPoll = struct {
    conn: *Connection,
    poll: os.pollfd,
};

const TransmissionProtocol = enum {
    tcp,
};

const max_packets = 1000;
const PacketSlot = u16;

allocator: Allocator,
packet_buffers: [max_packets]([2048]u8),
// TODO: this can be static
free_packet_buffers_slots: std.ArrayList(PacketSlot),

connections: std.SegmentedList(Connection, 0),
// TODO: This invalidates for polling when resized
//       Somehow base off indices and use negative fd for disconnected ones?
polls: std.MultiArrayList(ConnectionPoll),

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
        .connections = .{},
        .polls = .{},
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

// Assumes a single thread calls this
// TODO: need to rethink connections, they can't be removed, maybe allow nullability
pub fn addConnection(self: *Self, sock: os.socket_t) Allocator.Error!void {
    defer self.next_connection_id += 1;
    try self.connections.append(self.allocator, Connection.init(self.next_connection_id, sock));
    const conn: *Connection = self.connections.at(self.connections.len - 1);
    try self.polls.append(self.allocator, .{ .poll = .{ .fd = sock, .events = os.POLL.IN, .revents = 0 }, .conn = conn });
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

    for (0..self.connections.len) |i| {
        const conn: *Connection = self.connections.at(i);
        _ = try os.write(conn.sock, ser.buf.items);
    }

    //log.debug("Packet broadcasted {} to {} connections", .{ packet, self.connections.len });
}

pub fn send(self: *Self, packet: Packet, target: ConnectionId) !void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ser = Serializer.init(fba.allocator());
    ser.serialize(packet) catch |err| {
        std.debug.panic("{}", .{err});
    };

    for (0..self.connections.len) |i| {
        const conn: *Connection = self.connections.at(i);
        if (conn.id == target) {
            _ = try os.write(conn.sock, ser.buf.items);
            log.debug("Packet sent {} to connection {}", .{ packet, target });
            return;
        }
    }

    log.debug("{} {}", .{ packet, target });

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

// Not thread-safe
// Blocks until a packet is received
pub fn receive(self: *Self) !ReceivedPacket {
    var received_packet = self.allocPacketSlot();
    var fba = std.heap.FixedBufferAllocator.init(received_packet.buf);
    received_packet.packet = fba.allocator().create(Packet) catch unreachable;

    received_packet.packet.* = blk: {
        while (true) {
            for (0..self.connections.len) |i| {
                const conn: *Connection = self.connections.at(i);
                var des = Deserializer.init(self.allocator, conn.filledBuffer());
                var packet = des.deserialize(Packet) catch |err| {
                    switch (err) {
                        // TODO: Don't check entire buffer before continuing (use packet length?)
                        error.OutOfBytes => continue,
                        error.OutOfMemory => unreachable,
                    }
                };
                conn.skip(des.start);

                received_packet.connection_id = i;
                break :blk packet;
            }

            const ready_connections = try os.poll(self.polls.items(.poll), 1000);
            log.debug("ready_connections {}/{}", .{ ready_connections, self.polls.len });

            if (ready_connections > 0) {
                var n = self.polls.len;
                while (n > 0) : (n -= 1) {
                    var i = n - 1;
                    var conn: *Connection = self.polls.items(.conn)[i];
                    var poll: os.pollfd = self.polls.items(.poll)[i];
                    if ((poll.revents & os.POLL.HUP) != 0) {
                        unreachable;
                        // Remove connection
                        //os.close(conn.fd);
                        //server_context.remove_client(i);
                    } else if ((poll.revents & os.POLL.IN) != 0) {
                        _ = try conn.read();
                        //var buf: [1024]u8 = undefined;
                        //var rd = try os.read(conn.fd, &buf);
                        //var des = Deserializer.init(self.allocator, (&buf)[0..rd]);
                        //const packet = try des.deserialize(Packet);
                        //std.debug.assert(des.buf.len == 0); // TODO: buffering
                        //received_packet.connection_id = i;
                        //break :blk packet;
                    } else if (poll.revents != 0) {
                        log.warn("SERVER: unhandled pool revent 0x{x}", .{poll.revents});
                        unreachable;
                    }
                }
            }
        }
    };

    log.debug("Packet received {}", .{received_packet.packet.*});

    return received_packet;
}
