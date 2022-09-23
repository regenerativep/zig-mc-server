const std = @import("std");
const net = std.net;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const log = std.log;
const time = std.time;
const atomic = std.atomic;
const math = std.math;

const Uuid = @import("uuid6");

const mcp = @import("mcproto.zig");
const mcn = @import("mcnet.zig");

pub const PlayerKickReason = union(enum) {
    Custom: []const u8,
    TimedOut,
    Kicked,
};
pub const PlayerData = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    on_ground: bool,
};
pub const PacketClientType = mcn.PacketClient(net.Stream.Reader, net.Stream.Writer, null);
pub const Player = struct {
    eid: i32,
    uuid: Uuid,
    username: []const u8,
    settings: atomic.Atomic(*mcp.ClientSettings.UserType),

    inner: PacketClientType,
    reader_lock: Thread.Mutex = .{},
    writer_lock: Thread.Mutex = .{},
    alive: atomic.Atomic(bool) = .{ .value = true },

    ping: atomic.Atomic(i32) = .{ .value = 0 },
    keep_alive_timer: time.Timer = undefined,
    last_keep_alive_time_len: u64 = 0,
    keep_alives_waiting_lock: Thread.Mutex = .{},
    keep_alives_waiting: std.BoundedArray(i64, 6) = .{ .len = 0 },

    player_data: PlayerData,
    player_data_lock: Thread.Mutex = .{},

    last_player_data: PlayerData = .{
        .x = 0,
        .y = 0,
        .z = 0,
        .yaw = 0,
        .pitch = 0,
        .on_ground = false,
    },

    pub fn handlePacket(self: *Player, alloc: Allocator, game: *Game, packet: anytype) !void {
        switch (packet) {
            .keep_alive => |id| {
                self.keep_alives_waiting_lock.lock();
                defer self.keep_alives_waiting_lock.unlock();
                if (self.keep_alives_waiting.len > 0) {
                    var i: isize = @intCast(isize, self.keep_alives_waiting.len) - 1;
                    while (i >= 0) : (i -= 1) {
                        const val = self.keep_alives_waiting.get(@intCast(usize, i));
                        if (val <= id) {
                            _ = self.keep_alives_waiting.swapRemove(@intCast(usize, i));
                            if (val == id) {
                                self.ping.store(@intCast(i32, time.milliTimestamp() - val), .Unordered);
                            }
                        }
                    }
                }
            },
            .player_position => |data| {
                self.player_data_lock.lock();
                self.player_data.x = data.x;
                self.player_data.y = data.y;
                self.player_data.z = data.z;
                self.player_data.on_ground = data.on_ground;
                self.player_data_lock.unlock();
            },
            .player_position_and_rotation => |data| {
                self.player_data_lock.lock();
                self.player_data.x = data.x;
                self.player_data.y = data.y;
                self.player_data.z = data.z;
                self.player_data.yaw = data.yaw;
                self.player_data.pitch = data.pitch;
                self.player_data.on_ground = data.on_ground;
                self.player_data_lock.unlock();
            },
            .player_rotation => |data| {
                self.player_data_lock.lock();
                self.player_data.yaw = data.yaw;
                self.player_data.pitch = data.pitch;
                self.player_data.on_ground = data.on_ground;
                self.player_data_lock.unlock();
            },
            .player_movement => |on_ground| {
                self.player_data_lock.lock();
                self.player_data.on_ground = on_ground;
                self.player_data_lock.unlock();
            },
            .client_settings => |settings| {
                var new_settings = try alloc.create(mcp.ClientSettings.UserType);
                new_settings.* = settings;
                var old_settings = self.settings.swap(new_settings, .Monotonic);
                alloc.destroy(old_settings);
            },
            .chat_message => |msg| {
                var formatted_msg = try std.fmt.allocPrint(alloc,
                    \\{{"text":"{s}","color":"aqua","extra":[{{"text":": {s}","color":"white"}}]}}
                , .{ self.username, msg });
                defer alloc.free(formatted_msg);
                self.broadcastChatMessage(game, formatted_msg);
            },
            else => log.info("got packet {any}", .{packet}),
        }
    }
    pub fn deinit(self: *Player, alloc: Allocator, game: *Game) void {
        // remove self from player list
        game.players_lock.lock();
        for (game.players.items) |player, i| {
            if (player == self) {
                _ = game.players.swapRemove(i);
                break;
            }
        }
        game.players_lock.unlock();

        // tell everyone in the server we're gone
        game.broadcast(mcp.P.CB, mcp.P.CB.UserType{ .destroy_entities = &[_]i32{self.eid} });
        game.broadcast(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{ .remove_player = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[4].UserType){
            .{
                .uuid = self.uuid,
                .data = {},
            },
        } } });
        if (std.fmt.allocPrint(alloc,
            \\{{"text":"{s}","color":"yellow","extra":[{{"text":" disconnected","color":"white"}}]}}
        , .{self.username})) |formatted_msg| {
            defer alloc.free(formatted_msg);
            self.broadcastChatMessage(game, formatted_msg);
        } else |err| log.err("failed to broadcast disconnect message for player {s}: {any}", .{ self.username, err });

        // deinit resources
        // perhaps we want to move stuff before this into their own function?
        alloc.destroy(self.settings.load(.Unordered));
        game.returnEid(self.eid) catch |err| {
            log.err("lost eid {}: {any}", .{ self.eid, err });
        };
        //self.alive.store(false, .Unordered);
        if (self.alive.load(.Unordered)) {
            self.inner.close();
        }
        alloc.free(self.username);
        alloc.destroy(self);
    }
    pub fn run(self: *Player, alloc: Allocator, game: *Game) void {
        defer self.deinit(alloc, game);
        while (self.alive.load(.Unordered)) {
            self.reader_lock.lock();
            const packet = self.inner.readPacket(mcp.P.SB, alloc) catch |err| {
                defer self.reader_lock.unlock();
                if (err == error.EndOfStream) {
                    log.info("closing client", .{});
                    break;
                }
                log.err("failed to read packet: {any}", .{err});
                if (err == error.ReadTooFar) {
                    log.err("likely a server deserialization bug", .{});
                }
                continue;
            };
            defer mcp.P.SB.deinit(packet, alloc);
            self.reader_lock.unlock();

            self.handlePacket(alloc, game, packet) catch |err| {
                log.err("failed to handle packet from {s}: {any}", .{ self.username, err });
            };
        }
    }
    pub fn sendKick(self: *Player, reason: PlayerKickReason) !void {
        const message = switch (reason) {
            .Custom => |m| m,
            .TimedOut => "{\"text\":\"Timed out!\"}",
            .Kicked => "{\"text\":\"Kicked!\"}",
        };
        try self.inner.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .disconnect = message });
    }
    pub fn broadcastChatMessage(self: *Player, game: *Game, msg: []const u8) void {
        game.players_lock.lock();
        for (game.players.items) |player| {
            const player_client_settings = player.settings.load(.Unordered);
            if (player_client_settings.chat_mode == .Enabled) {
                player.inner.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .chat_message = .{
                    .message = msg,
                    .position = .Chat,
                    .sender = self.uuid,
                } }) catch |err| {
                    log.err("Failed to send chat message to client {s}: {any}", .{ player.username, err });
                };
            }
        }
        game.players_lock.unlock();
    }
    pub fn sendMovement(self: *Player, game: *Game) void {
        self.player_data_lock.lock();
        const nd = self.player_data;
        self.player_data_lock.unlock();
        const ld = self.last_player_data;
        if (!meta.eql(nd, ld)) {
            const position_changed = nd.x != ld.x or nd.y != ld.y or nd.z != ld.z;
            const angle_changed = nd.yaw != ld.yaw or nd.pitch != ld.pitch;
            const yaw = mcp.intoAngle(nd.yaw);
            const pit = mcp.intoAngle(nd.pitch);

            var packet: ?mcp.P.CB.UserType = null;
            if (position_changed) {
                const max_dist_changed = math.max3(@fabs(nd.x - ld.x), @fabs(nd.y - ld.y), @fabs(nd.z - ld.z));
                if (max_dist_changed > 8.0) {
                    packet = .{ .entity_teleport = .{
                        .entity_id = self.eid,
                        .x = nd.x,
                        .y = nd.y,
                        .z = nd.z,
                        .yaw = yaw,
                        .pitch = pit,
                        .on_ground = nd.on_ground,
                    } };
                } else {
                    const dx = @floatToInt(i16, (nd.x - ld.x) * (32 * 128));
                    const dy = @floatToInt(i16, (nd.y - ld.y) * (32 * 128));
                    const dz = @floatToInt(i16, (nd.z - ld.z) * (32 * 128));
                    if (angle_changed) {
                        packet = .{ .entity_position_and_rotation = .{
                            .entity_id = self.eid,
                            .dx = dx,
                            .dy = dy,
                            .dz = dz,
                            .yaw = yaw,
                            .pitch = pit,
                            .on_ground = nd.on_ground,
                        } };
                    } else {
                        packet = .{ .entity_position = .{
                            .entity_id = self.eid,
                            .dx = dx,
                            .dy = dy,
                            .dz = dz,
                            .on_ground = nd.on_ground,
                        } };
                    }
                }
            } else if (angle_changed) {
                packet = .{ .entity_rotation = .{
                    .entity_id = self.eid,
                    .yaw = yaw,
                    .pitch = pit,
                    .on_ground = nd.on_ground,
                } };
            }
            if (packet) |inner_packet| {
                game.broadcastExcept(mcp.P.CB, inner_packet, self);
            }
            if (angle_changed) {
                game.broadcastExcept(mcp.P.CB, mcp.P.CB.UserType{ .entity_head_look = .{
                    .entity_id = self.eid,
                    .yaw = yaw,
                } }, self);
            }
            self.last_player_data = self.player_data;
        }
        self.last_player_data = nd;
    }
};

