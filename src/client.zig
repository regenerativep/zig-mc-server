const std = @import("std");
const net = std.net;
const io = std.io;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const Value = std.atomic.Value;
const testing = std.testing;

const xev = @import("xev");

const Mpsc = @import("mpsc");

const mcp = @import("mcp");
const mcio = mcp.packetio;
const mcv = mcp.vlatest;

const VarI32SM = mcp.varint.VarIntSM(i32);
const VarI32 = mcp.varint.VarInt(i32);

const Server = @import("lib.zig").Server;
const ChunkPosition = @import("lib.zig").ChunkPosition;
const ChunkColumn = @import("lib.zig").ChunkColumn;
const Position = @import("lib.zig").Position;
const Entity = @import("entity.zig");

const XevClient = @import("xevclient.zig").XevClient;

const DefaultRegistry = @import("registry.zig").DefaultRegistry;

const Spsc = @import("spsc.zig").Spsc;
const QueuedSpsc = @import("spsc.zig").QueuedSpsc;

const Client = @This();

pub const PacketSM = union(enum) {
    waiting: struct {
        len: VarI32SM = .{},
    },
    reading: struct {
        read_len: usize,
        data: []u8,
    },
    ready: struct {
        data: []u8,
    },

    pub fn feed(self: *PacketSM, a: Allocator, b: u8) !void {
        switch (self.*) {
            .waiting => |*d| {
                if (try d.len.feed(b)) |result| {
                    const len = std.math.cast(usize, result) orelse
                        return error.InvalidCast;
                    self.* = .{ .reading = .{
                        .read_len = 0,
                        .data = try a.alloc(u8, len),
                    } };
                }
            },
            .reading => |*d| {
                d.data[d.read_len] = b;
                d.read_len += 1;
                if (d.read_len == d.data.len) {
                    const data = d.data;
                    self.* = .{ .ready = .{ .data = data } };
                }
            },
            .ready => unreachable,
        }
    }

    pub fn deinit(self: *PacketSM, a: Allocator) void {
        switch (self.*) {
            inline .reading, .ready => |d| a.free(d.data),
            else => {},
        }
        self.* = undefined;
    }
};

pub const VisibleChunks = struct {
    pub const Rect = struct {
        a: ChunkPosition,
        b: ChunkPosition,

        pub fn contains(self: Rect, pos: ChunkPosition) bool {
            return pos.x >= self.a.x and pos.z >= self.a.z and
                pos.x < self.b.x and pos.z < self.b.z;
        }

        /// iterator that starts from the center of the rectangle and moves outward
        pub const Iterator = struct {
            rect: Rect,
            center: ChunkPosition,
            i: usize = 0,
            until: usize,

            fn getRing(i_: usize) struct { isize, isize } {
                var i = i_;
                if (i < 1) return .{ 0, 0 };
                i -= 1;
                var j: usize = 1;
                while (i >= j * 8) {
                    i -= j * 8;
                    j += 1;
                }
                return .{ @intCast(j), @intCast(i) };
            }
            pub fn next(self: *Iterator) ?ChunkPosition {
                if (self.i >= self.until) return null;

                const ring, var ring_i = getRing(self.i);
                self.i += 1;

                if (ring == 0) return self.center;
                if (ring_i < ring * 2 + 1) {
                    return .{
                        .x = self.center.x - ring + ring_i,
                        .z = self.center.z + ring,
                    };
                }
                ring_i -= ring * 2 + 1;
                if (ring_i < ring * 2) {
                    return .{
                        .x = self.center.x + ring,
                        .z = self.center.z - ring + ring_i,
                    };
                }
                ring_i -= ring * 2;
                if (ring_i < ring * 2) {
                    return .{
                        .x = self.center.x - ring + ring_i,
                        .z = self.center.z - ring,
                    };
                }
                ring_i -= ring * 2;
                return .{
                    .x = self.center.x - ring,
                    .z = self.center.z - ring + 1 + ring_i,
                };
            }
        };

        pub fn iterator(self: Rect) Iterator {
            return .{
                .rect = self,
                .center = .{
                    .x = @divTrunc(self.a.x + self.b.x, 2),
                    .z = @divTrunc(self.a.z + self.b.z, 2),
                },
                .until = @intCast((self.b.x - self.a.x) * (self.b.z - self.a.z)),
            };
        }
    };

    last: ?struct {
        rect: Rect,
        pos: ChunkPosition,
    } = null,

    buffer: std.ArrayListUnmanaged(ChunkPosition) = .{},

    pub fn getChunkPosition(pos: Position) ChunkPosition {
        return .{
            .x = @intCast(@as(i64, @intFromFloat(pos.x)) >> 4),
            .z = @intCast(@as(i64, @intFromFloat(pos.z)) >> 4),
        };
    }
    pub fn getRect(pos: ChunkPosition, radius_: usize) Rect {
        const radius = @as(isize, @intCast(radius_));
        return .{
            .a = .{
                .x = pos.x - radius,
                .z = pos.z - radius,
            },
            .b = .{
                .x = pos.x + radius + 1,
                .z = pos.z + radius + 1,
            },
        };
    }

    /// uses internal buffer for return values
    pub fn move(
        self: *VisibleChunks,
        a: Allocator,
        new_position: ChunkPosition,
        view_distance: usize,
    ) !struct {
        new: []const ChunkPosition,
        remove: []const ChunkPosition,
    } {
        const rect = getRect(new_position, view_distance);
        defer self.last = .{ .rect = rect, .pos = new_position };
        self.buffer.clearRetainingCapacity();
        if (self.last) |last| {
            if (std.meta.eql(last.pos, new_position))
                return .{ .new = &.{}, .remove = &.{} };

            try self.buffer.ensureTotalCapacity(a, @intCast(
                (rect.b.x - rect.a.x) * (rect.b.z - rect.a.z) +
                    (last.rect.b.x - last.rect.a.x) * (last.rect.b.z - last.rect.a.z),
            ));

            {
                var iter = rect.iterator();
                while (iter.next()) |pos| {
                    if (!last.rect.contains(pos))
                        self.buffer.appendAssumeCapacity(pos);
                }
            }
            const new_len = self.buffer.items.len;

            {
                var iter = last.rect.iterator();
                while (iter.next()) |pos| {
                    if (!rect.contains(pos))
                        self.buffer.appendAssumeCapacity(pos);
                }
            }
            return .{
                .new = self.buffer.items[0..new_len],
                .remove = self.buffer.items[new_len..],
            };
        } else {
            try self.buffer.ensureTotalCapacity(a, @intCast(
                (rect.b.x - rect.a.x) * (rect.b.z - rect.a.z),
            ));
            {
                var iter = rect.iterator();
                while (iter.next()) |pos| {
                    self.buffer.appendAssumeCapacity(pos);
                }
            }
            return .{ .new = self.buffer.items, .remove = &.{} };
        }
    }
    pub fn deinit(self: *VisibleChunks, a: Allocator) void {
        self.buffer.deinit(a);
        self.* = undefined;
    }
};

