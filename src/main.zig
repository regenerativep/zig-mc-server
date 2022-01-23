const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const log = std.log;
const time = std.time;
const event = std.event;
const atomic = std.atomic;
const math = std.math;

const Uuid = @import("uuid6");

const serde = @import("serde.zig");
const mcp = @import("mcproto.zig");
const mcn = @import("mcnet.zig");
const nbt = @import("nbt.zig");

pub fn handleStatus(alloc: Allocator, cl: anytype) !void {
    defer cl.close();
    const request_packet = try cl.readPacket(mcp.S.SB, alloc);
    defer mcp.S.SB.deinit(request_packet, alloc);
    std.log.info("packet data: {any}", .{request_packet});
    if (request_packet != .request) {
        std.log.info("didnt receive a request", .{});
        return;
    }
    var response_data =
        \\{
        \\  "version": {
        \\    "name": "crappy server 1.18.1",
        \\    "protocol": 757
        \\  },
        \\  "players": {
        \\    "max": 69,
        \\    "online": 0
        \\  },
        \\  "description": {
        \\    "text": "zig test server status"
        \\  }
        \\}
    ;
    try cl.writePacket(mcp.S.CB, mcp.S.CB.UserType{ .response = response_data });
    const ping_packet = try cl.readPacket(mcp.S.SB, alloc);
    defer mcp.S.SB.deinit(ping_packet, alloc);
    if (ping_packet != .ping) {
        std.log.info("didnt receive a ping", .{});
        return;
    }
    try cl.writePacket(mcp.S.CB, mcp.S.CB.UserType{ .pong = ping_packet.ping });
    std.log.info("done", .{});
}

