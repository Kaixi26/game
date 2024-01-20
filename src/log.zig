const std = @import("std");

pub const netcode = std.log.scoped(.netcode);
pub const server = std.log.scoped(.server);
pub const game = std.log.scoped(.game);

pub const scope_levels = [_]std.log.ScopeLevel{
    .{ .scope = .netcode, .level = .info },
    .{ .scope = .server, .level = .debug },
    .{ .scope = .game, .level = .debug },
};