pub const WriteBuffer = std.fifo.LinearFifo(u8, .Dynamic);
pub const SendBuffer = std.fifo.LinearFifo(u8, .{ .Static = 1024 });
pub const ChunksToLoad = std.fifo.LinearFifo(*ChunkColumn, .Dynamic);

pub const NullKeepAlive = std.math.maxInt(i64);

id: usize,
cleanup: Server.Message = undefined,

inner: XevClient(struct {
    pub fn onRead(self_: anytype, data: []const u8) void {
        const self = @fieldParentPtr(Client, "inner", self_);
        if (data.len == 0) {
            if (self.inner.recv_error) |e| {
                std.log.err("Read error to {}: \"{}\"", .{ self.address, e });
            } else {}
        } else {
            self.updateState(data) catch |e| {
                std.log.err("Error reading data from {}: \"{}\"", .{ self.address, e });
            };
        }
    }

    pub fn onClose(self_: anytype) void {
        const self = @fieldParentPtr(Client, "inner", self_);

        std.log.debug("Connection to {} closed", .{self.address});

        // client's cleanup must succeed in sending a message to server,
        //     therefore it will use a node within the client rather than
        //     risk allocating one
        self.cleanup = .{ .data = .{ .client_closed = .{ .client = self } } };
        self.server.messages.push(&self.cleanup.node);
    }
}),
address: net.Address,

server: *Server,

/// recv thread only
packet: PacketSM = .{ .waiting = .{} },
// TODO: state may need to be a locked value, not an atomic. at the moment, it is not
//     an issue because once state is play, it doesnt change. but if we ever switch back
//     to configuration state (or if we make the configuration state more complex),
//     usage of state must block others waiting to do things based on it
/// modified by recv thread only
/// readable outside of recv thread
state: Value(enum(u8) {
    handshake,
    status,
    login,
    configuration,
    play,
}) = .{ .raw = .handshake },
/// recv thread only
arena: std.heap.ArenaAllocator,

/// locked by `lock`
visible_chunks: VisibleChunks = .{},

/// accessed only during tick
chunks_to_load: ChunksToLoad,

desired_chunks_per_tick: usize = 25,
initial_chunks: ?usize = null,

