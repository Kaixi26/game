const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const net = std.net;
const os = std.os;
const log = std.log.scoped(.server);
const GameState = @import("GameState.zig");
const Player = @import("Player.zig");
const nc = @import("netcode/netcode.zig");

var next_id: u64 = 1;

const ServerContext = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    ticks: u64 = 0,
    tick_rate: u64 = 30,
    previous_tick_ns: u128,
    current_tick_ns: u128,

    clients: std.ArrayListUnmanaged(os.pollfd),
    client_mutex: std.Thread.Mutex,
    game_state: GameState,
    nc_io: *nc.IO,

    packet_send_manager: nc.PacketSendManager,
    packet_recv_manager: nc.PacketReceiveManager,

    pub fn init(allocator: mem.Allocator) !Self {
        var nc_io = try allocator.create(nc.IO);
        nc_io.* = try nc.IO.init(allocator);
        return .{
            .allocator = allocator,
            .previous_tick_ns = @intCast(std.time.nanoTimestamp()),
            .current_tick_ns = @intCast(std.time.nanoTimestamp()),
            .clients = std.ArrayListUnmanaged(os.pollfd){},
            .client_mutex = std.Thread.Mutex{},
            .game_state = .{ .allocator = allocator },
            .nc_io = nc_io,
            .packet_send_manager = nc.PacketSendManager.init(allocator),
            .packet_recv_manager = nc.PacketReceiveManager.init(allocator),
        };
    }

    pub fn handle_received_packet(self: *Self, received_packet: nc.IO.ReceivedPacket) !void {
        defer received_packet.deinit();

        switch (received_packet.packet.*) {
            .ping => {
                try self.packet_send_manager.safeAppendSendPacket(.{
                    .packet = .{ .ping = .{} },
                    .kind = .{ .target = received_packet.connection_id },
                });
                self.packet_send_manager.signalPacketsAdded();
            },
            .join => {
                const player = blk: {
                    self.game_state.lock();
                    defer self.game_state.unlock();
                    defer next_id += 1;

                    const player = Player{ .id = next_id, .x = 0, .y = 0 };
                    try self.game_state.append(player);
                    break :blk player;
                };

                try self.packet_send_manager.safeAppendSendPacket(.{
                    .packet = .{ .join_ok = .{ .id = player.id } },
                    .kind = .{ .target = received_packet.connection_id },
                });
                self.packet_send_manager.signalPacketsAdded();
            },
            .move => |payload| {
                self.game_state.lock();
                defer self.game_state.unlock();

                if (self.game_state.find(payload.player.id)) |player| {
                    player.* = payload.player;
                }
            },
            else => {
                log.err("unhandled packet {}", .{received_packet});
            },
        }
    }

    fn update_ticks(self: *Self) void {
        self.ticks += 1;
        self.previous_tick_ns = self.current_tick_ns;
        self.current_tick_ns = @intCast(std.time.nanoTimestamp());
    }

    fn wait_next_tick(self: *Self) void {
        const ns_per_tick = @divTrunc(std.time.ns_per_s, self.tick_rate);

        const previous_ticks = @divTrunc(self.previous_tick_ns, ns_per_tick);
        const current_ticks = @divTrunc(self.current_tick_ns, ns_per_tick);
        const target_ticks = current_ticks + 1;

        const target_tick_ns = target_ticks * ns_per_tick;

        if (!(previous_ticks + 1 == current_ticks)) {
            log.warn("ticks have been skipped!", .{});
        }

        std.time.sleep(@intCast(target_tick_ns - self.current_tick_ns));
    }

    fn deltaSeconds(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.current_tick_ns - self.previous_tick_ns)) / std.time.ns_per_s;
    }

    pub fn tick(self: *Self) !void {
        self.update_ticks();
        defer self.wait_next_tick();

        {
            self.game_state.lock();
            self.game_state.unlock();
            if (self.game_state.find(69)) |player| {
                player.x += 5 * self.deltaSeconds();
                if (player.x > 10) {
                    player.x = -player.x;
                }
                if (self.ticks % 60 == 0) {
                    log.debug("{d:.3} {d:.3} {d:.3}", .{ player.x, self.deltaSeconds(), 5 * self.deltaSeconds() });
                }
            }
        }
        { // handle packets
            self.packet_recv_manager.mutex.lock();
            defer self.packet_recv_manager.mutex.unlock();

            for (self.packet_recv_manager.received_packets.items) |received_packet| {
                try self.handle_received_packet(received_packet);
            }
            self.packet_recv_manager.received_packets.clearRetainingCapacity();
        }

        { // send packets
            self.game_state.lock();
            defer self.game_state.unlock();

            try self.packet_send_manager.safeAppendSendPacket(.{
                .packet = .{ .update_players = .{ .players = self.game_state.players.items } },
                .kind = .broadcast,
            });
            self.packet_send_manager.signalPacketsAdded();
        }
    }
};

pub fn accept_connections(nc_io: *nc.IO, sockfd: os.socket_t) !void {
    while (true) {
        var accepted_addr: net.Address = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(accepted_addr));
        var client: os.socket_t = try os.accept(sockfd, &accepted_addr.any, &addr_len, os.SOCK.CLOEXEC);
        log.info("accepted client on {}", .{accepted_addr});

        try nc_io.addConnection(client);
    }
}

pub fn start(allocator: mem.Allocator, address: net.Address) !void {
    var sctx = try ServerContext.init(allocator);
    try sctx.game_state.append(.{ .id = 69, .x = 0, .y = 0 });

    var sockfd: os.socket_t = try os.socket(os.AF.INET, os.SOCK.STREAM, 0);
    try os.setsockopt(sockfd, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    log.info("started on {}", .{address});
    defer os.closeSocket(sockfd);

    try os.bind(sockfd, &address.any, address.getOsSockLen());
    try os.listen(sockfd, 5);

    var receive_handler = try std.Thread.spawn(.{}, nc.PacketReceiveManager.handle, .{ &sctx.packet_recv_manager, sctx.nc_io });
    defer receive_handler.join();

    var send_handler = try std.Thread.spawn(.{}, nc.PacketSendManager.handle, .{ &sctx.packet_send_manager, sctx.nc_io });
    defer send_handler.join();

    var connection_handler = try std.Thread.spawn(.{}, accept_connections, .{ sctx.nc_io, sockfd });
    defer connection_handler.join();

    while (true) {
        try sctx.tick();
        std.time.sleep(1E6);
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var address = try net.Address.parseIp("0.0.0.0", 1337);

    start(allocator, address);
}
