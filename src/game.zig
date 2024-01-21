const std = @import("std");
const heap = std.heap;
const io = std.io;
const os = std.os;
const net = std.net;
const log = @import("log.zig").game;
const GameState = @import("GameState.zig");
const Player = @import("Player.zig");
const nc = @import("netcode/netcode.zig");
const argsParser = @import("args.zig");
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

const velocity = 10;

const GameContext = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    elapsed_frames: u64 = 0,
    ping: std.atomic.Atomic(i64) = std.atomic.Atomic(i64).init(0),
    player_id: ?Player.Id = null,
    game_state: GameState,
    nc_io: *nc.IO,

    packet_send_manager: nc.PacketSendManager,
    packet_recv_manager: nc.PacketReceiveManager,

    pub fn init(allocator: std.mem.Allocator) !GameContext {
        const nc_io = try allocator.create(nc.IO);
        nc_io.* = try nc.IO.init(allocator);
        return .{
            .allocator = allocator,
            .game_state = .{ .allocator = allocator },
            .nc_io = nc_io,
            .packet_send_manager = nc.PacketSendManager.init(allocator),
            .packet_recv_manager = nc.PacketReceiveManager.init(allocator),
        };
    }

    pub fn safeGetPlayer(self: *Self) ?*Player {
        self.game_state.lock();
        defer self.game_state.unlock();
        if (self.player_id) |id| {
            return self.game_state.find(id);
        }
        return null;
    }

    pub fn handle_received_packet(self: *Self, received_packet: nc.IO.ReceivedPacket) !void {
        defer received_packet.deinit();
        // log.debug("handling packet {}", .{received_packet.packet.*});

        switch (received_packet.packet.*) {
            .join_ok => |payload| {
                self.game_state.players_mutex.lock();
                defer self.game_state.players_mutex.unlock();

                if (self.game_state.find(payload.id)) |player| {
                    _ = player;
                } else {
                    try self.game_state.players.append(self.game_state.allocator, .{ .id = payload.id, .x = 0, .y = 0 });
                }
                self.player_id = payload.id;
                log.info("joined game with id {}", .{payload.id});
            },
            .update_players => |payload| {
                for (payload.players) |player| {
                    if (player.id != self.player_id) {
                        if (self.game_state.find(player.id)) |p| {
                            p.* = player;
                        } else {
                            try self.game_state.append(player);
                        }
                    }
                }
            },
            else => {
                log.warn("Unhandled packet {}", .{received_packet.packet.*});
            },
        }
    }
};

pub fn handle_connection(gctx: *GameContext, address: net.Address) !void {
    std.time.sleep(1E6);

    var sock: os.socket_t = try os.socket(os.AF.INET, os.SOCK.STREAM, 0);
    _ = try os.connect(sock, &address.any, address.getOsSockLen());
    try gctx.nc_io.addConnection(sock);

    try gctx.packet_send_manager.safeAppendSendPacket(.{ .packet = .{ .join = .{} }, .kind = .broadcast });

    var receive_handler = try std.Thread.spawn(.{}, nc.PacketReceiveManager.handle, .{ &gctx.packet_recv_manager, gctx.nc_io });
    defer receive_handler.join();
    var send_handler = try std.Thread.spawn(.{}, nc.PacketSendManager.handle, .{ &gctx.packet_send_manager, gctx.nc_io });
    defer send_handler.join();
}

const GameArgsSpec = struct {
    host: []const u8 = "0.0.0.0"[0..],
    port: u16 = 1337,

    pub const shorthands = .{
        .h = "host",
        .p = "port",
    };

    pub const meta = .{
        .option_docs = .{
            .host = "TCP host IP to connect to",
            .port = "TCP host port to connect to",
        },
    };
};

pub fn start(allocator: std.mem.Allocator) !void {
    var gctx = try GameContext.init(allocator);

    const parsed_args = argsParser.parseForCurrentProcess(GameArgsSpec, allocator, .print) catch |err| {
        const out = std.io.getStdOut();
        var writer = std.io.bufferedWriter(out.writer());
        try argsParser.printHelp(GameArgsSpec, "game", writer.writer());
        try writer.flush();
        return err;
    };
    defer parsed_args.deinit();

    std.debug.print("{s}", .{parsed_args.options.host});

    var address = try std.net.Address.parseIp(parsed_args.options.host, parsed_args.options.port);

    var handler = try std.Thread.spawn(.{}, handle_connection, .{ &gctx, address });
    defer handler.join();

    const screen_width = 800;
    const screen_height = 600;

    rl.SetTraceLogLevel(rl.LOG_ERROR);

    rl.InitWindow(screen_width, screen_height, "raylib [core] example - basic window");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    while (!rl.WindowShouldClose()) {
        var scratchpad: [1024]u8 = undefined;
        var camera = std.mem.zeroes(rl.Camera2D);
        camera.zoom = 1;
        camera.offset.x = @as(f32, @floatFromInt(rl.GetScreenWidth())) / 2;
        camera.offset.y = @as(f32, @floatFromInt(rl.GetScreenHeight())) / 2;

        rl.ClearBackground(rl.RAYWHITE);

        if (gctx.safeGetPlayer()) |player| {
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
            camera.target.x = player.x;
            camera.target.y = player.y;
        }

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.BeginMode2D(camera);

        { // Draw grid and reference point at 0,0
            rl.rlPushMatrix();
            rl.rlTranslatef(0, 25 * 50, 0);
            rl.rlRotatef(90, 1, 0, 0);
            rl.DrawGrid(100, 50);
            rl.rlPopMatrix();
            rl.DrawCircle(0, 0, 10, rl.PINK);
        }

        { // Draw players
            gctx.game_state.lock();
            defer gctx.game_state.unlock();

            for (gctx.game_state.players.items) |player| {
                rl.DrawCircle(@intFromFloat(player.x), @intFromFloat(player.y), @as(f32, @floatFromInt(rl.GetScreenWidth())) / 16, rl.BLUE);
                var ping_text = try std.fmt.bufPrint(&scratchpad, "{}" ++ .{0}, .{player.id});
                rl.DrawText(@as([*:0]const u8, @ptrCast(ping_text)), @intFromFloat(player.x), @intFromFloat(player.y), 20, rl.BLACK);
            }
        }

        { // handle packets
            gctx.packet_recv_manager.mutex.lock();
            defer gctx.packet_recv_manager.mutex.unlock();

            for (gctx.packet_recv_manager.received_packets.items) |received_packet| {
                try gctx.handle_received_packet(received_packet);
            }
            gctx.packet_recv_manager.received_packets.clearRetainingCapacity();
        }

        rl.EndMode2D();

        {
            var ping_text = try std.fmt.bufPrint(&scratchpad, "PING: {}" ++ .{0}, .{gctx.ping.load(.Monotonic)});
            rl.DrawFPS(0, 0);
            rl.DrawText(@as([*:0]const u8, @ptrCast(ping_text)), 0, 20, 20, rl.LIME);
        }

        { // send packets
            if (gctx.elapsed_frames % 1 == 0) {
                if (gctx.safeGetPlayer()) |player| {
                    try gctx.packet_send_manager.safeAppendSendPacket(.{ .packet = .{ .move = .{ .player = player.* } }, .kind = .broadcast });
                }
            }

            gctx.packet_send_manager.signalPacketsAdded();
        }

        const frames = @atomicRmw(u64, &gctx.elapsed_frames, .Add, 1, .Monotonic);
        _ = frames;
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    try start(allocator);
}