/// write: keepalive thread
/// read: recv thread
keep_alives: Spsc(i64, math.log2_int_ceil(usize, Server.MaxKeepAlives)) = .{},
// doing `NullKeepAlive` cause im guessing ?i64 is not suitable for atomics
oldest_keep_alive: std.atomic.Value(i64) = .{ .raw = NullKeepAlive },

lock: std.Thread.RwLock = .{},
/// lock `lock`
next_teleport_id: i32 = 1,
name: []const u8 = "",
entity: ?*Entity = null,
info: ?mcv.ClientInformation.UT = null,

preloaded_messages: std.ArrayListUnmanaged(*Server.Message) = .{},
preloaded_messages_lock: std.Thread.RwLock = .{},

pub fn init(
    self: *Client,
    id: usize,
    stream: net.Stream,
    address: net.Address,
    server: *Server,
) void {
    self.* = .{
        .id = id,
        .inner = undefined,
        .address = address,
        .server = server,
        .arena = std.heap.ArenaAllocator.init(server.allocator),
        .chunks_to_load = ChunksToLoad.init(server.allocator),
    };
    self.inner.init(&server.loop, stream);
}

/// Gets a server message node preferably from our local preload, but will lock and get
/// more from server when necessary
pub fn getMessage(self: *Client) !*Server.Message {
    {
        self.preloaded_messages_lock.lockShared();
        defer self.preloaded_messages_lock.unlockShared();
        if (self.preloaded_messages.popOrNull()) |n| return n;
    }
    {
        self.preloaded_messages_lock.lock();
        defer self.preloaded_messages_lock.unlock();
        self.server.message_pool_lock.lock();
        defer self.server.message_pool_lock.unlock();
        // TODO: find a better way to preload
        if (self.preloaded_messages.capacity == 0) {
            try self.preloaded_messages.ensureTotalCapacity(self.server.allocator, 16);
        }
        for (self.preloaded_messages.addManyAsSliceAssumeCapacity(
            self.preloaded_messages.capacity,
        )) |*n| {
            n.* = try self.server.message_pool.create();
        }
        return self.preloaded_messages.pop();
    }
}

