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
const mcg = @import("game.zig");

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
    try cl.writePacket(mcp.S.CB, .{ .response = response_data });
    const ping_packet = try cl.readPacket(mcp.S.SB, alloc);
    defer mcp.S.SB.deinit(ping_packet, alloc);
    if (ping_packet != .ping) {
        std.log.info("didnt receive a ping", .{});
        return;
    }
    try cl.writePacket(mcp.S.CB, .{ .pong = ping_packet.ping });
    std.log.info("done", .{});
}

pub fn handleLogin(alloc: Allocator, game: *mcg.Game, cl: anytype) !void {
    errdefer cl.close();
    const login_start_packet = try cl.readPacket(mcp.L.SB, alloc);
    defer mcp.L.SB.deinit(login_start_packet, alloc);
    if (login_start_packet != .login_start) {
        std.log.info("didnt receive login start", .{});
        return;
    }
    const username_s = login_start_packet.login_start;
    const username = std.mem.sliceTo(&username_s, 0);
    std.log.info("\"{s}\" trying to connect", .{username});
    const uuid = try mcp.uuidFromUsername(username);
    var can_join: ?[]const u8 = null;
    game.players_lock.lock();
    for (game.players.items) |player| {
        if (std.mem.eql(u8, &player.uuid.bytes, &uuid.bytes)) {
            can_join = "{\"text\":\"You are already in the server\"}";
            break;
        }
    }
    game.players_lock.unlock();
    if (can_join) |kick_msg| {
        try cl.writePacket(mcp.L.CB, .{ .disconnect = kick_msg });
        return error{PlayerAlreadyInServer}.PlayerAlreadyInServer;
    } else {
        log.info("trying to write packet", .{});
        try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .login_success = .{ .username = username_s, .uuid = uuid } });
    }
    log.info("hey 5", .{});
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
    try cl.writePacket(mcp.P.CB, .{
        .plugin_message = .{
            .channel = "minecraft:brand",
            .data = &[_]u8{ 5, 'z', 'i', 'g', 'm', 'c' },
        },
    });
    std.log.info("sent difficulty", .{});
    try cl.writePacket(mcp.P.CB, .{
        .server_difficulty = .{
            .difficulty = .Peaceful,
            .difficulty_locked = true,
        },
    });
    std.log.info("sent player abilities", .{});
    try cl.writePacket(mcp.P.CB, .{
        .player_abilities = .{
            .flags = .{
                .invulnerable = true,
                .flying = false,
                .allow_flying = true,
                .creative_mode = true,
            },
            .flying_speed = 0.05,
            .field_of_view_modifier = 0.1,
        },
    });
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
    const client_settings = packet.client_settings;
    try cl.writePacket(mcp.P.CB, .{ .held_item_change = 0 });
    try cl.writePacket(mcp.P.CB, .{ .declare_recipes = .{
        .{
            .type = "crafting_shapeless",
            .recipe_id = "minecraft:recipe_flint_and_steel",
            .data = .{ .crafting_shapeless = .{
                .group = "steel",
                .ingredients = .{
                    &[_]mcp.Slot.UserType{.{
                        .item_id = 762,
                        .item_count = 1,
                        .nbt = &.{},
                    }},
                    &[_]mcp.Slot.UserType{.{
                        .item_id = 692,
                        .item_count = 1,
                        .nbt = &.{},
                    }},
                },
                .result = .{
                    .item_id = 680,
                    .item_count = 1,
                    .nbt = &.{},
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
    const pos_and_look = .{ .player_position_and_look = .{
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
                    .name = username_s,
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
            var player_username = [_:0]u8{0} ** (16 * 4);
            std.mem.copy(u8, player_username[0..player.username.len], player.username);
            try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .player_info = .{
                .add_player = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[0].UserType){
                    .{
                        .uuid = player.uuid,
                        .data = .{
                            .name = player_username,
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
    try cl.writePacket(mcp.P.CB, .{ .update_view_position = .{ .chunk_x = 0, .chunk_z = 0 } });

    // isnert chunk code here
    var k: i32 = -5;
    while (k <= 5) : (k += 1) {
        var j: i32 = -5;
        while (j <= 5) : (j += 1) {
            const chunk = mcp.chunk.Chunk{
                .chunk_x = k,
                .chunk_z = j,
                .block_entities = .{},
                .sections = mcp.chunk.DEFAULT_FLAT_SECTIONS,
                .height_map = mcp.chunk.Chunk.generateHeightMap(&mcp.chunk.DEFAULT_FLAT_SECTIONS),
            };
            try chunk.send(cl);
            std.log.info("writing chunk xz: {} {}", .{ k, j });
        }
    }
    try cl.writePacket(mcp.P.CB, .{ .world_border_center = .{ .x = 0.0, .z = 0.0 } });
    try cl.writePacket(mcp.P.CB, .{ .world_border_size = 128.0 });
    try cl.writePacket(mcp.P.CB, .{ .spawn_position = .{
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
    var player = try alloc.create(mcg.Player);
    errdefer {
        alloc.destroy(player);
        cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .disconnect = "{\"text\":\"internal error\"}" }) catch |err| {
            log.err("error during player disconnect for internal error: {any}", .{err});
        };
    }
    var alloced_settings = try alloc.create(mcp.ClientSettings.UserType);
    alloced_settings.* = client_settings;
    player.* = mcg.Player{
        .inner = cl.*,
        .eid = eid,
        .uuid = uuid,
        .username = try alloc.dupe(u8, username),
        .settings = .{ .value = alloced_settings },
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
                .name = username_s,
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
    {
        const unfmt_text =
            \\{"text":"","color":"yellow","extra":[{"text":" joined the game","color":"white"}]}
        ;
        var buf: [unfmt_text.len + 64]u8 = undefined;
        const formatted_msg = std.fmt.bufPrint(&buf,
            \\{{"text":"{s}","color":"yellow","extra":[{{"text":" joined the game","color":"white"}}]}}
        , .{username}) catch unreachable; // given that username is max 16 unicode characters, this should never fail
        player.broadcastChatMessage(game, formatted_msg);
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
    const thread = try Thread.spawn(.{}, mcg.Player.run, .{ player, alloc, game });
    thread.detach();
}

pub fn handleClient(alloc: Allocator, game: *mcg.Game, conn: net.StreamServer.Connection) !void {
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
                var buf: [128]u8 = undefined;
                var disconnect_msg = std.fmt.bufPrint(&buf,
                    \\{{"text":"Incorrect protocol version; this server is on {}. You are on {}."}}
                , .{ mcp.PROTOCOL_VERSION, handshake_packet.handshake.protocol_version }) catch
                    \\{"text":"Incorrect protocol version; this server is on
                ++ std.fmt.comptimePrint("{}", .{mcp.PROTOCOL_VERSION}) ++
                    \\"}
                ;
                try cl.writePacket(mcp.L.CB, .{ .disconnect = disconnect_msg });
            } else {
                try handleLogin(alloc, game, &cl);
            }
        },
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    var game = mcg.Game{
        .alloc = alloc,
        .players = std.ArrayList(*mcg.Player).init(alloc),
        .alive = atomic.Atomic(bool).init(true),
        .available_eids = std.ArrayList(i32).init(alloc),
    };
    var game_thread = try Thread.spawn(.{}, mcg.Game.run, .{&game});
    game_thread.detach();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25400);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(address);
    std.log.info("Listening on 127.0.0.1:25400", .{});
    while (true) {
        const conn = try server.accept();

        handleClient(alloc, &game, conn) catch |err| {
            if (err != error.EndOfStream) {
                std.log.err("failed to handle client: {}", .{err});
            }
        };
    }
}
