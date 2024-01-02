// based on https://thealexcons.github.io/spsc-queue/

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

const cache_line = std.atomic.cache_line;

pub fn Spsc(comptime T: type, comptime log2_capacity: comptime_int) type {
    return struct {
        /// this is capacity of buffer, but actual capacity is capacity - 1
        pub const capacity = 1 << log2_capacity;
        pub const Index = @Type(.{ .Int = .{
            .signedness = .unsigned,
            .bits = log2_capacity,
        } });

        // TODO: doesnt this not need to be aligned? (not that it matters much since
        //     everything else in here is) both enqueue and dequeue are regularly
        //     accessing it anyway.
        buffer: [capacity]T align(cache_line) = undefined,
        /// rw by dequeue, frugally read by enqueue
        head: Index align(cache_line) = 0,
        /// rw by enqueue, frugally read by dequeue
        tail: Index align(cache_line) = 0,
        /// rw by enqueue, enqueue's cache of head
        head_cache: Index align(cache_line) = 0,
        /// rw by dequeue, dequeue's cache of tail
        tail_cache: Index align(cache_line) = 0,

        const Self = @This();

        // TODO: enqueue and dequeue slices
        pub fn enqueue(self: *Self, value: T) bool {
            const tail = @atomicLoad(Index, &self.tail, .Monotonic);
            const next_tail = tail +% 1;

            if (next_tail == self.head_cache) {
                self.head_cache = @atomicLoad(Index, &self.head, .Acquire);
                if (next_tail == self.head_cache) {
                    return false;
                }
            }

            self.buffer[tail] = value;
            @atomicStore(Index, &self.tail, next_tail, .Release);
            return true;
        }

        pub fn dequeue(self: *Self) ?T {
            const head = @atomicLoad(Index, &self.head, .Monotonic);

            if (head == self.tail_cache) {
                self.tail_cache = @atomicLoad(Index, &self.tail, .Acquire);
                if (head == self.tail_cache) {
                    return null;
                }
            }

            const value = self.buffer[head];
            @atomicStore(Index, &self.head, head +% 1, .Release);
            return value;
        }

        /// peek the value on the enqueue side
        pub fn enpeek(self: *Self) ?*T {
            const tail = @atomicLoad(Index, &self.tail, .Monotonic);

            if (tail == self.head_cache) {
                self.head_cache = @atomicLoad(Index, &self.head, .Acquire);
                if (tail == self.head_cache) {
                    return null;
                }
            }

            return &self.buffer[tail];
        }

        // peek the value on the dequeue side
        pub fn depeek(self: *Self) ?*T {
            const head = @atomicLoad(Index, &self.head, .Monotonic);

            if (head == self.tail_cache) {
                self.tail_cache = @atomicLoad(Index, &self.tail, .Acquire);
                if (head == self.tail_cache) {
                    return null;
                }
            }

            return &self.buffer[head];
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return @atomicLoad(Index, &self.tail, .Monotonic) ==
                @atomicLoad(Index, &self.head, .Monotonic);
        }

        pub inline fn count(self: *const Self) Index {
            return @atomicLoad(Index, &self.tail, .Acquire) -%
                @atomicLoad(Index, &self.head, .Acquire);
        }

        pub inline fn countUnused(self: *const Self) Index {
            return (capacity - 1) - self.count();
        }
    };
}

/// Queue up values in the event the spsc is full
pub fn QueuedSpsc(comptime T: type, comptime log2_capacity: comptime_int) type {
    return struct {
        pub const Fifo = std.fifo.LinearFifo(T, .Dynamic);

        spsc: Spsc(T, log2_capacity) = .{},
        fifo: ?Fifo = null,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (self.fifo) |*fifo| fifo.deinit();
            self.* = undefined;
        }

        pub fn ensureUnusedCapacity(self: *Self, a: Allocator, count: usize) !void {
            const available_spsc = self.spsc.countUnused();
            if (self.fifo == null) self.fifo = Fifo.init(a);
            try self.fifo.?.ensureUnusedCapacity(count -| available_spsc);
        }

        pub fn enqueue(self: *Self, a: Allocator, value: T) !void {
            try self.ensureUnusedCapacity(a, 1);
            self.enqueueAssumeCapacity(value);
        }

        /// fills spsc with as many values from internal fifo as we can
        pub fn enqueueFifo(self: *Self) void {
            if (self.fifo) |*fifo| {
                while (fifo.count > 0) {
                    if (self.spsc.enqueue(fifo.peekItem(0))) {
                        fifo.discard(1);
                    } else {
                        return;
                    }
                }
            }
        }
        pub fn enqueueAssumeCapacity(self: *Self, value: T) void {
            self.enqueueFifo();
            if ((self.fifo != null and self.fifo.?.count > 0) or
                !self.spsc.enqueue(value))
            {
                if (self.fifo) |*fifo| fifo.writeItemAssumeCapacity(value);
            }
        }
        pub inline fn dequeue(self: *Self) ?T {
            return self.spsc.dequeue();
        }
    };
}

test "spsc" {
    const T = Spsc(u64, 3);
    var spsc = T{};

    try testing.expectEqual(true, spsc.isEmpty());
    try testing.expectEqual(@as(T.Index, 0), spsc.count());

    try testing.expectEqual(true, spsc.enqueue(1));
    try testing.expectEqual(true, spsc.enqueue(2));
    try testing.expectEqual(true, spsc.enqueue(3));
    try testing.expectEqual(true, spsc.enqueue(4));
    try testing.expectEqual(true, spsc.enqueue(5));

    try testing.expectEqual(@as(T.Index, 5), spsc.count());
    try testing.expectEqual(false, spsc.isEmpty());

    try testing.expectEqual(@as(?u64, 1), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 2), spsc.dequeue());

    try testing.expectEqual(true, spsc.enqueue(6));
    try testing.expectEqual(true, spsc.enqueue(7));
    try testing.expectEqual(true, spsc.enqueue(8));
    try testing.expectEqual(true, spsc.enqueue(9));

    try testing.expectEqual(@as(T.Index, 7), spsc.count());
    try testing.expectEqual(false, spsc.isEmpty());

    try testing.expectEqual(false, spsc.enqueue(10));

    try testing.expectEqual(@as(?u64, 3), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 4), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 5), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 6), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 7), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 8), spsc.dequeue());

    try testing.expectEqual(true, spsc.enqueue(11));
    try testing.expectEqual(true, spsc.enqueue(12));

    try testing.expectEqual(@as(?u64, 9), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 11), spsc.dequeue());
    try testing.expectEqual(@as(?u64, 12), spsc.dequeue());

    try testing.expectEqual(true, spsc.isEmpty());
    try testing.expectEqual(@as(T.Index, 0), spsc.count());
}
