const nc = @import("netcode/netcode.zig");
const Serializer = nc.Serializer;
const Deserializer = nc.Deserializer;

const Self = @This();
pub const Id = u64;

id: Id,
x: f32,
y: f32,

pub fn serialize(self: Self, ser: *Serializer) Serializer.Error!void {
    try ser.serialize(self.id);
    try ser.serialize(self.x);
    try ser.serialize(self.y);
}

pub fn deserialize(des: *Deserializer) Deserializer.Error!Self {
    return .{
        .id = try des.deserialize(Id),
        .x = try des.deserialize(f32),
        .y = try des.deserialize(f32),
    };
}
