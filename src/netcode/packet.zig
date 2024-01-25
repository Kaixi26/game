const std = @import("std");
const Player = @import("../Player.zig");
const Allocator = std.mem.Allocator;
const nc = @import("netcode.zig");
const Serializer = nc.Serializer;
const Deserializer = nc.Deserializer;
const rl = @import("raylib");

pub const Packet = union(Kind) {
    const Self = @This();

    pub const max_transmission_unit = 1472;

    pub const PacketHeader = packed struct {
        kind: Kind,
        packet_len: u16,
    };

    pub const Kind = enum(u8) {
        ping = 0x00,
        pong = 0x01,
        join = 0x02,
        join_ok = 0x03,
        move = 0x04,
        update_players = 0x05,
    };

    ping: Ping,
    pong: Pong,
    join: Join,
    join_ok: JoinOk,
    move: Move,
    update_players: UpdatePlayers,

    pub const Ping = struct {};

    pub const Pong = struct {};

    pub const Join = struct {};

    pub const JoinOk = struct {
        id: u64,
    };

    pub const Move = struct {
        player: Player,
    };

    pub const UpdatePlayers = struct {
        players: []Player,

        pub const max_player_amount = 25;
    };

    pub fn serialize(self: Self, ser: *Serializer) Serializer.Error!void {
        const kind: Kind = @as(Kind, self);

        var header = PacketHeader{
            .kind = kind,
            .packet_len = undefined,
        };
        // Header
        try ser.serialize(header.kind);
        var cursor_packet_len = ser.cursor;
        try ser.serialize(header.packet_len);

        // Payload
        switch (self) {
            .join_ok => |v| {
                try ser.serialize(v.id);
            },
            .move => |packet| {
                try ser.serialize(packet.player);
            },
            .update_players => |packet| {
                std.debug.assert(packet.players.len <= UpdatePlayers.max_player_amount);
                try ser.serialize(@as(u8, @intCast(packet.players.len)));
                for (packet.players) |p| {
                    try ser.serialize(p);
                }
            },
            else => {},
        }

        // Set up packet length
        {
            header.packet_len = @intCast(ser.cursor);
            const cursor = ser.jump(cursor_packet_len);
            try ser.serialize(header.packet_len);
            _ = ser.jump(cursor);
        }
    }

    pub fn deserialize(des: *Deserializer) Deserializer.Error!Self {
        var header: PacketHeader = undefined;
        header.kind = try des.deserialize(Kind);
        header.packet_len = try des.deserialize(u16);

        switch (header.kind) {
            .ping => {
                return .{ .ping = .{} };
            },
            .pong => {
                return .{ .pong = .{} };
            },
            .join => {
                return .{ .join = .{} };
            },
            .join_ok => {
                return .{
                    .join_ok = .{ .id = try des.deserialize(u64) },
                };
            },
            .move => {
                return .{
                    .move = .{ .player = try des.deserialize(Player) },
                };
            },
            .update_players => {
                const len = try des.deserialize(u8);
                var i: usize = 0;
                var arr = std.ArrayListUnmanaged(Player){};
                while (i < len) : (i += 1) {
                    try arr.append(des.allocator, try des.deserialize(Player));
                }
                return .{
                    .update_players = .{ .players = arr.items },
                };
            },
        }
    }
};

fn expectPacketEqualAfterEncode(packet: Packet) !void {
    var ser_buffer: [Packet.max_transmission_unit]u8 = undefined;
    var ser_fba = std.heap.FixedBufferAllocator.init(&ser_buffer);

    var des_buffer: [2048]u8 = undefined;
    var des_fba = std.heap.FixedBufferAllocator.init(&des_buffer);

    var ser = Serializer.init(ser_fba.allocator());
    try ser.serialize(packet);
    var de = Deserializer.init(des_fba.allocator(), ser.buf.items);
    var de_packet = try de.deserialize(Packet);

    _ = try des_fba.allocator().create(Packet);

    try std.testing.expectEqualDeep(packet, de_packet);
}

test "Encode and decode ping" {
    try expectPacketEqualAfterEncode(Packet{ .ping = .{} });
}

test "Encode and decode pong" {
    try expectPacketEqualAfterEncode(Packet{ .pong = .{} });
}

test "Encode and decode join" {
    try expectPacketEqualAfterEncode(Packet{ .join = .{} });
}

test "Encode and decode join_ok" {
    try expectPacketEqualAfterEncode(Packet{ .join_ok = .{ .id = 69 } });
}

test "Encode and decode move_players" {
    var players: [Packet.UpdatePlayers.max_player_amount]Player = undefined;

    for (0..Packet.UpdatePlayers.max_player_amount) |i| {
        players[i] = .{
            .id = i,
            .pos = rl.Vector3.init(69, 420, 1337),
            .vel = rl.Vector3.init(69, 420, 1337),
        };
    }
    try expectPacketEqualAfterEncode(Packet{ .update_players = .{ .players = players[0..Packet.UpdatePlayers.max_player_amount] } });
}
