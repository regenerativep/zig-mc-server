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

pub const Client = @import("client.zig");
pub const Entity = @import("entity.zig");

test {
    _ = Client;
    _ = Entity;
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
    pub const CleanupLL = std.SinglyLinkedList(void);
    pub const RequestedChunks = std.fifo.LinearFifo(
        struct { position: ChunkPosition, client: *Client },
        .Dynamic,
    );

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
    clients_cleanup: Mpsc = undefined,

    accept_comp: xev.Completion = undefined,

    options_lock: std.Thread.RwLock = .{},
    //spawn_position: Position = .{ .x = 0, .y = 13, .z = 0 },
    spawn_position: Position = .{ .x = 0, .y = 50, .z = 0 },

    next_eid: usize = 1,

    entities_lock: std.Thread.RwLock = .{},
    entities: std.SegmentedList(Entity, 0) = .{},
    eid_map: std.AutoHashMapUnmanaged(usize, *Entity) = .{},

    unused_entities_lock: std.Thread.RwLock = .{},
    unused_entities: CleanupLL = .{},

    chunks_lock: std.Thread.RwLock = .{},
    chunks: std.AutoHashMapUnmanaged(ChunkPosition, *ChunkColumn) = .{},
    chunk_pool: std.heap.MemoryPool(ChunkColumn) = undefined,

    requested_chunks_lock: std.Thread.RwLock = .{},
    requested_chunks: RequestedChunks = undefined,

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
        const keep_alive_id = @as(i32, @bitCast(@as(u32, @truncate(
            std.hash.Wyhash.hash(20, mem.asBytes(&current_time)),
        ))));
        self.clients_lock.lockShared();
        defer self.clients_lock.unlockShared();
        var iter = self.clients.iterator(0);
        while (iter.next()) |cl| if (cl.isAlive()) {
            cl.lock.lockShared();
            defer cl.lock.unlockShared();

            if (cl.last_keep_alive != math.maxInt(i64) and
                current_time - cl.last_keep_alive > KeepAliveMaxTime)
            {
                // disconnect client
                std.log.info("No keep alive from {} in time", .{cl.address});
                cl.inner.stop(&self.loop);
                continue;
            }

            const res = switch (cl.state.load(.Monotonic)) {
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

    pub fn runTick(self: *Server) !void {
        _ = self.current_tick.fetchAdd(1, .Monotonic);

        {
            self.clients_lock.lockShared();
            defer self.clients_lock.unlockShared();
            var iter = self.clients.iterator(0);
            while (iter.next()) |cl| {
                try cl.tick();
            }
        }

        {
            self.requested_chunks_lock.lock();
            defer self.requested_chunks_lock.unlock();
            while (self.requested_chunks.readItem()) |pair| {
                const chunk = try self.getChunk(pair.position);
                chunk.lock.lock();
                defer chunk.lock.unlock();
                chunk.viewers += 1;
                errdefer chunk.viewers -= 1;

                try pair.client.chunks_to_load.writeItem(chunk);
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
        while (iter.next()) |cl| if (cl.isPlay()) {
            cl.sendPacket(mcv.P.CB, .{
                .remove_entities = &.{@intCast(id)},
            }) catch {}; // TODO: handle error?
        };

        // TODO: deinit entity (but not the id!)
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

        const client = if (self.clients_cleanup.pop()) |cl_node| blk: {
            const cl = @fieldParentPtr(Client, "cleanup", cl_node);
            cl.deinit();
            break :blk cl;
        } else try self.clients.addOne(self.allocator);
        errdefer {
            // only need to be able to run deinit on this client
            client.* = .{
                .inner = .{
                    .stream = undefined,
                    .recv_comp = undefined,
                    .alive = .{ .raw = false },
                },
                .address = undefined,
                .server = self,
                .arena = std.heap.ArenaAllocator.init(self.allocator),
                .chunks_to_load = Client.ChunksToLoad.init(self.allocator),
            };
            self.clients_cleanup.push(&client.cleanup);
        }

        self.options_lock.lock();
        defer self.options_lock.unlock();
        client.init(stream, address, self);
    }

    pub fn init(self: *Server, address: net.Address) !void {
        self.clients_cleanup.init();
        self.chunk_pool = std.heap.MemoryPool(ChunkColumn).init(self.allocator);
        self.requested_chunks = RequestedChunks.init(self.allocator);
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
        self.inner.deinit();
        self.loop.deinit();
        self.* = undefined;
    }
};
