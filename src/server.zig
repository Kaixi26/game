const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const net = std.net;
const os = std.os;
const log = std.log;
const Protocol = @import("Protocol.zig");
const GameState = @import("GameState.zig");
const Player = @import("Player.zig").Player;

var next_id: u64 = 1;

const ServerContext = struct {
    allocator: std.mem.Allocator,
    clients: std.ArrayListUnmanaged(os.pollfd),
    client_mutex: std.Thread.Mutex,
    game_state: GameState,

    const Self = @This();

    pub fn append_client(self: *Self, client: os.socket_t) !void {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        try self.clients.append(self.allocator, .{
            .fd = client,
            .events = os.POLL.IN,
            .revents = 0,
        });
    }

    pub fn get_clients(self: *Self) []os.pollfd {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        return self.clients.items;
    }

    pub fn remove_client(self: *Self, i: usize) void {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        _ = self.clients.swapRemove(i);
    }
};

pub fn client_handler(server_context: *ServerContext) !void {
    var buf: [Protocol.Packet.max_length]u8 = undefined;
    while (true) {
        var clients: []os.pollfd = server_context.get_clients();
        const ready_clients = try os.poll(clients, 1000);
        log.info("SERVER: ready clients: {}/{}", .{ ready_clients, clients.len });

        if (ready_clients > 0) {
            var n = clients.len;
            while (n > 0) : (n -= 1) {
                var i = n - 1;
                var client = clients[i];
                if ((client.revents & os.POLL.HUP) != 0) {
                    os.close(client.fd);
                    server_context.remove_client(i);
                } else if ((client.revents & os.POLL.IN) != 0) {
                    var rd = try os.read(client.fd, &buf);
                    _ = rd;
                    var client_message = try Protocol.Packet.decode(&buf);
                    log.info("SERVER: read data {any}", .{client_message});
                    const client_data = client_message.extractData();
                    switch (client_data) {
                        .ping => {
                            var pong_packet = Protocol.Packet.pong();
                            pong_packet.encode(&buf);
                            _ = try os.write(client.fd, &buf);
                        },
                        .join => {
                            server_context.game_state.lock();
                            defer server_context.game_state.unlock();
                            defer next_id += 1;

                            const player = Player{ .id = next_id, .x = 0, .y = 0 };
                            try server_context.game_state.append(player);
                            var packet = Protocol.Packet.joinOk(player);
                            packet.encode(&buf);
                            _ = try os.write(client.fd, &buf);
                        },
                        .move => |updated_player| {
                            server_context.game_state.lock();
                            defer server_context.game_state.unlock();

                            if (server_context.game_state.find(updated_player.id)) |player| {
                                player.* = updated_player;
                            }

                            var packet = Protocol.Packet.update_players(server_context.game_state.players.items);
                            packet.encode(&buf);
                            _ = try os.write(client.fd, &buf);
                        },
                        else => {
                            log.err("SERVER: Unhandled packet {}", .{client_message});
                        },
                    }
                } else if (client.revents != 0) {
                    log.warn("SERVER: unhandled pool revent 0x{x}", .{client.revents});
                }
            }
        }
    }
}

pub fn start(allocator: mem.Allocator, address: net.Address) !void {
    var sockfd: os.socket_t = try os.socket(os.AF.INET, os.SOCK.STREAM, 0);
    try os.setsockopt(sockfd, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    log.info("SERVER: started on {}", .{address});
    defer os.closeSocket(sockfd);

    try os.bind(sockfd, &address.any, address.getOsSockLen());
    try os.listen(sockfd, 5);

    var server_context = ServerContext{
        .allocator = allocator,
        .clients = std.ArrayListUnmanaged(os.pollfd){},
        .client_mutex = std.Thread.Mutex{},
        .game_state = .{ .allocator = allocator },
    };

    try server_context.game_state.append(.{ .id = 69, .x = 0xbb, .y = 0xbb });

    var handler = try std.Thread.spawn(.{}, client_handler, .{&server_context});
    defer handler.join();

    while (true) {
        var accepted_addr: net.Address = undefined;
        var addr_len: os.socklen_t = @sizeOf(@TypeOf(accepted_addr));
        var client: os.socket_t = try os.accept(sockfd, &accepted_addr.any, &addr_len, os.SOCK.CLOEXEC);
        log.info("SERVER: accepted client on {}", .{accepted_addr});

        try server_context.append_client(client);
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var address = try net.Address.parseIp("0.0.0.0", 1337);

    start(allocator, address);
}
