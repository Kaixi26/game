const std = @import("std");
const Player = @import("Player.zig").Player;
const Allocator = std.mem.Allocator;

pub const PacketHeader = packed struct {
    const Self = @This();

    kind: PacketKind,
    packet_len: u16,
};

pub const PacketKind = enum(u8) {
    ping = 0x00,
    pong = 0x01,
    join = 0x02,
    join_ok = 0x03,
    move = 0x04,
    update_players = 0x05,
};

pub const Packet = union(PacketKind) {
    const Self = @This();

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
    };

    pub fn serialize(self: Self, ser: *Serializer) Serializer.Error!void {
        const kind: PacketKind = @as(PacketKind, self);

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
                std.debug.assert(packet.players.len < std.math.maxInt(u8));
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
        header.kind = try des.deserialize(PacketKind);
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

pub const Serializer = struct {
    const Self = @This();
    pub const Error = Allocator.Error;

    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8),
    cursor: usize,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .buf = std.ArrayListUnmanaged(u8){},
            .cursor = 0,
        };
    }

    pub fn jump(self: *Self, new_cursor: usize) usize {
        const saved_cursor = self.cursor;
        self.cursor = new_cursor;

        return saved_cursor;
    }

    pub fn serialize(self: *Self, value: anytype) Error!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Int => |_| {
                var buf: [@sizeOf(T)]u8 = @bitCast(value);
                try self.buf.ensureTotalCapacity(self.allocator, self.cursor + @sizeOf(T));
                self.buf.allocatedSlice()[self.cursor..][0..@sizeOf(T)].* = buf;
                self.cursor += @sizeOf(T);
                self.buf.items.len = @max(self.cursor, self.buf.items.len);
            },
            .Float => |_| {
                var buf: [@sizeOf(T)]u8 = @bitCast(value);
                try self.buf.ensureTotalCapacity(self.allocator, self.cursor + @sizeOf(T));
                self.buf.allocatedSlice()[self.cursor..][0..@sizeOf(T)].* = buf;
                self.cursor += @sizeOf(T);
                self.buf.items.len = @max(self.cursor, self.buf.items.len);
            },
            .Enum => |_| {
                try self.serialize(@intFromEnum(value));
            },
            .Union => |_| {
                return try value.serialize(self);
            },
            .Struct => |_| {
                try value.serialize(self);
            },
            else => {
                @compileError(std.fmt.comptimePrint("Cannot serialize value of type `{}`", .{T}));
            },
        }
    }
};

pub const Deserializer = struct {
    const Self = @This();
    pub const Error = error{
        OutOfBytes,
    } || Allocator.Error;

    allocator: Allocator,
    buf: []u8,
    start: usize = 0,

    fn ensureBufferLen(self: *Self, n: usize) Error!void {
        if (self.buf[self.start..].len < n) {
            return Error.OutOfBytes;
        }
    }

    fn skipBufferBytes(self: *Self, n: usize) void {
        self.start += n;
    }

    fn remaining(self: *Self) []u8 {
        return self.buf[self.start..];
    }

    pub fn init(allocator: Allocator, buf: []u8) Self {
        return .{
            .allocator = allocator,
            .buf = buf,
        };
    }

    pub fn deserialize(self: *Self, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .Int => |_| {
                try self.ensureBufferLen(@sizeOf(T));
                defer self.skipBufferBytes(@sizeOf(T));
                return @bitCast(self.remaining()[0..@sizeOf(T)].*);
            },
            .Float => |_| {
                try self.ensureBufferLen(@sizeOf(T));
                defer self.skipBufferBytes(@sizeOf(T));
                return @bitCast(self.remaining()[0..@sizeOf(T)].*);
            },
            .Enum => |en| {
                return @enumFromInt(try self.deserialize(en.tag_type));
            },
            .Union => |_| {
                return try T.deserialize(self);
            },
            .Struct => |_| {
                return try T.deserialize(self);
            },
            else => {
                @compileError(std.fmt.comptimePrint("Cannot deserialize value of type `{}`", .{T}));
            },
        }
    }
};

fn assertPacketEqualAfterEncode(packet: Packet) !void {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var allocator = fba.allocator();

    var ser = Serializer.init(allocator);
    try ser.serialize(packet);
    var de = Deserializer.init(allocator, ser.buf.items);
    var de_packet = try de.deserialize(Packet);

    try std.testing.expectEqualDeep(packet, de_packet);
}

test "Encode and decode ping" {
    try assertPacketEqualAfterEncode(Packet{ .ping = .{} });
}

test "Encode and decode pong" {
    try assertPacketEqualAfterEncode(Packet{ .pong = .{} });
}

test "Encode and decode join" {
    try assertPacketEqualAfterEncode(Packet{ .join = .{} });
}

test "Encode and decode join_ok" {
    try assertPacketEqualAfterEncode(Packet{ .join_ok = .{ .id = 69 } });
}

test "Encode and decode move_players" {
    var players = [_]Player{
        .{ .id = 1, .x = 1.2, .y = 2.5 },
        .{ .id = 2, .x = 2.2, .y = 2.5 },
        .{ .id = 3, .x = 3.2, .y = 2.5 },
    };
    try assertPacketEqualAfterEncode(Packet{ .update_players = .{ .players = &players } });
}
