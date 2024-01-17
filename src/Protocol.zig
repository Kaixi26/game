const std = @import("std");
const Player = @import("Player.zig").Player;

pub const Header = packed struct {
    kind: Packet.Kind,
    message_length: u16,
};

pub const Packet = struct {
    const Self = @This();
    pub const max_length = 1024;
    const PacketBufType = [max_length - @sizeOf(Header)]u8;

    header: Header,
    buf: PacketBufType = undefined,

    const Kind = enum(u8) {
        ping = 0x00,
        pong = 0x01,
        join = 0x02,
        join_ok = 0x03,
        move = 0x04,
        update_players = 0x05,
    };

    const PacketData = union(Kind) {
        ping: void,
        pong: void,
        join: void,
        join_ok: Player,
        move: Player,
        update_players: []align(1) const Player,
    };

    pub fn encode(self: Self, buf: []u8) void {
        buf[0..(@divExact(@bitSizeOf(Header), 8))].* = @bitCast(self.header);
        buf[(@divExact(@bitSizeOf(Header), 8))..][0..@sizeOf(PacketBufType)].* = self.buf;
    }

    pub fn decode(buf: []u8) !Packet {
        const header: Header = @bitCast(buf[0 .. @sizeOf(Header) - 1].*);
        return .{
            .header = header,
            .buf = buf[@sizeOf(Header) - 1 ..][0..@sizeOf(PacketBufType)].*,
        };
    }

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("CPacket{{{}}}", .{self.header.kind});
    }

    pub fn ping() Packet {
        return .{ .header = .{ .kind = .ping, .message_length = 0 } };
    }

    pub fn pong() Packet {
        return .{ .header = .{ .kind = .pong, .message_length = 0 } };
    }

    pub fn join() Packet {
        return .{ .header = .{ .kind = .join, .message_length = 0 } };
    }

    pub fn joinOk(player: Player) Packet {
        var buf: PacketBufType = undefined;
        buf[0..@sizeOf(Player)].* = @bitCast(player);
        return .{
            .header = .{ .kind = .join_ok, .message_length = @sizeOf(Player) },
            .buf = buf,
        };
    }

    pub fn move(player: Player) Packet {
        var buf: PacketBufType = undefined;
        buf[0..@sizeOf(Player)].* = @bitCast(player);
        return .{
            .header = .{ .kind = .move, .message_length = @sizeOf(Player) },
            .buf = buf,
        };
    }

    pub fn update_players(players: []Player) Packet {
        const message_length: usize = @sizeOf(u64) + players.len * @sizeOf(Player);
        std.debug.assert(message_length < @sizeOf(PacketBufType));

        var buf: PacketBufType = undefined;
        buf[0] = @as(u8, @intCast(players.len));
        for (players, 0..) |player, i| {
            const begin = @sizeOf(u64) + @sizeOf(Player) * i;
            buf[begin..][0..@sizeOf(Player)].* = @bitCast(player);
        }
        return .{
            .header = .{ .kind = .update_players, .message_length = @sizeOf(Player) },
            .buf = buf,
        };
    }

    pub fn extractData(self: Self) PacketData {
        switch (self.header.kind) {
            .ping => {
                return .{ .ping = {} };
            },
            .pong => {
                return .{ .pong = {} };
            },
            .join => {
                return .{ .join = {} };
            },
            .join_ok => {
                return .{ .join_ok = @bitCast(self.buf[0..@sizeOf(Player)].*) };
            },
            .move => {
                return .{ .move = @bitCast(self.buf[0..@sizeOf(Player)].*) };
            },
            .update_players => {
                var players: []align(1) const Player = undefined;
                players.ptr = @alignCast(@ptrCast(self.buf[@sizeOf(u64)..]));
                players.len = self.buf[0];
                for (0..players.len) |i| {
                    const begin = @sizeOf(u64) + @sizeOf(Player) * i;
                    var player: Player = @bitCast(self.buf[begin..][0..@sizeOf(Player)].*);
                    std.log.debug("SERVER: HUH? {}", .{player});
                }
                var player2: Player = @as(Player, @bitCast(self.buf[@sizeOf(u64) + @sizeOf(Player) ..][0..@sizeOf(Player)].*));
                _ = player2;
                std.log.debug("SERVER: HUH? {}", .{std.fmt.fmtSliceHexLower(self.buf[@sizeOf(u64)..])});
                //std.log.debug("SERVER: HUH? {}", .{player2});
                return .{ .update_players = players };
            },
        }
    }
};
