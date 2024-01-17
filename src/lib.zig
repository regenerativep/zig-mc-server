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

pub const config = @import("config.zig");

pub const Client = @import("client.zig");
pub const Entity = @import("entity.zig");

pub const Command = @import("commands.zig").Command;

test {
    _ = Client;
    _ = Entity;
    _ = config;
    _ = Command;
}

pub const Position = mcv.V3(f64);
pub const ChunkPosition = struct { x: isize, z: isize };

pub const ChunkColumn = struct {
    lock: std.Thread.RwLock = .{},
    position: ChunkPosition,

    inner: mcp.chunk.Column,

    viewers: usize = 0,
};

pub const Server = struct {
    pub const KeepAliveTime = std.time.ms_per_s * 10;
    pub const KeepAliveMaxTime = std.time.ms_per_s * 30;
    pub const MaxKeepAlives = Server.KeepAliveMaxTime / Server.KeepAliveTime + 1;
    pub const CleanupLL = std.SinglyLinkedList(void);

    pub const Message = struct {
        node: Mpsc.Node = undefined,
        /// whether this `Message` must be destroyed (not whether deinit should be
        /// called)
        allocated: bool = true,
        data: union(enum) {
            chat_message: struct {
                sender: *Client,
                message: []const u8,
            },
            request_chunk: struct {
                sender: *Client,
                position: ChunkPosition,
            },
            client_closed: struct {
                client: *Client,
            },
            return_entity: struct {
                entity: *Entity,
            },
            run_command: struct {
                sender: ?*Client,
                command: []const u8,
            },
        },

        pub fn deinit(self: *Message, a: Allocator) void {
            switch (self.data) {
                .chat_message => |d| {
                    a.free(d.message);
                },
                .run_command => |d| {
                    a.free(d.command);
                },
                else => {},
            }
            self.* = undefined;
        }
    };
    pub const MessagePool = std.heap.MemoryPool(Message);

    inner: net.StreamServer = net.StreamServer.init(.{
        .reuse_address = true,
        .force_nonblocking = true,
    }),
    loop: xev.Loop = undefined,
    allocator: Allocator,

    tick_timer_comp: xev.Completion = .{},
    target_tps: Value(usize) = .{ .raw = 20 },
    current_tick: Value(usize) = .{ .raw = 0 },

    keepalive_timer_comp: xev.Completion = .{},

    clients_lock: std.Thread.RwLock = .{},
    clients: std.SegmentedList(Client, 0) = .{},
    clients_available: std.DynamicBitSetUnmanaged = .{},

    accept_comp: xev.Completion = undefined,

    options_lock: std.Thread.RwLock = .{},
    //spawn_position: Position = .{ .x = 0, .y = 13, .z = 0 },
    spawn_position: Position = .{ .x = 0, .y = 50, .z = 0 },

    next_eid: usize = 1,

    // TODO: handle entity management more similarly to clients
    entities_lock: std.Thread.RwLock = .{},
    entities: std.SegmentedList(Entity, 0) = .{},
    eid_map: std.AutoHashMapUnmanaged(usize, *Entity) = .{},

    unused_entities_lock: std.Thread.RwLock = .{},
    unused_entities: CleanupLL = .{},

    chunks_lock: std.Thread.RwLock = .{},
    chunks: std.AutoHashMapUnmanaged(ChunkPosition, *ChunkColumn) = .{},
    chunk_pool: std.heap.MemoryPool(ChunkColumn) = undefined,

    messages: Mpsc = undefined,
    message_pool: MessagePool = undefined,
    message_pool_lock: std.Thread.Mutex = .{},

    tick_arena: std.heap.ArenaAllocator = undefined,

    fn keepAliveCb(
        self_: ?*anyopaque,
        l: *xev.Loop,
        c: *xev.Completion,
        r: xev.Result,
    ) xev.CallbackAction {
        var self: *Server = @ptrCast(@alignCast(self_.?));
        _ = r.timer catch |e| {
            std.log.err("Keep alive timer error: \"{}\"", .{e});
        };
        const current_time = std.time.milliTimestamp();
        //const keep_alive_id = @as(i32, @bitCast(@as(u32, @truncate(
        //    std.hash.Wyhash.hash(20, mem.asBytes(&current_time)),
        //))));
        const keep_alive_id = current_time;
        self.clients_lock.lockShared();
        defer self.clients_lock.unlockShared();
        var iter = self.clients.iterator(0);
        while (iter.next()) |cl| if (cl.isAlive()) {
            const oldest = cl.oldest_keep_alive.load(.Acquire);
            if (oldest != Client.NullKeepAlive and
                current_time - oldest > KeepAliveMaxTime)
            {
                // disconnect client
                std.log.info("No keep alive from {} in time. Kicking", .{cl.address});
                cl.lock.lockShared();
                defer cl.lock.unlockShared();
                cl.stop();
                continue;
            }

            _ = cl.keep_alives.enqueue(keep_alive_id);
            // TODO: this might not be thread safe enough
            if (cl.inner.canSend()) {
                const res = switch (cl.state.load(.Acquire)) {
                    .configuration => cl.sendPacket(mcv.C.CB, .{
                        .keep_alive = keep_alive_id,
                    }),
                    .play => cl.sendPacket(mcv.P.CB, .{
                        .keep_alive = keep_alive_id,
                    }),
                    else => {},
                };
                // ok why do i need a variable, why cant i just catch right after switch
                res catch |e| {
                    std.log.err(
                        "Failed to send keep alive to {}: \"{}\"",
                        .{ cl.address, e },
                    );
                };
            }
        };
        l.timer(c, KeepAliveTime, self_, keepAliveCb);
        return .disarm;
    }
    fn tickCb(
        self_: ?*anyopaque,
        l: *xev.Loop,
        c: *xev.Completion,
        r: xev.Result,
    ) xev.CallbackAction {
        const current_time = std.time.milliTimestamp();
        var self: *Server = @ptrCast(@alignCast(self_.?));
        _ = r.timer catch |e| {
            std.log.err("Tick timer error: \"{}\"", .{e});
            // TODO: is this fatal?
        };
        self.runTick() catch |e| {
            std.log.err("Failed to run a tick: \"{}\"", .{e});
        };
        const desired_ms = @as(i64, @intCast(
            std.time.ms_per_s / self.target_tps.load(.Monotonic),
        ));
        const time_taken = @max(0, std.time.milliTimestamp() - current_time);
        const time_to_take = @as(u64, @intCast(@max(0, desired_ms - time_taken)));
        //std.log.info(
        //    "target: {}ms, time taken: {}ms, will wait: {}ms",
        //    .{ desired_ms, time_taken, time_to_take },
        //);
        l.timer(c, time_to_take, self_, tickCb);
        if (time_taken > desired_ms) {
            std.log.warn(
                "Tick took {}ms, longer than {}ms!",
                .{ time_taken, desired_ms },
            );
        }
        return .disarm;
    }

    pub fn handleMessage(self: *Server, msg: *Message) !void {
        const ar = self.tick_arena.allocator();
        defer _ = self.tick_arena.reset(.retain_capacity);

        defer {
            if (msg.allocated) {
                msg.deinit(self.allocator);
                self.message_pool_lock.lock();
                self.message_pool.destroy(msg);
                self.message_pool_lock.unlock();
            } else {
                msg.deinit(self.allocator);
            }
        }
        switch (msg.data) {
            .chat_message => |d| {
                std.log.info("{s}: {s}", .{ d.sender.name, d.message });
                d.sender.lock.lockShared();
                defer d.sender.lock.unlockShared();
                const packet = mcv.P.CB.UT{
                    .player_chat_message = .{
                        .sender = blk: {
                            if (d.sender.entity) |entity| {
                                entity.lock.lockShared();
                                defer entity.lock.unlockShared();
                                break :blk entity.uuid;
                            }
                            break :blk mem.zeroes(mcv.Uuid.UT);
                        },
                        .index = 0, // TODO: what is this
                        .message = d.message,
                        .timestamp = @intCast(std.time.milliTimestamp()),
                        .salt = 0,
                        .previous_messages = &.{},
                        .filter = .pass_through,
                        .chat_type = 0,
                        .sender_name = .{ .string = d.sender.name },
                    },
                };
                self.clients_lock.lockShared();
                defer self.clients_lock.unlockShared();
                var iter = self.clients.iterator(0);
                while (iter.next()) |cl| if (cl.canSendPlay()) {
                    try cl.sendPacket(mcv.P.CB, packet);
                };
            },
            .request_chunk => |d| {
                const chunk = try self.getChunk(d.position);
                chunk.lock.lock();
                defer chunk.lock.unlock();
                chunk.viewers += 1;
                errdefer chunk.viewers -= 1;

                try d.sender.chunks_to_load.writeItem(chunk);
            },
            .client_closed => |d| {
                // no other thread should be looking at client right now (so we
                //     shouldnt need to lock anything in client EXCEPT if the
                //     client is being looked at through iterating through all
                //     clients, therefore we must lock client list until we have
                //     completely removed the client (which we will have to lock
                //     anyway)
                const closed_cl = d.client;

                self.clients_lock.lock();
                const entity_to_return = closed_cl.entity;
                closed_cl.entity = null;
                {
                    defer self.clients_lock.unlock();
                    if (entity_to_return) |e| {
                        const packet = mcv.P.CB.UT{
                            .player_info_remove = &.{e.uuid},
                        };
                        var iter = self.clients.iterator(0);
                        while (iter.next()) |cl| {
                            if (cl != closed_cl and cl.canSendPlay()) {
                                try cl.sendPacket(mcv.P.CB, packet);
                            }
                        }
                    }
                    if (closed_cl.name.len > 0)
                        std.log.info("\"{s}\" disconnected", .{closed_cl.name});

                    self.clients_available.set(closed_cl.id);
                    closed_cl.deinit();
                    // mark as not alive so that anyone looping on this will skip
                    //     and not have to check the bit set to see if the client
                    //     is deinitialized
                    closed_cl.inner.alive = .{ .raw = false };
                }

                if (entity_to_return) |e| {
                    self.returnEntity(e);
                }
            },
            .return_entity => |d| {
                self.returnEntity(d.entity);
            },
            .run_command => |d| blk: {
                const cmd = Command.parse(ar, d.command) catch |e| {
                    if (d.sender) |cl| {
                        if (cl.canSendPlay()) {
                            try cl.sendPacket(mcv.P.CB, .{ .system_chat_message = .{
                                .content = .{ .string = try std.fmt.allocPrint(
                                    ar,
                                    "Failed to parse command: {}",
                                    .{e},
                                ) },
                                .is_action_bar = false,
                            } });
                        }
                    } else {
                        std.log.err("Failed to parse command: {}", .{e});
                    }
                    break :blk;
                } orelse {
                    if (d.sender) |cl| {
                        if (cl.canSendPlay()) {
                            try cl.sendPacket(mcv.P.CB, .{ .system_chat_message = .{
                                .content = .{ .string = "Unknown command" },
                                .is_action_bar = false,
                            } });
                        }
                    } else {
                        std.log.err("Unknown command", .{});
                    }
                    break :blk;
                };
                switch (cmd) {
                    .list => {
                        var response = std.ArrayList(u8).init(ar);
                        try response.appendSlice("Players: ");
                        {
                            self.clients_lock.lockShared();
                            defer self.clients_lock.unlockShared();
                            var iter = self.clients.iterator(0);
                            var first = true;
                            while (iter.next()) |cl| if (cl.canSendPlay()) {
                                cl.lock.lockShared();
                                defer cl.lock.unlockShared();
                                if (cl.name.len > 0)
                                    try response.appendSlice(cl.name);
                                if (first) {
                                    first = false;
                                } else {
                                    try response.appendSlice(", ");
                                }
                            };
                        }
                        if (d.sender) |cl| {
                            if (cl.canSendPlay()) {
                                try cl.sendPacket(mcv.P.CB, .{
                                    .system_chat_message = .{
                                        .content = .{ .string = response.items },
                                        .is_action_bar = false,
                                    },
                                });
                            }
                        } else {
                            std.log.info("{s}", .{response.items});
                        }
                    },
                    else => {},
                }
            },
        }
    }

    pub fn returnEntity(self: *Server, entity: *Entity) void {
        const id = entity.id;
        {
            self.entities_lock.lock();
            defer self.entities_lock.unlock();
            _ = self.eid_map.remove(id);

            self.unused_entities_lock.lock();
            defer self.unused_entities_lock.unlock();
            self.unused_entities.prepend(&entity.cleanup);
        }

        self.clients_lock.lockShared();
        defer self.clients_lock.unlockShared();
        var iter = self.clients.iterator(0);
        while (iter.next()) |cl| if (cl.canSendPlay()) {
            cl.sendPacket(mcv.P.CB, .{
                .remove_entities = &.{@intCast(id)},
            }) catch {}; // TODO: handle error?
        };

        // TODO: deinit entity (but not the id!)
    }

    pub fn runTick(self: *Server) !void {
        // TODO: we need better error handling of stuff like looping through all clients
        //     and sending a message; a single client erroring should not prevent
        //     other clients from receiving a message and such
        _ = self.current_tick.fetchAdd(1, .Monotonic);

        {
            while (self.messages.pop()) |node| {
                const msg = @fieldParentPtr(Message, "node", node);
                self.handleMessage(msg) catch |e| {
                    std.log.err(
                        "Failed to handle internal message {any}: {}",
                        .{ msg.*, e },
                    );
                };
            }
        }

        {
            self.clients_lock.lockShared();
            defer self.clients_lock.unlockShared();
            var iter = self.clients.iterator(0);
            while (iter.next()) |cl| {
                try cl.tick();
            }
        }

        {
            self.entities_lock.lockShared();
            defer self.entities_lock.unlockShared();
            var iter = self.eid_map.valueIterator();
            while (iter.next()) |e| {
                try e.*.tick(self);
            }
        }
    }

    pub fn getChunk(self: *Server, pos: ChunkPosition) !*ChunkColumn {
        {
            self.chunks_lock.lockShared();
            defer self.chunks_lock.unlockShared();
            if (self.chunks.get(pos)) |chunk| return chunk;
        }
        self.chunks_lock.lock();
        defer self.chunks_lock.unlock();

        // TODO: generate chunk
        const chunk = try self.chunk_pool.create();
        errdefer self.chunk_pool.destroy(chunk);
        chunk.* = .{
            .inner = mcp.chunk.Column.initFlat(),
            .position = pos,
        };
        try self.chunks.putNoClobber(self.allocator, pos, chunk);
        return chunk;
    }

    pub fn addEntity(self: *Server, pos: Position, uuid: mcv.Uuid.UT) !*Entity {
        {
            self.unused_entities_lock.lock();
            defer self.unused_entities_lock.unlock();
            if (self.unused_entities.popFirst()) |e_node| {
                const entity = @fieldParentPtr(Entity, "cleanup", e_node);

                self.entities_lock.lock();
                defer self.entities_lock.unlock();
                try self.eid_map.putNoClobber(self.allocator, entity.id, entity);
                return entity;
            }
        }
        self.entities_lock.lock();
        defer self.entities_lock.unlock();
        const entity = try self.entities.addOne(self.allocator);
        entity.* = .{ .id = self.next_eid, .position = pos, .uuid = uuid };
        self.next_eid += 1;

        try self.eid_map.putNoClobber(self.allocator, entity.id, entity);

        return entity;
    }

    fn acceptCb(
        self_: ?*anyopaque,
        _: *xev.Loop,
        c: *xev.Completion,
        r: xev.Result,
    ) xev.CallbackAction {
        var self: *Server = @ptrCast(@alignCast(self_.?));
        const handle = r.accept catch |e| {
            std.log.err("Failed to handle incoming connection: \"{}\"", .{e});
            return .disarm;
        };
        self.addClient(.{ .handle = handle }, .{ .any = c.op.accept.addr }) catch |e| {
            std.log.err(
                "Failed to create client for incoming connection: \"{}\"",
                .{e},
            );
            return .disarm;
        };
        return .rearm;
    }

    pub fn addClient(self: *Server, stream: net.Stream, address: net.Address) !void {
        self.clients_lock.lock();
        defer self.clients_lock.unlock();

        const client, const id = if (self.clients_available.findFirstSet()) |ind| blk: {
            self.clients_available.unset(ind);
            break :blk .{ self.clients.at(ind), ind };
        } else blk: {
            const new_id = self.clients.count();
            try self.clients_available
                .resize(self.allocator, self.clients.count() + 1, false);
            break :blk .{ try self.clients.addOne(self.allocator), new_id };
        };

        self.options_lock.lock();
        defer self.options_lock.unlock();
        client.init(id, stream, address, self);
    }

    pub fn init(self: *Server, address: net.Address) !void {
        self.messages.init();
        self.message_pool = MessagePool.init(self.allocator);
        self.tick_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.chunk_pool = std.heap.MemoryPool(ChunkColumn).init(self.allocator);
        try self.inner.listen(address);
        errdefer self.inner.deinit();
        self.loop = try xev.Loop.init(.{});
        errdefer self.loop.deinit();
    }

    pub fn start(self: *Server) !void {
        self.accept_comp = .{
            .op = .{ .accept = .{ .socket = self.inner.sockfd.? } },
            .userdata = self,
            .callback = acceptCb,
        };
        self.loop.add(&self.accept_comp);
        self.loop.timer(&self.tick_timer_comp, 1000 / self.target_tps.raw, self, tickCb);
        self.loop.timer(&self.keepalive_timer_comp, KeepAliveTime, self, keepAliveCb);
        try self.loop.run(.until_done);
    }

    pub fn deinit(self: *Server) void {
        while (self.messages.pop()) |n| {
            const msg = @fieldParentPtr(Message, "node", n);
            msg.deinit(self.allocator);
        }
        self.message_pool.deinit();
        {
            var iter = self.chunks.valueIterator();
            while (iter.next()) |chunk| {
                chunk.*.inner.deinit(self.allocator);
                self.allocator.destroy(chunk);
            }
            self.chunks.deinit(self.allocator);
        }
        self.chunk_pool.deinit();
        while (self.clients.pop()) |client_| {
            var client = client_;
            client.deinit();
        }
        self.clients.deinit(self.allocator);
        self.clients_available.deinit(self.allocator);
        // TODO: deinit entities
        self.inner.deinit();
        self.loop.deinit();
        self.* = undefined;
    }
};
