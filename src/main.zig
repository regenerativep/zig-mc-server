const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;

const Uuid = @import("uuid6");

const serde = @import("serde.zig");
const mcp = @import("mcproto.zig");
const mcn = @import("mcnet.zig");
const nbt = @import("nbt.zig");

pub fn handleStatus(alloc: Allocator, cl: anytype) !void {
    const request_packet = try cl.readPacket(mcp.S.SB, alloc);
    defer mcp.S.SB.deinit(request_packet, alloc);
    std.log.info("packet data: {any}", .{request_packet});
    if (request_packet != .Request) {
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
    try cl.writePacket(mcp.S.CB, mcp.S.CB.UserType{ .Response = response_data });
    const ping_packet = try cl.readPacket(mcp.S.SB, alloc);
    defer mcp.S.SB.deinit(ping_packet, alloc);
    if (ping_packet != .Ping) {
        std.log.info("didnt receive a ping", .{});
        return;
    }
    try cl.writePacket(mcp.S.CB, mcp.S.CB.UserType{ .Pong = ping_packet.Ping });
    std.log.info("done", .{});
}

pub fn handleLogin(alloc: Allocator, cl: anytype) !void {
    const login_start_packet = try cl.readPacket(mcp.L.SB, alloc);
    defer mcp.L.SB.deinit(login_start_packet, alloc);
    if (login_start_packet != .LoginStart) {
        std.log.info("didnt receive login start", .{});
        return;
    }
    const username = login_start_packet.LoginStart;
    std.log.info("\"{s}\" trying to connect", .{username});
    const uuid = try mcp.uuidFromUsername(username);
    try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .LoginSuccess = .{ .username = username, .uuid = uuid } });
    // play state now
    const dimension_names = [_][]const u8{
        "minecraft:overworld",
    };
    const eid: i32 = 1;
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{
        .JoinGame = .{
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
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .PluginMessage = .{
        .channel = "minecraft:brand",
        .data = &[_]u8{ 5, 'z', 'i', 'g', 'm', 'c' },
    } });
    std.log.info("sent difficulty", .{});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .ServerDifficulty = .{
        .difficulty = .Peaceful,
        .difficulty_locked = true,
    } });
    std.log.info("sent player abilities", .{});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .PlayerAbilities = .{
        .flags = .{
            .invulnerable = true,
            .flying = false,
            .allow_flying = true,
            .creative_mode = true,
        },
        .flying_speed = 0.05,
        .field_of_view_modifier = 0.1,
    } });
    var packet_res = cl.readPacket(mcp.P.SB, alloc);
    if (meta.isError(packet_res)) {
        _ = packet_res catch |err| return err;
    }
    var packet = packet_res catch unreachable;
    std.log.info("packet {any}", .{packet});
    defer mcp.P.SB.deinit(packet, alloc);
    while (packet != .ClientSettings) {
        if (packet == .PluginMessage) {
            if (std.mem.eql(u8, packet.PluginMessage.channel, "minecraft:brand")) {
                std.log.info("client brand is \"{s}\"", .{packet.PluginMessage.data[1..]});
            }
        } else {
            std.log.info("unexpected packet {any}", .{packet});
        }
        mcp.P.SB.deinit(packet, alloc);
        packet = try cl.readPacket(mcp.P.SB, alloc);
    }
    std.log.info("client settings: {any}", .{packet.ClientSettings});
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .HeldItemChange = 0 });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .DeclareRecipes = &[_]mcp.Recipe{
        .{
            .type = "crafting_shapeless",
            .recipe_id = "minecraft:recipe_flint_and_steel",
            .data = .{ .CraftingShapeless = .{
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
    //    .Tags = &[_]meta.Child(mcp.Tags.UserType){
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
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .EntityStatus = .{ .entity_id = eid, .entity_status = 28 } }); // set op level to 4
    const teleport_id: i32 = 5;
    const pos_and_look = mcp.P.CB.UserType{ .PlayerPositionAndLook = .{
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
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .PlayerInfo = .{
        .AddPlayer = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[0].UserType){
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
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .PlayerInfo = .{
        .UpdateLatency = &[_]meta.Child(mcp.PlayerInfo.UnionType.Specs[2].UserType){
            .{
                .uuid = uuid,
                .data = 0,
            },
        },
    } });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .UpdateViewPosition = .{ .chunk_x = 0, .chunk_z = 0 } });
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
        .ChunkDataAndUpdateLight = .{
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
                        .palette = .{ .Single = 6 }, // andesite
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                    .biomes = .{
                        .bits_per_entry = 0,
                        .palette = .{ .Single = 1 }, // plains?
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                },
            } ++ [_]mcp.ChunkSection.UserType{
                .{
                    .block_count = 0,
                    .block_states = .{
                        .bits_per_entry = 0,
                        .palette = .{ .Single = 0 },
                        .data_array = &[_]mcp.GlobalPaletteInt{},
                    },
                    .biomes = .{
                        .bits_per_entry = 0,
                        .palette = .{ .Single = 1 },
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
            chunk_packet.ChunkDataAndUpdateLight.chunk_x = k;
            chunk_packet.ChunkDataAndUpdateLight.chunk_z = j;
            try cl.writePacket(mcp.P.CB, chunk_packet);
            std.log.info("writing chunk xz: {} {}", .{ k, j });
        }
    }
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .WorldBorderCenter = .{ .x = 0.0, .z = 0.0 } });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .WorldBorderSize = 128.0 });
    try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{ .SpawnPosition = .{
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
    if (teleport_confirm_packet == .TeleportConfirm) {
        std.debug.assert(teleport_confirm_packet.TeleportConfirm == teleport_id);
    } else {
        std.log.info("unexpected packet {any}", .{teleport_confirm_packet});
    }
    const pos_rot_packet = try cl.readPacket(mcp.P.SB, alloc);
    defer mcp.P.SB.deinit(pos_rot_packet, alloc);
    if (pos_rot_packet == .PlayerPositionAndRotation) {
        std.log.info("got pos rot {any}", .{pos_rot_packet});
    } else {
        std.log.info("unexpected packet {any}", .{teleport_confirm_packet});
    }
    while (true) {
        const packet_len = try mcp.VarInt.deserialize(alloc, cl.reader);
        std.log.info("got packet len {}\n", .{packet_len});
        var j: usize = 0;
        while (j < packet_len) : (j += 1) {
            _ = try cl.reader.readByte();
        }
    }
}

pub fn handleClient(alloc: Allocator, conn: net.StreamServer.Connection) !void {
    std.log.info("connection", .{});
    var cl = mcn.packetClient(conn.stream.reader(), conn.stream.writer(), null);
    const handshake_packet = try cl.readHandshakePacket(mcp.H.SB, alloc);
    std.log.info("handshake: {any}", .{handshake_packet});
    if (handshake_packet == .Legacy) {
        std.log.info("legacy ping...", .{});
        return;
    }
    switch (handshake_packet.Handshake.next_state) {
        .Status => try handleStatus(alloc, &cl),
        .Login => {
            if (handshake_packet.Handshake.protocol_version != @as(i32, mcp.PROTOCOL_VERSION)) {
                try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .Disconnect = "{\"text\":\"Incorrect protocol version; this server is on " ++ std.fmt.comptimePrint("{}", .{mcp.PROTOCOL_VERSION}) ++ ".\"}" });
            } else {
                try handleLogin(alloc, &cl);
            }
        },
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25400);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(address);
    std.log.info("listening", .{});
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        handleClient(alloc, conn) catch |err| {
            std.log.err("failed to handle client: {}", .{err});
        };
        std.log.info("closed client", .{});
    }
}