pub fn handleLogin(alloc: Allocator, game: *Game, cl: anytype) !void {
    errdefer cl.close();
    const login_start_packet = try cl.readPacket(mcp.L.SB, alloc);
    defer mcp.L.SB.deinit(login_start_packet, alloc);
    if (login_start_packet != .login_start) {
        std.log.info("didnt receive login start", .{});
        return;
    }
    const username = login_start_packet.login_start;
    std.log.info("\"{s}\" trying to connect", .{username});
    const uuid = try mcp.uuidFromUsername(username);
    try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .login_success = .{ .username = username, .uuid = uuid } });
    // play state now
    const dimension_names = [_][]const u8{
        "minecraft:overworld",
    };
    const eid: i32 = game.getEid();
    errdefer {
        game.returnEid(eid) catch |err| {
            log.err("lost eid {}: {any}", .{ eid, err });
        };
        // if allocation failure, then oops, guess we're never using that eid again
    }
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{
        .join_game = .{
            .entity_id = eid,
            .is_hardcore = false,
            .gamemode = .Creative,
            .previous_gamemode = .None,
            .dimension_names = std.mem.span(&dimension_names),
            .dimension_codec = mcp.DEFUALT_DIMENSION_CODEC,
            .dimension = mcp.DEFAULT_DIMENSION_TYPE_ELEMENT, //default_dimension_codec.@"minecraft:dimension_type".value[0].element,
            .dimension_name = "minecraft:overworld",
            .hashed_seed = 1,
            .max_players = 69,
            .view_distance = 12,
            .simulation_distance = 12,
            .reduced_debug_info = false,
            .enable_respawn_screen = false,
            .is_debug = false,
            .is_flat = true,
        },
    });
    std.log.info("sent join game", .{});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .plugin_message = .{
        .channel = "minecraft:brand",
        .data = &[_]u8{ 5, 'z', 'i', 'g', 'm', 'c' },
    } });
    std.log.info("sent difficulty", .{});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .server_difficulty = .{
        .difficulty = .Peaceful,
        .difficulty_locked = true,
    } });
    std.log.info("sent player abilities", .{});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .player_abilities = .{
        .flags = .{
            .invulnerable = true,
            .flying = false,
            .allow_flying = true,
            .creative_mode = true,
        },
        .flying_speed = 0.05,
        .field_of_view_modifier = 0.1,
    } });
    var packet = try cl.readPacket(mcp.P.SB, alloc);
    std.log.info("packet {any}", .{packet});
    defer mcp.P.SB.deinit(packet, alloc);
    while (packet != .client_settings) {
        if (packet == .plugin_message) {
            if (std.mem.eql(u8, packet.plugin_message.channel, "minecraft:brand")) {
                std.log.info("client brand is \"{s}\"", .{packet.plugin_message.data[1..]});
            }
        } else {
            std.log.info("unexpected packet {any}", .{packet});
        }
        mcp.P.SB.deinit(packet, alloc);
        packet = try cl.readPacket(mcp.P.SB, alloc);
    }
    std.log.info("client settings: {any}", .{packet.client_settings});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .held_item_change = 0 });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .declare_recipes = &[_]mcp.Recipe{
        .{
            .type = "crafting_shapeless",
            .recipe_id = "minecraft:recipe_flint_and_steel",
            .data = .{ .crafting_shapeless = .{
                .group = "steel",
                .ingredients = &[_]mcp.Ingredient.UserType{
                    &[_]mcp.Slot.UserType{.{
                        .item_id = 762,
                        .item_count = 1,
                        .nbt = &[_]nbt.TagDynNbtPair{},
                    }},
                    &[_]mcp.Slot.UserType{.{
                        .item_id = 692,
                        .item_count = 1,
                        .nbt = &[_]nbt.TagDynNbtPair{},
                    }},
                },
                .result = .{
                    .item_id = 680,
                    .item_count = 1,
                    .nbt = &[_]nbt.TagDynNbtPair{},
                },
            } },
        },
    } });
    //try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{
    //    .tags = &[_]meta.Child(mcp.Tags.UserType){
    //        .{
    //            .tag_type = "minecraft:block",
    //            .tags = &[_]mcp.TagEntries.UserType{.{
    //                .tag_name = "mineable/shovel",
    //                .entries = &[_]i32{9}, // 9 is dirt probably
    //            }},
    //        },
    //        .{
    //            .tag_type = "minecraft:item",
    //            .tags = &[_]mcp.TagEntries.UserType{},
    //        },
    //        .{
    //            .tag_type = "minecraft:fluid",
    //            .tags = &[_]mcp.TagEntries.UserType{},
    //        },
    //        .{
    //            .tag_type = "minecraft:entity_type",
    //            .tags = &[_]mcp.TagEntries.UserType{},
    //        },
    //        .{
    //            .tag_type = "minecraft:game_event",
    //            .tags = &[_]mcp.TagEntries.UserType{},
    //        },
    //    },
    //});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .entity_status = .{ .entity_id = eid, .entity_status = 28 } }); // set op level to 4
    const teleport_id: i32 = 5;
    const pos_and_look = mcp.P.CB.UserType{ .player_position_and_look = .{
        .x = 0,
        .y = 32,
        .z = 0,
        .yaw = 0.0,
        .pitch = 0.0,
        .relative = .{
            .x = false,
            .y = false,
            .z = false,
            .y_rot = false,
            .x_rot = false,
        },
        .teleport_id = teleport_id,
        .dismount_vehicle = false,
    } };
    try cl.writePacket(mcp.P.CB, pos_and_look);
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{
        .add_player = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[0].UserType){
            .{
                .uuid = uuid,
                .data = .{
                    .name = username,
                    .properties = &[_]mcp.PlayerProperty.UserType{},
                    .gamemode = .Creative,
                    .ping = 0,
                    .display_name = null,
                },
            },
        },
    } });

    {
        game.players_lock.lock();
        defer game.players_lock.unlock();
        for (game.players.items) |player| {
            try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{
                .add_player = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[0].UserType){
                    .{
                        .uuid = player.uuid,
                        .data = .{
                            .name = player.username,
                            .properties = &[_]mcp.PlayerProperty.UserType{},
                            .gamemode = .Creative,
                            .ping = player.ping.load(.Unordered),
                            .display_name = null,
                        },
                    },
                },
            } });
        }
    }

    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{
        .update_latency = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[2].UserType){
            .{
                .uuid = uuid,
                .data = 0,
            },
        },
    } });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .update_view_position = .{ .chunk_x = 0, .chunk_z = 0 } });
    const height = 256;
    const floor_height = 16;
    const MbInt = std.math.IntFittingRange(0, height - 1);
    const ratio = 64 / meta.bitCount(MbInt);
    const long_count = ((16 * 16) + (ratio - 1)) / ratio;
    var longs = try alloc.alloc(i64, long_count);
    defer alloc.free(longs);
    var total: usize = 0;
    var i: usize = 0;
    while (i < long_count) : (i += 1) {
        var current_long: i64 = 0;
        var j: usize = 0;
        while (j < ratio) : (j += 1) {
            if (total < 16 * 16) {
                current_long = (current_long << meta.bitCount(MbInt)) | @as(MbInt, floor_height);
                total += 1;
            } else {
                break;
            }
        }
        const remainder = 64 % meta.bitCount(MbInt);
        longs[i] = current_long << remainder;
    }
    const section_count = height / 16;
    var sky_light_mask = try std.DynamicBitSetUnmanaged.initFull(alloc, section_count + 2);
    defer sky_light_mask.deinit(alloc);
    sky_light_mask.setValue(0, false);
    sky_light_mask.setValue(1, false);
    var empty_sky_light_mask = try sky_light_mask.clone(alloc);
    defer empty_sky_light_mask.deinit(alloc);
    empty_sky_light_mask.toggleAll();

    var block_light_mask = try std.DynamicBitSetUnmanaged.initEmpty(alloc, section_count + 2);
    defer block_light_mask.deinit(alloc);
    var empty_block_light_mask = try block_light_mask.clone(alloc);
    defer empty_block_light_mask.deinit(alloc);
    empty_block_light_mask.toggleAll();

    const full_light = [_]u8{0xFF} ** 2048;
    const sky_light_arrays = [_][]const u8{&full_light} ** section_count; // section count + 2 - 2

    var chunk_packet = mcp.P.CB.UserType{
        .chunk_data_and_update_light = .{
            .chunk_x = 0,
            .chunk_z = 0,
            .heightmaps = .{
                .MOTION_BLOCKING = longs,
                .WORLD_SURFACE = null,
            },
            .data = &([_]mcp.ChunkSection.UserType{
                .{
                    .block_count = 4096,
                    .block_states = .{
                        .bits_per_entry = 0,
                        .palette = .{ .single = 6 }, // andesite
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                    .biomes = .{
                        .bits_per_entry = 0,
                        .palette = .{ .single = 1 }, // plains?
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                },
            } ++ [_]mcp.ChunkSection.UserType{
                .{
                    .block_count = 0,
                    .block_states = .{
                        .bits_per_entry = 0,
                        .palette = .{ .single = 0 },
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                    .biomes = .{
                        .bits_per_entry = 0,
                        .palette = .{ .single = 1 },
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                },
            } ** (section_count - 1)),
            .block_entities = &[_]mcp.BlockEntity.UserType{},
            .trust_edges = true,
            .sky_light_mask = sky_light_mask,
            .block_light_mask = block_light_mask,
            .empty_sky_light_mask = empty_sky_light_mask,
            .empty_block_light_mask = empty_block_light_mask,
            .sky_light_arrays = std.mem.span(&sky_light_arrays),
            .block_light_arrays = &[_][]const u8{},
        },
    };
    var k: i32 = -4;
    while (k <= 4) : (k += 1) {
        var j: i32 = -4;
        while (j <= 4) : (j += 1) {
            chunk_packet.chunk_data_and_update_light.chunk_x = k;
            chunk_packet.chunk_data_and_update_light.chunk_z = j;
            try cl.writePacket(mcp.P.CB, chunk_packet);
            //std.log.info("writing chunk xz: {} {}", .{ k, j });
        }
    }
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .world_border_center = .{ .x = 0.0, .z = 0.0 } });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .world_border_size = 128.0 });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .spawn_position = .{
        .location = .{
            .x = 0,
            .z = 0,
            .y = 32,
        },
        .angle = 0.0,
    } });
    try cl.writePacket(mcp.P.CB, pos_and_look);
    const teleport_confirm_packet = try cl.readPacket(mcp.P.SB, alloc);
    defer mcp.P.SB.deinit(teleport_confirm_packet, alloc);
    if (teleport_confirm_packet == .teleport_confirm) {
        std.debug.assert(teleport_confirm_packet.teleport_confirm == teleport_id);
    } else {
        std.log.info("unexpected packet {any}", .{teleport_confirm_packet});
    }
    const pos_rot_packet = try cl.readPacket(mcp.P.SB, alloc);
    defer mcp.P.SB.deinit(pos_rot_packet, alloc);
    if (pos_rot_packet == .player_position_and_rotation) {
        std.log.info("got pos rot {any}", .{pos_rot_packet});
    } else {
        std.log.info("unexpected packet {any}", .{teleport_confirm_packet});
    }
    var player = try alloc.create(Player);
    errdefer {
        alloc.destroy(player);
        cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .disconnect = "{\"text\":\"internal error\"}" }) catch |err| {
            log.err("error during player disconnect for internal error: {any}", .{err});
        };
    }
    player.* = Player{
        .inner = cl.*,
        .eid = eid,
        .uuid = uuid,
        .username = try alloc.dupe(u8, username),
        .player_data = .{
            .x = 0,
            .y = 32,
            .z = 0,
            .yaw = 0,
            .pitch = 0,
            .on_ground = false,
        },
    };
    {
        game.players_lock.lock();
        defer game.players_lock.unlock();
        try game.players.append(player);
    }
    game.broadcastExcept(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{ .add_player = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[0].UserType){
        .{
            .uuid = uuid,
            .data = .{
                .name = username,
                .properties = &[_]mcp.PlayerProperty.UserType{},
                .gamemode = mcp.Gamemode.Creative,
                .ping = 0,
                .display_name = null,
            },
        },
    } } }, player);
    {
        game.players_lock.lock();
        defer game.players_lock.unlock();
        for (game.players.items) |other_player| {
            if (other_player == player) continue;
            other_player.player_data_lock.lock();
            defer other_player.player_data_lock.unlock();
            try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .spawn_player = .{
                .entity_id = other_player.eid,
                .player_uuid = other_player.uuid,
                .x = other_player.player_data.x,
                .y = other_player.player_data.y,
                .z = other_player.player_data.z,
                .yaw = mcp.intoAngle(other_player.player_data.yaw),
                .pitch = mcp.intoAngle(other_player.player_data.pitch),
            } });
        }
    }
    player.player_data_lock.lock();
    game.broadcastExcept(mcp.P.CB, mcp.P.CB.UserType{ .spawn_player = .{
        .entity_id = player.eid,
        .player_uuid = player.uuid,
        .x = player.player_data.x,
        .y = player.player_data.y,
        .z = player.player_data.z,
        .yaw = mcp.intoAngle(player.player_data.yaw),
        .pitch = mcp.intoAngle(player.player_data.pitch),
    } }, player);
    player.player_data_lock.unlock();
    const thread = try Thread.spawn(.{}, Player.run, .{ player, alloc, game });
    thread.detach();
}

