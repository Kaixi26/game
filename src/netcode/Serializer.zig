const std = @import("std");
const Allocator = std.mem.Allocator;

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