pub fn updateState(self: *Client, data: []const u8) !void {
    const ar = self.arena.allocator();
    for (data) |b| {
        try self.packet.feed(ar, b);
        if (self.packet == .ready) {
            defer {
                self.packet = .{ .waiting = .{} };
                _ = self.arena.reset(.retain_capacity);
            }
            var stream = io.fixedBufferStream(self.packet.ready.data);
            const reader = stream.reader();
            switch (self.state.load(.Acquire)) {
                .handshake => {
                    var packet: mcv.H.SB.UT = undefined;
                    try mcv.H.SB.read(reader, &packet, ar);
                    if (packet != .handshake) return;
                    switch (packet.handshake.next_state) {
                        .status => {
                            self.state.store(.status, .Release);
                        },
                        .login => {
                            self.state.store(.login, .Release);
                        },
                    }
                },
                .status => {
                    var packet: mcv.S.SB.UT = undefined;
                    try mcv.S.SB.read(reader, &packet, ar);
                    switch (packet) {
                        .status_request => {
                            const response_data =
                                \\{
                                \\    "version": {
                                \\        "name": "
                            ++ mcv.MCVersion ++
                                \\",
                                \\        "protocol":
                            ++ std.fmt.comptimePrint(
                                "{}",
                                .{mcv.ProtocolVersion},
                            ) ++
                                \\    },
                                \\    "players": {
                                \\        "max": 32,
                                \\        "online": 0
                                \\    },
                                \\    "description": {
                                \\        "text": "bad minecraft server"
                                \\    }
                                \\}
                            ;
                            try self.sendPacket(mcv.S.CB, .{
                                .status_response = response_data,
                            });
                        },
                        .ping_request => |d| {
                            try self.sendPacket(mcv.S.CB, .{ .ping_response = d });
                            self.stop();
                        },
                    }
                },
                .login => {
                    var packet: mcv.L.SB.UT = undefined;
                    try mcv.L.SB.read(reader, &packet, ar);
                    switch (packet) {
                        .login_start => |d| {
                            self.name = try self.server.allocator.dupe(u8, d.name);

                            self.server.options_lock.lockShared();
                            defer self.server.options_lock.unlockShared();
                            const entity = try self.server.addEntity(
                                self.server.spawn_position,
                                mcv.Uuid.fromUsername(self.name),
                            );
                            self.entity = entity;

                            try self.sendPacket(mcv.L.CB, .{ .login_success = .{
                                .uuid = entity.uuid,
                                .username = self.name,
                                .properties = &.{},
                            } });
                        },
                        .login_acknowledged => {
                            self.state.store(.configuration, .Release);

                            try self.sendPacket(mcv.C.CB, .{ .plugin_message = .{
                                .channel = "minecraft:brand",
                                .data = "\x08bluanfah",
                            } });
                            try self.sendPacket(mcv.C.CB, .{
                                .feature_flags = &.{
                                    .vanilla,
                                },
                            });

                            try self.sendPacket(mcv.C.CB, .{
                                .registry_data = DefaultRegistry,
                            });
                            // TODO: tags
                            try self.sendPacket(mcv.C.CB, .{ .update_tags = &.{
                                .{ .tag_type = .biome, .tags = &.{} },
                                .{ .tag_type = .instrument, .tags = &.{} },
                                .{ .tag_type = .point_of_interest_type, .tags = &.{} },
                                .{ .tag_type = .entity_type, .tags = &.{} },
                                .{ .tag_type = .cat_variant, .tags = &.{} },
                                .{ .tag_type = .painting_variant, .tags = &.{} },
                                .{ .tag_type = .game_event, .tags = &.{} },
                                .{ .tag_type = .block, .tags = &.{} },
                                .{ .tag_type = .item, .tags = &.{} },
                                .{ .tag_type = .banner_pattern, .tags = &.{} },
                                .{ .tag_type = .damage_type, .tags = &.{} },
                                .{ .tag_type = .fluid, .tags = &.{
                                    .{
                                        .tag_name = "minecraft:lava",
                                        .entries = &.{ 4, 3 },
                                    },
                                    .{
                                        .tag_name = "minecraft:water",
                                        .entries = &.{ 2, 1 },
                                    },
                                } },
                            } });

                            try self.sendPacket(mcv.C.CB, .finish_configuration);
                        },
                        else => {},
                    }
                },
                .configuration => {
                    var packet: mcv.C.SB.UT = undefined;
                    try mcv.C.SB.read(reader, &packet, ar);
                    //std.debug.print("read packet \"{s}\"\n", .{@tagName(packet)});
                    switch (packet) {
                        .client_information => |d| {
                            const locale = try self.server.allocator.dupe(
                                u8,
                                d.locale,
                            );
                            self.info = d;
                            self.info.?.locale = locale;
                        },
                        .plugin_message => {},
                        .finish_configuration => {
                            self.state.store(.play, .Release);

                            self.lock.lock();
                            defer self.lock.unlock();

                            try self.sendPacket(mcv.P.CB, .{
                                .login = .{
                                    .entity_id = @intCast(self.entity.?.id),
                                    // TODO: make these values less hardcoded
                                    .is_hardcore = false,
                                    .dimensions = &.{.overworld},
                                    .max_players = 32,
                                    .view_distance = 8,
                                    .simulation_distance = 8,
                                    .reduced_debug_info = false,
                                    .enable_respawn_screen = true,
                                    .do_limited_crafting = false,
                                    .respawn = .{
                                        .dimension_type = "minecraft:overworld",
                                        .dimension_name = .overworld,
                                        .hashed_seed = 12345,
                                        .gamemode = .creative,
                                        .previous_gamemode = null,
                                        .is_debug = false,
                                        .is_flat = true,
                                        .death_location = null,
                                        .portal_cooldown = 0,
                                    },
                                },
                            });
                            try self.sendPacket(mcv.P.CB, .{ .change_difficulty = .{
                                .difficulty = .peaceful,
                                .locked = true,
                            } });
                            try self.sendPacket(mcv.P.CB, .{ .player_abilities = .{
                                .flags = .{
                                    .invulnerable = true,
                                    .flying = false,
                                    .allow_flying = true,
                                    .creative_mode = true,
                                },
                                .flying_speed = 0.05,
                                .fov_modifier = 0.1,
                            } });
                            try self.sendPacket(mcv.P.CB, .{ .set_held_item = .{
                                .slot = 0,
                            } });
                            // TODO update_recipes, item gen
                            try self.sendPacket(mcv.P.CB, .{ .update_recipes = &.{.{
                                .m = "minecraft:crafting_table",
                                .t = .{ .crafting_shaped = .{
                                    .width = 2,
                                    .height = 2,
                                    .group = "",
                                    .category = .misc,
                                    .ingredients = &(.{&.{.{
                                        .item_id = 23,
                                        .item_count = 1,
                                        .data = null,
                                    }}} ** 4),
                                    .result = .{
                                        .item_id = 278,
                                        .item_count = 1,
                                        .data = null,
                                    },
                                    .show_notification = false,
                                } },
                            }} });

                            try self.sendPacket(mcv.P.CB, .{ .entity_event = .{
                                .entity_id = @intCast(self.entity.?.id),
                                .entity_status = .op_permission_0,
                            } });
                            try self.sendPacket(mcv.P.CB, .{ .commands = .{
                                .root_index = 0,
                                .nodes = &.{.{
                                    .children = &.{},
                                    .data = .root,
                                    .is_executable = false,
                                    .redirect_node = null,
                                    .suggestion = null,
                                }},
                            } });
                            try self.sendPacket(mcv.P.CB, .{
                                .update_recipe_book = .{
                                    .init = .{
                                        .book = .{
                                            .crafting = .{
                                                .open = false,
                                                .filter = false,
                                            },
                                            .smelting = .{
                                                .open = false,
                                                .filter = false,
                                            },
                                            .blast_furnace = .{
                                                .open = false,
                                                .filter = false,
                                            },
                                            .smoker = .{
                                                .open = false,
                                                .filter = false,
                                            },
                                        },
                                        .recipe_ids_1 = &.{"minecraft:crafting_table"},
                                        .recipe_ids_2 = &.{"minecraft:crafting_table"},
                                    },
                                },
                            });

                            if (self.entity) |entity| {
                                entity.lock.lockShared();
                                defer entity.lock.unlockShared();
                                try self.sendPacket(mcv.P.CB, .{
                                    .synchronize_player_position = .{
                                        .position = .{
                                            .x = entity.position.x,
                                            .y = entity.position.y,
                                            .z = entity.position.z,
                                        },
                                        .yaw = entity.yaw,
                                        .pitch = entity.pitch,
                                        .relative = .{
                                            .x = false,
                                            .y = false,
                                            .z = false,
                                            .pitch = false,
                                            .yaw = false,
                                        },
                                        // TODO: queue teleports
                                        .teleport_id = self.next_teleport_id,
                                    },
                                });
                                self.next_teleport_id += 1;

                                const other_players = blk: {
                                    self.server.clients_lock.lockShared();
                                    defer self.server.clients_lock.unlockShared();

                                    var actions = try ar.alloc(
                                        mcv.PlayerInfoUpdate.PlayerAction,
                                        self.server.clients.count(),
                                    );
                                    var i: usize = 0;
                                    var iter = self.server.clients.iterator(0);
                                    while (iter.next()) |cl| if (cl.canSendPlay()) {
                                        // send new player info to every player
                                        try cl.sendPacket(mcv.P.CB, .{
                                            .player_info_update = .{
                                                .actions = .{
                                                    .add_player = true,
                                                    .initialize_chat = true,
                                                    .update_gamemode = true,
                                                    .update_listed = true,
                                                    .update_latency = true,
                                                    .update_display_name = true,
                                                },
                                                .player_actions = &.{.{
                                                    .uuid = entity.uuid,
                                                    .add_player = .{
                                                        .name = self.name,
                                                        .properties = &.{},
                                                    },
                                                    .initialize_chat = @as(
                                                        mcv.PlayerInfoUpdate
                                                            .InitializeChatSpec.UT,
                                                        null,
                                                    ),
                                                    .update_gamemode = .creative,
                                                    .update_listed = true,
                                                    .update_latency = 0,
                                                    .update_display_name = @as(
                                                        mcv.PlayerInfoUpdate
                                                            .UpdateDisplayNameSpec.UT,
                                                        null,
                                                    ),
                                                }},
                                            },
                                        });

                                        // dont add self to list of all players
                                        if (cl == self) continue;

                                        cl.lock.lockShared();
                                        defer cl.lock.unlockShared();

                                        actions[i] = .{
                                            .uuid = if (cl.entity) |e| blk2: {
                                                e.lock.lockShared();
                                                defer e.lock.unlockShared();
                                                break :blk2 e.uuid;
                                            } else mem.zeroes(mcv.Uuid.UT),
                                            .add_player = .{
                                                .name = cl.name,
                                                .properties = &.{},
                                            },
                                            .initialize_chat = @as(
                                                mcv.PlayerInfoUpdate
                                                    .InitializeChatSpec.UT,
                                                null,
                                            ),
                                            .update_gamemode = .creative,
                                            .update_listed = true,
                                            .update_latency = 0,
                                            .update_display_name = @as(
                                                mcv.PlayerInfoUpdate
                                                    .UpdateDisplayNameSpec.UT,
                                                null,
                                            ),
                                        };
                                        i += 1;
                                    };
                                    break :blk actions[0..i];
                                };

                                try self.sendPacket(mcv.P.CB, .{
                                    .player_info_update = .{
                                        .actions = .{
                                            .add_player = true,
                                            .initialize_chat = true,
                                            .update_gamemode = true,
                                            .update_listed = true,
                                            .update_latency = true,
                                            .update_display_name = true,
                                        },
                                        .player_actions = other_players,
                                    },
                                });

                                // send entity spawn to other clients
                                var iter = self.server.clients.iterator(0);
                                while (iter.next()) |cl| {
                                    if (cl != self and cl.canSendPlay()) {
                                        try entity.sendSpawn(cl);
                                    }
                                }
                            }

                            try self.sendPacket(mcv.P.CB, .{ .server_data = .{
                                .motd = .{ .string = "wait dont go, come back!" },
                                .icon = null,
                                .enforces_secure_chat = false,
                            } });

                            try self.sendPacket(mcv.P.CB, .{ .world_border_init = .{
                                .x = 0,
                                .z = 0,
                                .old_diameter = 4096,
                                .new_diameter = 4096,
                                .speed = 0,
                                .portal_teleport_boundary = 29999984,
                                .warning_blocks = 8,
                                .warning_time = 0,
                            } });
                            const current_tick =
                                self.server.current_tick.load(.Monotonic);
                            try self.sendPacket(mcv.P.CB, .{ .update_time = .{
                                .world_age = @intCast(current_tick),
                                .time_of_day = @intCast(current_tick),
                            } });
                            // TODO: update_time all the other times in the future

                            {
                                self.server.options_lock.lockShared();
                                defer self.server.options_lock.unlockShared();
                                try self.sendPacket(mcv.P.CB, .{
                                    .set_default_spawn_position = .{
                                        .location = .{
                                            .y = @intFromFloat(
                                                self.server.spawn_position.y,
                                            ),
                                            .z = @intFromFloat(
                                                self.server.spawn_position.z,
                                            ),
                                            .x = @intFromFloat(
                                                self.server.spawn_position.x,
                                            ),
                                        },
                                        .angle = 0,
                                    },
                                });
                            }
                            // TODO: view distance
                            self.initial_chunks = (8 + 8 + 1) * (8 + 8 + 1);
                            try self.sendChunks(true);
                        },
                        .keep_alive => |d| self.receiveKeepAlive(d),
                        else => {},
                    }
                },
                .play => {
                    var packet: mcv.P.SB.UT = undefined;
                    try mcv.P.SB.read(reader, &packet, ar);
                    //std.debug.print("read packet \"{s}\"\n", .{@tagName(packet)});

                    switch (packet) {
                        .chunk_batch_received => |d| {
                            self.desired_chunks_per_tick =
                                math.lossyCast(usize, math.ceil(d.chunks_per_tick));
                        },
                        .keep_alive => |d| self.receiveKeepAlive(d),
                        inline .set_player_position,
                        .set_player_rotation,
                        .set_player_position_and_rotation,
                        .set_player_on_ground,
                        => |d, v| {
                            self.lock.lockShared();
                            defer self.lock.unlockShared();
                            if (self.entity) |entity| {
                                entity.lock.lockShared();
                                defer entity.lock.unlockShared();
                                switch (v) {
                                    .set_player_position,
                                    .set_player_position_and_rotation,
                                    => entity.position = .{
                                        .x = d.x,
                                        .y = d.feet_y,
                                        .z = d.z,
                                    },
                                    else => {},
                                }
                                switch (v) {
                                    .set_player_rotation,
                                    .set_player_position_and_rotation,
                                    => {
                                        entity.yaw = d.yaw;
                                        entity.pitch = d.pitch;
                                    },
                                    else => {},
                                }
                                entity.on_ground = d.on_ground;
                            }
                        },
                        .chat_message => |d| {
                            const msg = try self.getMessage();
                            // TODO: don't allocate every message
                            msg.* = .{ .data = .{ .chat_message = .{
                                .sender = self,
                                .message = try self.server.allocator
                                    .dupe(u8, d.message),
                            } } };
                            self.server.messages.push(&msg.node);
                        },
                        else => {
                            std.log.debug(
                                "Unhandled packet \"{s}\"",
                                .{@tagName(packet)},
                            );
                        },
                    }
                },
            }
        }
    }
}

