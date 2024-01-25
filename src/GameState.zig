const std = @import("std");
const Player = @import("Player.zig");
const Mutex = std.Thread.Mutex;
const Render = @import("Render.zig");
const rl = @import("raylib");

const Self = @This();

allocator: std.mem.Allocator,
players: std.ArrayListUnmanaged(Player) = .{},

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

pub fn tick(self: *Self, elapsed_s: f32) void {
    for (self.players.items) |*player| {
        player.tick(elapsed_s);
    }
}

pub fn draw3D(self: *Self, render: *Render) void {
    rl.drawGrid(10, 1.0);
    for (self.players.items) |*player| {
        player.draw(render);
    }
}
