const std = @import("std");
const Player = @import("Player.zig");
const Mutex = std.Thread.Mutex;

const Self = @This();

const Players = std.ArrayListUnmanaged(Player);

allocator: std.mem.Allocator,
players_mutex: Mutex = Mutex{},
players: Players = Players{},

pub fn lock(self: *Self) void {
    return self.players_mutex.lock();
}

pub fn unlock(self: *Self) void {
    return self.players_mutex.unlock();
}

pub fn append(self: *Self, player: Player) std.mem.Allocator.Error!void {
    return try self.players.append(self.allocator, player);
}

pub fn find(self: *Self, id: Player.Id) ?*Player {
    for (self.players.items) |*player| {
        if (player.id == id) {
            return player;
        }
    }
    return null;
}