pub fn receiveKeepAlive(self: *Client, value: i64) void {
    while (true) {
        if (self.keep_alives.depeek()) |v| {
            if (v.* <= value) {
                _ = self.keep_alives.dequeue();
                continue;
            } else {
                self.oldest_keep_alive.store(v.*, .Release);
                break;
            }
        } else {
            self.oldest_keep_alive.store(NullKeepAlive, .Release);
            break;
        }
    }
}

pub fn tick(self: *Client) !void {
    if (!self.canSendPlay()) return;

    try self.sendPacket(mcv.P.CB, .bundle_delimeter);

    try self.sendChunks(true);

    // chunks_to_load only modified here and in server's tick call (not on another
    //     thread)
    if (self.chunks_to_load.count > 0) {
        const total_chunks_to_load = blk: {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            break :blk @min(
                self.desired_chunks_per_tick,
                self.chunks_to_load.count,
            );
        };

        try self.sendPacket(mcv.P.CB, .chunk_batch_start);

        var chunks_loaded: usize = 0;
        while (chunks_loaded < total_chunks_to_load) : (chunks_loaded += 1) {
            const chunk = self.chunks_to_load.readItem() orelse break;

            chunk.lock.lock();
            defer chunk.lock.unlock();

            try self.sendPacket(mcv.P.CB, .{
                .chunk_data_and_update_light = .{
                    .chunk_x = @intCast(chunk.position.x),
                    .chunk_z = @intCast(chunk.position.z),
                    .heightmaps = .{
                        .motion_blocking = chunk.inner.motion_blocking,
                        .world_surface = chunk.inner.world_surface,
                    },
                    .data = &chunk.inner.sections,
                    .block_entities = &.{},
                    .light_levels = chunk.inner.light_levels,
                },
            });
        }

        if (self.initial_chunks) |*initial_chunks| {
            if (total_chunks_to_load >= initial_chunks.*) {
                self.initial_chunks = null;

                self.lock.lockShared();
                defer self.lock.unlockShared();
                if (self.entity) |entity| {
                    entity.lock.lockShared();
                    defer entity.lock.unlockShared();
                    const current_chunk_pos =
                        VisibleChunks.getChunkPosition(entity.position);
                    try self.sendPacket(mcv.P.CB, .{ .set_center_chunk = .{
                        .chunk_x = @intCast(current_chunk_pos.x),
                        .chunk_z = @intCast(current_chunk_pos.z),
                    } });
                    try self.sendPacket(mcv.P.CB, .{
                        .synchronize_player_position = .{
                            .position = .{
                                .x = entity.position.x,
                                .y = entity.position.y,
                                .z = entity.position.z,
                            },
                            .yaw = entity.yaw,
                            .pitch = entity.pitch,
                            .relative = .{
                                .x = false,
                                .y = false,
                                .z = false,
                                .pitch = false,
                                .yaw = false,
                            },
                            // TODO: queue teleports
                            .teleport_id = self.next_teleport_id,
                        },
                    });
                    self.next_teleport_id += 1;
                }
                {
                    self.server.options_lock.lockShared();
                    defer self.server.options_lock.unlockShared();
                    std.debug.print("sent initial chunks\n", .{});
                    try self.sendPacket(mcv.P.CB, .{
                        .set_default_spawn_position = .{
                            .location = .{
                                .y = @intFromFloat(
                                    self.server.spawn_position.y,
                                ),
                                .z = @intFromFloat(
                                    self.server.spawn_position.z,
                                ),
                                .x = @intFromFloat(
                                    self.server.spawn_position.x,
                                ),
                            },
                            .angle = 0,
                        },
                    });
                }

                try self.sendPacket(mcv.P.CB, .{ .game_event = .{
                    .start_waiting_for_level_chunks = 0,
                } });
                try self.sendPacket(mcv.P.CB, .{ .set_ticking_state = .{
                    .tick_rate = @floatFromInt(
                        self.server.target_tps.load(.Acquire),
                    ),
                    .is_frozen = false,
                } });
                try self.sendPacket(mcv.P.CB, .{ .step_tick = 0 });

                {
                    self.server.clients_lock.lockShared();
                    defer self.server.clients_lock.unlockShared();
                    // send all other client entities to client
                    var iter = self.server.clients.iterator(0);
                    while (iter.next()) |cl| {
                        if (cl != self and cl.canSendPlay()) {
                            cl.lock.lockShared();
                            defer cl.lock.unlockShared();
                            if (cl.entity) |e| {
                                e.lock.lockShared();
                                defer e.lock.unlockShared();
                                try e.sendSpawn(self);
                            }
                        }
                    }
                }
            } else {
                initial_chunks.* -= total_chunks_to_load;
            }
        }
        try self.sendPacket(mcv.P.CB, .{
            .chunk_batch_finished = @intCast(total_chunks_to_load),
        });
    }
}

