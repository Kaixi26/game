const std = @import("std");
const heap = std.heap;
const io = std.io;
const os = std.os;
const net = std.net;
const log = @import("log.zig").game;
const GameState = @import("GameState.zig");
const Player = @import("Player.zig");
const Render = @import("Render.zig");
const nc = @import("netcode/netcode.zig");
const argsParser = @import("args.zig");
const rl = @import("raylib");
const rm = @import("raylib-math");

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

    render: *Render,

    pub fn init(allocator: std.mem.Allocator) !GameContext {
        const nc_io = try allocator.create(nc.IO);
        nc_io.* = try nc.IO.init(allocator);

        const render = try allocator.create(Render);
        render.* = Render.init(allocator);
        try render.loadModels();
        return .{
            .allocator = allocator,
            .game_state = .{ .allocator = allocator },
            .nc_io = nc_io,
            .packet_send_manager = nc.PacketSendManager.init(allocator),
            .packet_recv_manager = nc.PacketReceiveManager.init(allocator),
            .render = render,
        };
    }

    pub fn getPlayer(self: *Self) ?*Player {
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
                if (self.game_state.find(payload.id)) |player| {
                    _ = player;
                } else {
                    try self.game_state.players.append(self.game_state.allocator, .{
                        .id = payload.id,
                        .pos = rl.Vector3.init(0, 0, 0),
                        .vel = rl.Vector3.init(0, 0, 0),
                    });
                }
                self.player_id = payload.id;
                log.info("joined game with id {}", .{payload.id});
            },
            .update_players => |payload| {
                for (payload.players) |player| {
                    if (player.id != self.player_id) {
                        if (self.game_state.find(player.id)) |p| {
                            p.pos = player.pos;
                            p.vel = player.vel;
                            //p.* = player;
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

    pub fn handleReceivedPackets(self: *Self) !void {
        self.packet_recv_manager.mutex.lock();
        defer self.packet_recv_manager.mutex.unlock();

        for (self.packet_recv_manager.received_packets.items) |received_packet| {
            try self.handle_received_packet(received_packet);
        }
        self.packet_recv_manager.received_packets.clearRetainingCapacity();
    }

    pub fn handleSendPackets(self: *Self) !void {
        if (self.elapsed_frames % 1 == 0) {
            if (self.getPlayer()) |player| {
                try self.packet_send_manager.safeAppendSendPacket(.{ .packet = .{ .move = .{ .player = player.* } }, .kind = .broadcast });
            }
        }

        self.packet_send_manager.signalPacketsAdded();
    }

    pub fn handleInput(self: *Self) !void {
        var velocity = rl.Vector3.init(0, 0, 0);
        if (rl.isKeyDown(rl.KeyboardKey.key_up)) {
            velocity.z -= 1;
        }
        if (rl.isKeyDown(rl.KeyboardKey.key_down)) {
            velocity.z += 1;
        }
        if (rl.isKeyDown(rl.KeyboardKey.key_right)) {
            velocity.x += 1;
        }
        if (rl.isKeyDown(rl.KeyboardKey.key_left)) {
            velocity.x -= 1;
        }

        if (self.getPlayer()) |player| {
            player.vel = rm.vector3Scale(velocity, Player.base_velocity);
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
    const screen_width = 800;
    const screen_height = 600;

    rl.setTraceLogLevel(rl.TraceLogLevel.log_error);
    rl.setTargetFPS(60);
    rl.initWindow(screen_width, screen_height, "raylib [core] example - basic window");
    defer rl.closeWindow();

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

    var camera = std.mem.zeroes(rl.Camera);
    camera.position = .{ .x = 0.0, .y = 10.0, .z = 10.0 };
    camera.target = .{ .x = 0.0, .y = 2.0, .z = 0.0 };
    camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    camera.fovy = 45.0;
    camera.projection = rl.CameraProjection.camera_perspective;

    while (!rl.windowShouldClose()) {
        var scratchpad: [1024]u8 = undefined;

        if (gctx.getPlayer()) |p| {
            camera.target = rl.Vector3.init(p.pos.x / 100, 0, p.pos.y / 100);
            camera.position = rl.Vector3.init(p.pos.x / 100, 10, p.pos.y / 100 + 10);
        }

        var camera2d = std.mem.zeroes(rl.Camera2D);
        camera2d.zoom = 1;
        camera2d.offset.x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
        camera2d.offset.y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;

        try gctx.handleInput();

        if (gctx.getPlayer()) |player| {
            camera2d.target.x = player.pos.x;
            camera2d.target.y = player.pos.z;
        }

        rl.clearBackground(rl.Color.ray_white);

        rl.beginDrawing();

        {
            rl.beginMode3D(camera);
            gctx.game_state.draw3D(gctx.render);
            rl.endMode3D();
        }

        {
            rl.beginMode2D(camera2d);
            rl.endMode2D();
        }

        { // Draw FPS/Ping
            var ping_text = try std.fmt.bufPrint(&scratchpad, "PING: {}" ++ .{0}, .{gctx.ping.load(.Monotonic)});
            rl.drawFPS(0, 0);
            rl.drawText(@as([:0]const u8, @ptrCast(ping_text)), 0, 20, 20, rl.Color.lime);
        }

        //rl.updateModelAnimation(model, animation, animation_frame);

        { // Draw grid and reference point at 0,0
            //rl.pushMatrix();
            //rl.translatef(0, 25 * 50, 0);
            //rl.rotatef(90, 1, 0, 0);
            //rl.drawGrid(100, 50);
            //rl.popMatrix();
            //rl.drawCircle(0, 0, 10, rl.Color.pink);
        }

        { // Draw players
            for (gctx.game_state.players.items) |player| {
                rl.drawCircle(@intFromFloat(player.pos.x), @intFromFloat(player.pos.y), @as(f32, @floatFromInt(rl.getScreenWidth())) / 16, rl.Color.blue);
                var ping_text = try std.fmt.bufPrint(&scratchpad, "{}" ++ .{0}, .{player.id});
                rl.drawText(@as([:0]const u8, @ptrCast(ping_text)), @intFromFloat(player.pos.x), @intFromFloat(player.pos.y), 20, rl.Color.black);
            }
        }

        rl.endDrawing();

        try gctx.handleReceivedPackets();
        try gctx.handleSendPackets();

        const frames = @atomicRmw(u64, &gctx.elapsed_frames, .Add, 1, .Monotonic);
        _ = frames;
        gctx.game_state.tick(rl.getFrameTime());
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    try start(allocator);
}
