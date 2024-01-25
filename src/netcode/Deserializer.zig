const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

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

pub fn deserializeVector3(self: *Self) Error!rl.Vector3 {
    return rl.Vector3{
        .x = try self.deserialize(f32),
        .y = try self.deserialize(f32),
        .z = try self.deserialize(f32),
    };
}