// TODO: we probably dont need this?
pub fn SilentWriter(comptime WriterType: type) type {
    return struct {
        err: ?WriterType.Error = null,
        inner: WriterType,

        const Self = @This();
        pub const Error = error{};
        pub const Writer = io.Writer(*Self, Error, write);

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (self.err != null) return bytes.len;
            self.inner.write(bytes) catch |e| {
                self.inner = e;
                return bytes.len;
            };
        }
    };
}

pub fn silentWriter(writer: anytype) SilentWriter(@TypeOf(writer)) {
    return .{ .inner = writer };
}

pub fn sendPacket(self: *Client, comptime ST: type, packet: ST.UT) !void {
    const payload_size = ST.size(packet);
    const packet_size = payload_size + VarI32.size(@intCast(payload_size));
    //if (ST != mcv.P.CB or packet != .bundle_delimeter) {
    //std.debug.print(
    //    "writing packet \"{s}\" ({}, {})\n",
    //    .{
    //        @tagName(packet),
    //        packet_size,
    //        payload_size,
    //    },
    //);
    //}
    {
        self.inner.buffer.swap_lock.lockShared();
        defer self.inner.buffer.swap_lock.unlockShared();
        const current_buffer = self.inner.buffer.nonActiveBuffer();
        current_buffer.lock.lock();
        defer current_buffer.lock.unlock();
        const buf =
            try current_buffer.data.addManyAsSlice(self.server.allocator, packet_size);
        var stream = std.io.fixedBufferStream(buf);
        const silent_writer = silentWriter(stream.writer());
        const writer = stream.writer();

        VarI32.write(writer, @intCast(payload_size)) catch unreachable;
        ST.write(writer, packet) catch unreachable;

        if (silent_writer.err) |e| {
            if (e == error.NoSpaceLeft) {
                std.log.err(
                    "Just sent too-full packet! ({}) Bug in serialization code?",
                    .{buf.len},
                );
            } else {
                return e;
            }
        }

        if (stream.pos < stream.buffer.len) {
            std.log.err("Just sent non-full packet! Bug in serialization code?", .{});
            try writer.writeByteNTimes(0xAA, stream.buffer.len - stream.pos);
        }
    }
    self.inner.submitSend(&self.server.loop);
}

