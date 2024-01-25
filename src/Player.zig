const std = @import("std");
const math = std.math;
const nc = @import("netcode/netcode.zig");
const Serializer = nc.Serializer;
const Deserializer = nc.Deserializer;
const Render = @import("Render.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");

const Self = @This();
pub const Id = u64;

pub const base_velocity = 1000;

id: Id,
pos: rl.Vector3,
vel: rl.Vector3,

facing_angle: f32 = 0,

pub fn tick(self: *Self, elapsed_s: f32) void {
    self.pos = rm.vector3Add(self.pos, rm.vector3Scale(self.vel, elapsed_s));

    if (rm.vector3Length(self.vel) > 0.1) {
        self.facing_angle = math.atan2(f32, self.vel.x, self.vel.z);
    }
}

pub fn draw(self: *Self, render: *Render) void {
    var am = render.getAnimated(.robot);
    if (rm.vector3Length(self.vel) > 0) {
        am.update(@intFromEnum(Render.RobotAnimations.robot_running), 0, 1);
    } else {
        am.update(@intFromEnum(Render.RobotAnimations.robot_idle), 0, 1);
    }
    am.model.transform = rm.matrixRotateY(self.facing_angle);
    am.model.draw(.{ .x = self.pos.x / 100, .y = 0, .z = self.pos.z / 100 }, 0.5, rl.Color.white);
}

pub fn serialize(self: Self, ser: *Serializer) Serializer.Error!void {
    try ser.serialize(self.id);
    try ser.serializeVector3(self.pos);
    try ser.serializeVector3(self.vel);
}

pub fn deserialize(des: *Deserializer) Deserializer.Error!Self {
    return .{
        .id = try des.deserialize(Id),
        .pos = try des.deserializeVector3(),
        .vel = try des.deserializeVector3(),
    };
}