pub const Game = struct {
    alloc: Allocator,

    players_lock: Thread.Mutex = .{},
    players: std.ArrayList(*Player),
    alive: atomic.Atomic(bool),

    tick_count: u64 = 0,
    keep_alive_timer: time.Timer = undefined,

    available_eids: std.ArrayList(i32),
    available_eids_lock: Thread.Mutex = .{},

    pub fn run(self: *Game) void {
        defer self.deinit();
        self.available_eids.append(1) catch unreachable;
        self.keep_alive_timer = time.Timer.start() catch unreachable;
        var tick_timer = time.Timer.start() catch unreachable;
        const DESIRED_TOTAL_TICK_NS: u64 = (1000 * 1000 * 1000) / 20; // 1/20 sec
        while (self.alive.load(.Unordered)) {
            self.sendPlayerUpdates();
            const TIME_BETWEEN_KEEP_ALIVES: u64 = 1000 * 1000 * 1000 * 5; // 5 seconds
            if (self.keep_alive_timer.read() > TIME_BETWEEN_KEEP_ALIVES) {
                self.sendKeepAlives();
                self.keep_alive_timer.reset();
            }
            self.tick_count += 1;

            var ns = tick_timer.read();
            if (ns > DESIRED_TOTAL_TICK_NS) {
                log.warn("tick took too long! {}ms (tick took {}ms)", .{ (ns - DESIRED_TOTAL_TICK_NS) / 1000, ns / 1000 });
            } else {
                time.sleep(DESIRED_TOTAL_TICK_NS - ns);
            }
            tick_timer.reset();
        }
    }
    pub fn deinit(self: *Game) void {
        std.debug.assert(self.players.items.len == 0);
        self.players.deinit();
        self.available_eids.deinit();
    }
    pub fn sendPlayerUpdates(self: *Game) void {
        self.players_lock.lock();
        for (self.players.items) |player| {
            self.players_lock.unlock();

            player.sendMovement(self);

            self.players_lock.lock();
        }
        self.players_lock.unlock();
    }
    // `i` is position in players array
    // assumes that .players_lock is locked (otherwise `i` might refer to something unintended)
    pub fn kickPlayer(self: *Game, i: usize, reason: PlayerKickReason) !void {
        var player = self.players.items[i];
        defer player.inner.close();
        _ = self.players.swapRemove(i);
        player.alive.store(false, .Unordered);
        player.writer_lock.lock();
        defer player.writer_lock.unlock();
        try player.sendKick(reason);
    }
    pub fn sendLatencyUpdates(self: *Game) void {
        self.players_lock.lock();
        for (self.players.items) |player| {
            self.broadcast(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{
                .update_latency = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[2].UserType){
                    .{
                        .uuid = player.uuid,
                        .data = player.ping.load(.Unordered),
                    },
                },
            } });
        }
        self.players_lock.unlock();
    }
    pub fn sendKeepAlives(self: *Game) void {
        const timestamp = time.milliTimestamp();
        self.players_lock.lock();
        var i: isize = @intCast(isize, self.players.items.len) - 1;
        while (i >= 0) : (i -= 1) {
            var player = self.players.items[@intCast(usize, i)];

            player.writer_lock.lock();
            player.inner.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .keep_alive = timestamp }) catch |err| {
                log.err("error while sending keep alive: {any}", .{err});
            };
            player.writer_lock.unlock();

            player.keep_alives_waiting_lock.lock();
            player.keep_alives_waiting.append(timestamp) catch |waiting_err| {
                std.debug.assert(waiting_err == error.Overflow);
                // if waiting list is overflowing, then player hasnt responded for too many keep alives
                self.kickPlayer(@intCast(usize, i), PlayerKickReason.TimedOut) catch |err| {
                    log.err("error during keep alive kick: {any}", .{err});
                };
            };
            player.keep_alives_waiting_lock.unlock();
        }
        self.players_lock.unlock();
    }
    pub fn getEid(self: *Game) i32 {
        self.available_eids_lock.lock();
        const eid = self.available_eids.items[self.available_eids.items.len - 1];
        if (self.available_eids.items.len == 1) {
            self.available_eids.items[0] = eid + 1;
        } else {
            _ = self.available_eids.pop();
        }
        self.available_eids_lock.unlock();
        return eid;
    }
    pub fn returnEid(self: *Game, eid: i32) !void { // might want to figure out a different way to do this that doesnt potentially return an error
        self.available_eids_lock.lock();
        defer self.available_eids_lock.unlock();
        try self.available_eids.append(eid);
    }
    pub fn broadcast(self: *Game, comptime PacketType: type, packet: PacketType.UserType) void {
        self.players_lock.lock();
        defer self.players_lock.unlock();
        for (self.players.items) |player| {
            player.writer_lock.lock();
            defer player.writer_lock.unlock();
            player.inner.writePacket(PacketType, packet) catch |err| {
                log.err("failed to broadcast packet to player {}: {any}", .{ player.eid, err });
            };
        }
    }
    pub fn broadcastExcept(self: *Game, comptime PacketType: type, packet: PacketType.UserType, except: *Player) void {
        self.players_lock.lock();
        defer self.players_lock.unlock();
        for (self.players.items) |player| {
            if (player == except) continue;
            player.writer_lock.lock();
            defer player.writer_lock.unlock();
            player.inner.writePacket(PacketType, packet) catch |err| {
                log.err("failed to broadcast packet to player {}: {any}", .{ player.eid, err });
            };
        }
    }
};