/// TODO: this is more like request rather than send
/// self.lock should be locked
pub fn sendChunks(self: *Client, send_center: bool) !void {
    const res = blk: {
        if (self.entity == null) return;
        self.entity.?.lock.lockShared();
        defer self.entity.?.lock.unlockShared();

        const current_chunk_pos =
            VisibleChunks.getChunkPosition(self.entity.?.position);
        if (if (self.visible_chunks.last) |last|
            !std.meta.eql(last.pos, current_chunk_pos)
        else
            true)
        {
            if (send_center) try self.sendPacket(mcv.P.CB, .{ .set_center_chunk = .{
                .chunk_x = @intCast(current_chunk_pos.x),
                .chunk_z = @intCast(current_chunk_pos.z),
            } });
        } else {
            // hasnt moved enough. chunk updates should not change
            // TODO: except when view distance changed
            return;
        }
        break :blk try self.visible_chunks.move(
            self.server.allocator,
            current_chunk_pos,
            8, // TODO: view distance
        );
    };
    {
        for (res.new) |pos| {
            const msg = try self.getMessage();
            msg.* = .{ .data = .{ .request_chunk = .{
                .sender = self,
                .position = pos,
            } } };
            self.server.messages.push(&msg.node);
        }
    }
    //for (res.remove) |pos| {
    //    const chunk = try self.server.getChunk(pos);
    //    chunk.lock.lock();
    //    defer chunk.lock.unlock();
    //    chunk.viewers -|= 1; // should not ever sub 1 from 0, but whatever
    // TODO: notify chunk cleanup if viewers == 0

    //try self.sendPacket(mcv.P.CB, .{ .unload_chunk = .{
    //    .chunk_x = @intCast(pos.x),
    //    .chunk_z = @intCast(pos.z),
    //} });
    //}
}

pub fn canSendPlay(self: *const Client) bool {
    return self.inner.canSend() and self.state.load(.Acquire) == .play;
}
pub inline fn readyForCleanup(self: *Client) bool {
    return !self.isAlive();
}
pub inline fn isAlive(self: *const Client) bool {
    return self.inner.isAlive();
}

pub inline fn stop(self: *Client) void {
    self.inner.queueStop(&self.server.loop);
}

pub fn deinit(self: *Client) void {
    // server handles freeing the entity before this fn is called
    {
        self.server.message_pool_lock.lock();
        defer self.server.message_pool_lock.unlock();
        var i = self.preloaded_messages.items.len;
        while (i > 0) {
            i -= 1;
            self.server.message_pool.destroy(self.preloaded_messages.items[i]);
        }
    }
    self.preloaded_messages.deinit(self.server.allocator);
    self.visible_chunks.deinit(self.server.allocator);
    self.chunks_to_load.deinit();
    if (self.info) |inf| self.server.allocator.free(inf.locale);
    if (self.name.len > 0) self.server.allocator.free(self.name);
    self.packet.deinit(self.server.allocator);
    self.arena.deinit();
    self.inner.deinit(self.server.allocator);
    self.* = undefined;
}
