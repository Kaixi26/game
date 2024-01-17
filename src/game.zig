const std = @import("std");
const heap = std.heap;
const io = std.io;
const os = std.os;
const net = std.net;
const log = std.log;
const GameState = @import("GameState.zig");
const Protocol = @import("Protocol.zig");
const Player = @import("Player.zig").Player;
const rl = @cImport({
    @cInclude("raylib.h");
});

const velocity = 10;

const GameContext = struct {
    allocator: std.mem.Allocator,
    ping: std.atomic.Atomic(i64) = std.atomic.Atomic(i64).init(0),
    sock: os.socket_t,
    player: ?Player.Id = null,
    game_state: GameState,

    pub fn init(allocator: std.mem.Allocator, sock: os.socket_t) GameContext {
        return .{
            .allocator = allocator,
            .sock = sock,
            .game_state = .{ .allocator = allocator },
        };
    }
};

pub fn handle_connection_wrapped(ctx: *GameContext) !void {
    var buf: [Protocol.Packet.max_length]u8 = undefined;

    {
        var packet_join = Protocol.Packet.join();
        packet_join.encode(&buf);
        _ = try os.write(ctx.sock, &buf);
        _ = try os.read(ctx.sock, &buf);
        var packet = try Protocol.Packet.decode(&buf);
        log.debug("GAME: read packet {}", .{packet});
        var packet_data = packet.extractData();
        switch (packet_data) {
            .join_ok => |player| {
                log.debug("GAME: Player {}", .{player});
                ctx.game_state.players_mutex.lock();
                defer ctx.game_state.players_mutex.unlock();
                try ctx.game_state.players.append(ctx.game_state.allocator, player);
                ctx.player = player.id;
            },
            else => {},
        }
    }

    while (true) {
        var opt_player = blk: {
            ctx.game_state.lock();
            ctx.game_state.unlock();
            if (ctx.player) |id| {
                break :blk ctx.game_state.find(id);
            }
            break :blk null;
        };
        log.debug("GAME: {?}", .{opt_player});

        if (opt_player) |player| {
            var packet = Protocol.Packet.move(player.*);
            packet.encode(&buf);
            _ = try os.write(ctx.sock, &buf);

            const curr_ms = std.time.milliTimestamp();
            _ = try os.read(ctx.sock, &buf);

            const elapsed_ms = std.time.milliTimestamp() - curr_ms;
            ctx.ping.store(elapsed_ms, .Monotonic);

            const received_packet = try Protocol.Packet.decode(&buf);
            const received_data = received_packet.extractData();
            switch (received_data) {
                .update_players => |players| {
                    for (players) |updated_player| {
                        if (updated_player.id != ctx.player) {
                            if (ctx.game_state.find(updated_player.id)) |p| {
                                p.* = updated_player;
                            } else {
                                try ctx.game_state.append(updated_player);
                            }
                        }
                    }
                    log.debug("GAME: update_players {any}", .{players});
                    log.debug("GAME: update_players {}", .{std.fmt.fmtSliceHexLower(received_packet.buf[0..69])});
                },
                else => {},
            }
            log.debug("GAME: read packet {}", .{received_packet});
        }
        std.time.sleep(1E6);
    }
}

pub fn handle_connection(ctx: *GameContext) void {
    handle_connection_wrapped(ctx) catch |err| {
        log.err("GAME: error in `handle_connection` {}", .{err});
    };
}

pub fn start(allocator: std.mem.Allocator, address: net.Address) !void {
    var sock: os.socket_t = try os.socket(os.AF.INET, os.SOCK.STREAM, 0);
    _ = try os.connect(sock, &address.any, address.getOsSockLen());

    var ctx = GameContext.init(allocator, sock);
    log.debug("GAME: connected to socket", .{});

    var handler = try std.Thread.spawn(.{}, handle_connection, .{&ctx});
    defer handler.join();
    defer os.close(sock);

    const screen_width = 800;
    const screen_height = 600;

    rl.InitWindow(screen_width, screen_height, "raylib [core] example - basic window");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        defer rl.EndDrawing();
        if (ctx.player) |id| {
            ctx.game_state.lock();
            defer ctx.game_state.unlock();

            if (ctx.game_state.find(id)) |player| {
                if (rl.IsKeyDown(rl.KEY_UP)) {
                    player.y -= 10;
                }
                if (rl.IsKeyDown(rl.KEY_DOWN)) {
                    player.y += 10;
                }
                if (rl.IsKeyDown(rl.KEY_RIGHT)) {
                    player.x += 10;
                }
                if (rl.IsKeyDown(rl.KEY_LEFT)) {
                    player.x -= 10;
                }
            }
        }

        {
            ctx.game_state.lock();
            defer ctx.game_state.unlock();

            for (ctx.game_state.players.items) |player| {
                rl.DrawCircle(@intFromFloat(player.x), @intFromFloat(player.y), @as(f32, @floatFromInt(rl.GetScreenWidth())) / 16, rl.BLUE);
            }
        }

        {
            var buf: [1024]u8 = undefined;
            var ping_text = try std.fmt.bufPrint(&buf, "PING: {}" ++ .{0}, .{ctx.ping.load(.Monotonic)});
            rl.DrawFPS(0, 0);
            rl.DrawText(@as([*:0]const u8, @ptrCast(ping_text)), 0, 20, 20, rl.LIME);
        }

        rl.ClearBackground(rl.RAYWHITE);
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var address = try std.net.Address.parseIp("0.0.0.0", 1337);

    try start(allocator, address);
}