const PacketClientType = mcn.PacketClient(net.Stream.Reader, net.Stream.Writer, null);

pub fn handleClient(alloc: Allocator, game: *Game, conn: net.StreamServer.Connection) !void {
    std.log.info("connection", .{});
    var cl = mcn.packetClient(conn, conn.stream.reader(), conn.stream.writer(), null);
    const handshake_packet = try cl.readHandshakePacket(mcp.H.SB, alloc);
    std.log.info("handshake: {any}", .{handshake_packet});
    if (handshake_packet == .legacy) {
        std.log.info("legacy ping...", .{});
        return;
    }
    switch (handshake_packet.handshake.next_state) {
        .Status => try handleStatus(alloc, &cl),
        .Login => {
            if (handshake_packet.handshake.protocol_version != @as(i32, mcp.PROTOCOL_VERSION)) {
                defer cl.close();
                try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .disconnect = "{\"text\":\"Incorrect protocol version; this server is on " ++ std.fmt.comptimePrint("{}", .{mcp.PROTOCOL_VERSION}) ++ ".\"}" });
            } else {
                try handleLogin(alloc, game, &cl);
            }
        },
    }
}

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
pub const Player = struct {
    eid: i32,
    uuid: Uuid,
    username: []const u8,

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

    pub fn run(self: *Player, alloc: Allocator, game: *Game) void {
        defer alloc.destroy(self);
        defer alloc.free(self.username);
        defer self.alive.store(false, .Unordered);
        defer {
            game.returnEid(self.eid) catch |err| {
                log.err("lost eid {}: {any}", .{ self.eid, err });
            };
        }
        self.reader_lock.lock();
        while (self.alive.load(.Unordered)) {
            const packet = self.inner.readPacket(mcp.P.SB, alloc) catch |err| {
                if (err == error.EndOfStream) {
                    log.info("closing client", .{});
                    break;
                }
                log.err("failed to read packet: {any}", .{err});
                continue;
            };
            defer mcp.P.SB.deinit(packet, alloc);
            self.reader_lock.unlock();

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
                else => log.info("got packet {any}", .{packet}),
            }

            self.reader_lock.lock();
        }
        self.reader_lock.unlock();
        game.players_lock.lock();
        for (game.players.items) |player, i| {
            if (player == self) {
                _ = game.players.swapRemove(i);
                break;
            }
        }
        game.players_lock.unlock();
    }
    pub fn sendKick(self: *Player, reason: PlayerKickReason) !void {
        const message = switch (reason) {
            .Custom => |m| m,
            .TimedOut => "{\"text\":\"Timed out!\"}",
            .Kicked => "{\"text\":\"Kicked!\"}",
        };
        try self.inner.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .disconnect = message });
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
                const max_dist_changed = math.max3(math.absFloat(nd.x - ld.x), math.absFloat(nd.y - ld.y), math.absFloat(nd.z - ld.z));
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
    pub fn returnEid(self: *Game, eid: i32) !void {
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

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    var game = Game{
        .alloc = alloc,
        .players = std.ArrayList(*Player).init(alloc),
        .alive = atomic.Atomic(bool).init(true),
        .available_eids = std.ArrayList(i32).init(alloc),
    };
    var game_thread = try Thread.spawn(.{}, Game.run, .{&game});
    game_thread.detach();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25400);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(address);
    std.log.info("listening", .{});
    while (true) {
        const conn = try server.accept();

        handleClient(alloc, &game, conn) catch |err| {
            if (err != error.EndOfStream) {
                std.log.err("failed to handle client: {}", .{err});
            }
        };
    }
}
