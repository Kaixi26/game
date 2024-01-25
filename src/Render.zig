const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

const Self = @This();

allocator: Allocator,

animated_models: std.ArrayListUnmanaged(AnimatedModel) = .{},

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn getAnimated(self: Self, kind: AnimatedModelKind) AnimatedModel {
    return self.animated_models.items[@intCast(@intFromEnum(kind))];
}

pub fn loadAnimatedModel(self: *Self, model_filename: [:0]const u8, animation_filename: [:0]const u8) !void {
    const model = rl.loadModel(model_filename);
    const animations = rl.loadModelAnimations(animation_filename) catch unreachable;

    for (animations) |animation| {
        std.debug.print("{s}\n", .{animation.name});
    }

    try self.animated_models.append(self.allocator, .{ .model = model, .animations = animations });
}

pub const AnimatedModel = struct {
    model: rl.Model,
    animations: []rl.ModelAnimation,

    pub fn update(self: AnimatedModel, idx: usize, start_time: f64, speed: f64) void {
        const animation = self.animations[idx];
        const frame: i32 = @intFromFloat(@mod((rl.getTime() - start_time) * 50 * speed, @as(f64, @floatFromInt(animation.frameCount))));
        rl.updateModelAnimation(self.model, animation, frame);
    }
};

pub const AnimatedModelKind = enum(u8) {
    robot = 0x00,
};

pub const RobotAnimations = enum(u8) {
    robot_dance,
    robot_death,
    robot_idle,
    robot_jump,
    robot_no,
    robot_punch,
    robot_running,
    robot_sitting,
    robot_standing,
    robot_thumbsup,
    robot_walking,
    robot_walkjump,
    robot_wave,
    robot_yes,
};

pub fn loadModels(self: *Self) !void {
    try self.loadAnimatedModel("resources/robot.glb", "resources/robot.glb");
}
