const std = @import("std");
const net = std.net;

const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;

const xev = @import("xev");

/// Double buffer for queuing writes
pub const DoubleBuffer = struct {
    pub const Buffer = struct {
        pub const List = std.ArrayListUnmanaged(u8);

        lock: std.Thread.RwLock = .{},
        data: List = .{},

        /// must lock `lock` and `swap_lock`
        pub inline fn writer(self: *Buffer, a: Allocator) List.Writer {
            return self.data.writer(a);
        }
    };
    buffers: [2]Buffer = .{ .{}, .{} },

    swap_lock: std.Thread.RwLock = .{},
    active_buffer: u1 = 0,
    total_read: usize = 0,

    const Self = @This();

    /// must lock `swap_lock`
    pub inline fn nonActiveBuffer(self: *Self) *Buffer {
        return &self.buffers[self.active_buffer +% 1];
    }

    pub fn write(self: *Self, a: Allocator, data: []const u8) !void {
        self.swap_lock.lockShared();
        defer self.swap_lock.unlockShared();
        const buffer = self.nonActiveBuffer();
        buffer.lock.lock();
        defer buffer.lock.unlock();
        try buffer.writer(a).writeAll(data);
    }

    pub fn deinit(self: *Self, a: Allocator) void {
        inline for (&self.buffers) |*buffer| {
            buffer.data.deinit(a);
        }
        self.* = undefined;
    }

    pub fn isEmpty(self: *Self) bool {
        self.swap_lock.lockShared();
        defer self.swap_lock.unlockShared();
        for (&self.buffers) |*buffer| {
            buffer.lock.lockShared();
            defer buffer.lock.unlockShared();
            if (buffer.data.items.len > 0) return false;
        }
        return true;
    }
};

pub fn XevClient(comptime Callbacks: type) type {
    return struct {
        alive: std.atomic.Value(bool) = .{ .raw = true },

        buffer: DoubleBuffer = .{},

        send_lock: std.Thread.Mutex = .{},
        send_comp: ?xev.Completion = null,

        recv_comp: xev.Completion,
        recv_cancel_comp: xev.Completion = undefined,
        recv_buffer: [1024]u8 = undefined,
        recv_error: ?xev.ReadError = null,

        stream: net.Stream,

        const Self = @This();

        pub fn init(self: *Self, loop: *xev.Loop, stream: net.Stream) void {
            self.* = .{
                .stream = stream,
                .recv_comp = .{
                    .op = .{ .recv = .{
                        .fd = stream.handle,
                        .buffer = .{ .slice = &self.recv_buffer },
                    } },
                    .userdata = self,
                    .callback = recvCb,
                },
            };
            loop.add(&self.recv_comp);
        }

        pub fn isAlive(self: *const Self) bool {
            return self.alive.load(.Acquire);
        }

        pub fn send(
            self: *Self,
            a: Allocator,
            loop: *xev.Loop,
            data: []const u8,
        ) !void {
            try self.buffer.write(a, data);
            self.submitSend(loop);
        }
        pub fn submitSend(self: *Self, loop: *xev.Loop) void {
            if (!self.isAlive()) return;
            self.send_lock.lock();
            defer self.send_lock.unlock();
            if (self.send_comp == null) {
                {
                    self.buffer.swap_lock.lock();
                    defer self.buffer.swap_lock.unlock();
                    const active_buffer =
                        &self.buffer.buffers[self.buffer.active_buffer];
                    active_buffer.lock.lock();
                    defer active_buffer.lock.unlock();
                    if (self.buffer.total_read == active_buffer.data.items.len) {
                        active_buffer.data.clearRetainingCapacity();
                        self.buffer.active_buffer +%= 1;
                        self.buffer.total_read = 0;
                    }
                }

                // locked for lifetime of comp
                self.buffer.swap_lock.lockShared();
                const active_buffer = &self.buffer.buffers[self.buffer.active_buffer];
                active_buffer.lock.lockShared();
                self.send_comp = .{
                    .op = .{ .send = .{
                        .fd = self.stream.handle,
                        .buffer = .{
                            .slice = active_buffer.data.items[self.buffer.total_read..],
                        },
                    } },
                    .userdata = self,
                    .callback = sendCb,
                };
                loop.add(&self.send_comp.?);
                // TODO: how to handle undoing the add on submision failure? or is
                //     submission error perhaps fatal to the loop? or should we just
                //     leave the comp in the queue and try submitting later?
                loop.submit() catch unreachable;
            }
        }

        fn sendCb(
            self_: ?*anyopaque,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            var self: *Self = @ptrCast(@alignCast(self_.?));

            // lifetime of completion is over, unlock buffer
            self.buffer.buffers[self.buffer.active_buffer].lock.unlockShared();
            self.buffer.swap_lock.unlockShared();

            if (r.send) |wrote_len| {
                self.buffer.swap_lock.lock();
                self.buffer.total_read += wrote_len;
                self.buffer.swap_lock.unlock();
            } else |_| {
                // any error, we shut this client down
                self.send_lock.lock();
                self.send_comp = null;
                self.send_lock.unlock();

                self.stop(l);
                return .disarm;
            }
            if (!self.isAlive()) {
                self.stop(l);
                return .disarm;
            }

            // check for data remaining in buffer and continue sending
            {
                self.buffer.swap_lock.lockShared();
                const active_buffer = &self.buffer.buffers[self.buffer.active_buffer];
                active_buffer.lock.lockShared();
                if (active_buffer.data.items.len > self.buffer.total_read) {
                    //c.* = .{ .op = .{ .send = .{
                    //    .fd = self.stream.handle,
                    //    .buffer = .{
                    //        .slice = active_buffer.data.items[self.buffer.total_read..],
                    //    },
                    //} } };
                    c.op.send = .{
                        .fd = self.stream.handle,
                        .buffer = .{
                            .slice = active_buffer.data.items[self.buffer.total_read..],
                        },
                    };
                    return .rearm;
                } else {
                    active_buffer.lock.unlockShared();
                    self.buffer.swap_lock.unlockShared();
                }
            }
            // check for data in alt buffer and continue sending
            {
                self.buffer.swap_lock.lock();
                {
                    const active_buffer = &self.buffer.buffers[self.buffer.active_buffer];
                    active_buffer.lock.lock();
                    active_buffer.data.clearRetainingCapacity();
                    active_buffer.lock.unlock();
                }
                self.buffer.active_buffer +%= 1;
                self.buffer.total_read = 0;
                self.buffer.swap_lock.unlock();

                self.buffer.swap_lock.lockShared();
                const active_buffer = &self.buffer.buffers[self.buffer.active_buffer];
                active_buffer.lock.lockShared();
                if (active_buffer.data.items.len > 0) {
                    //c.* = .{ .op = .{ .send = .{
                    //    .fd = self.stream.handle,
                    //    .buffer = .{
                    //        .slice = active_buffer.data.items[self.buffer.total_read..],
                    //    },
                    //} } };
                    c.op.send = .{
                        .fd = self.stream.handle,
                        .buffer = .{
                            .slice = active_buffer.data.items[self.buffer.total_read..],
                        },
                    };
                    return .rearm;
                } else {
                    active_buffer.lock.unlockShared();
                    self.buffer.swap_lock.unlockShared();
                }
            }
            // no data in either buffer, stop sending
            self.send_lock.lock();
            self.send_comp = null;
            self.send_lock.unlock();
            return .disarm;
        }

        fn recvCb(
            self_: ?*anyopaque,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            var self: *Self = @ptrCast(@alignCast(self_.?));
            if (r.recv) |read_len| {
                Callbacks.onRead(self, self.recv_buffer[0..read_len]);
                return .rearm;
            } else |e| {
                switch (e) {
                    // connection was closed. no error
                    error.EOF, error.ConnectionReset => {},
                    // read cancelled
                    error.Canceled => {},
                    else => {
                        std.debug.assert(self.recv_error == null);
                        self.recv_error = e;
                    },
                }
                Callbacks.onRead(self, &.{});
                Callbacks.onClose(self);
                self.alive.store(false, .Release);
                self.stream.close();
                return .disarm;
            }
        }

        fn recvCancelCb(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.CancelError!void,
        ) xev.CallbackAction {
            //r catch |e| {
            //    if (e != error.NotFound) {
            //        unreachable;
            //    }
            //};
            r catch {};
            return .disarm;
        }

        pub fn stop(self: *Self, loop: *xev.Loop) void {
            loop.cancel(
                &self.recv_comp,
                &self.recv_cancel_comp,
                void,
                null,
                recvCancelCb,
            );
            loop.add(&self.recv_cancel_comp);
            self.alive.store(false, .Release);
        }

        pub fn deinit(self: *Self, a: Allocator) void {
            self.buffer.deinit(a);
            self.* = undefined;
        }
    };
}
