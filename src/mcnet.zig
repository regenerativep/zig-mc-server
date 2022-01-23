const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const deflate = std.compress.deflate;
const io = std.io;

const zlib = @import("zlib");
const c = @cImport({
    @cInclude("zlib.h");
    @cInclude("stddef.h");
});

const mcp = @import("mcproto.zig");

pub const ZlibCompressor = struct {
    allocator: Allocator,
    stream: *c.z_stream,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        var ret = Self{
            .allocator = allocator,
            .stream = undefined,
        };

        ret.stream = try allocator.create(c.z_stream);
        errdefer allocator.destroy(ret.stream);

        // if the user provides an allocator zlib uses an opaque pointer for
        // custom malloc an free callbacks, this requires pinning, so we use
        // the allocator to allocate the Allocator struct on the heap
        const pinned = try allocator.create(Allocator);
        errdefer allocator.destroy(pinned);

        pinned.* = allocator;
        ret.stream.@"opaque" = pinned;
        ret.stream.zalloc = zlib.zalloc;
        ret.stream.zfree = zlib.zfree;

        const rc = c.deflateInit(ret.stream, c.Z_DEFAULT_COMPRESSION);
        return if (rc == c.Z_OK) ret else zlib.errorFromInt(rc);
    }

    pub fn deinit(self: *Self) void {
        const pinned = @ptrCast(*Allocator, @alignCast(@alignOf(*Allocator), self.stream.@"opaque".?));
        _ = c.deflateEnd(self.stream);
        self.allocator.destroy(pinned);
        self.allocator.destroy(self.stream);
    }

    pub fn reset(self: *Self) void {
        _ = c.deflateReset(self.stream);
    }

    pub fn flush(self: *Self, w: anytype) !void {
        var tmp: [4096]u8 = undefined;
        while (true) {
            self.stream.next_out = &tmp;
            self.stream.avail_out = tmp.len;
            var rc = c.deflate(self.stream, c.Z_FINISH);
            if (rc != c.Z_STREAM_END)
                return zlib.errorFromInt(rc);

            if (self.stream.avail_out != 0) {
                const n = tmp.len - self.stream.avail_out;
                try w.writeAll(tmp[0..n]);
                break;
            } else try w.writeAll(&tmp);
        }
    }

    pub fn WithWriter(comptime WriterType: type) type {
        return struct {
            const WriterError = zlib.Error || WriterType.Error;
            const Writer = io.Writer(InnerSelf, WriterError, write);
            inner: WriterType,
            parent: *ZlibCompressor,

            const InnerSelf = @This();

            pub fn write(self: InnerSelf, buf: []const u8) WriterError!usize {
                var tmp: [4096]u8 = undefined;

                self.parent.stream.next_in = @intToPtr([*]u8, @ptrToInt(buf.ptr));
                self.parent.stream.avail_in = @intCast(c_uint, buf.len);

                while (true) {
                    self.parent.stream.next_out = &tmp;
                    self.parent.stream.avail_out = tmp.len;
                    var rc = c.deflate(self.parent.stream, c.Z_PARTIAL_FLUSH);
                    if (rc != c.Z_OK)
                        return zlib.errorFromInt(rc);

                    if (self.parent.stream.avail_out != 0) {
                        const n = tmp.len - self.parent.stream.avail_out;
                        try self.inner.writeAll(tmp[0..n]);
                        break;
                    } else try self.inner.writeAll(&tmp);
                }

                return buf.len - self.stream.avail_in;
            }
        };
    }

    pub fn writer(self: *Self, w: anytype) WithWriter(@TypeOf(w)).Writer {
        return .{ .context = WithWriter(@TypeOf(w)){
            .inner = w,
            .parent = self,
        } };
    }
};

pub fn PacketClient(comptime ReaderType: type, comptime WriterType: type, comptime compression_threshold: ?i32) type {
    return struct {
        pub const Threshold = compression_threshold;

        connection: net.StreamServer.Connection,
        reader: io.BufferedReader(1024, ReaderType),
        writer: io.BufferedWriter(1024, WriterType),

        const Self = @This();
        pub fn readHandshakePacket(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType.UserType {
            var len = try mcp.VarInt.deserialize(alloc, self.reader.reader());
            if (len == 0xFE) {
                return PacketType.UserType.legacy;
            }
            return try self.readPacketLen(PacketType, alloc, @intCast(usize, len));
        }
        pub fn readPacket(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType.UserType {
            var len = try mcp.VarInt.deserialize(alloc, self.reader.reader());
            return try self.readPacketLen(PacketType, alloc, @intCast(usize, len));
        }
        usingnamespace if (compression_threshold) |threshold| struct {
            pub fn readPacketLen(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType.UserType {
                var reader = io.limitedReader(self.reader.reader(), len);
                const data_len = try mcp.VarInt.deserialize(alloc, reader.reader());
                if (data_len == 0) {
                    return try PacketType.deserialize(alloc, reader.reader());
                } else {
                    var decompressor = std.zlib.zlibStream(alloc, reader.reader());
                    defer decompressor.deinit();
                    return try PacketType.deserialize(alloc, decompressor.reader()); // TODO can these readers not be pointers?
                }
            }

            pub fn writePacket(self: *Self, comptime PacketType: type, packet: PacketType.UserType, compressor: *ZlibCompressor) !void {
                const actual_len = @intCast(i32, PacketType.size(packet));
                var buf_writer = self.writer.writer();
                if (actual_len < compression_threshold) {
                    try mcp.VarInt.write(actual_len, buf_writer);
                    try buf_writer.writeByte(0x00); // varint of 0
                    try PacketType.write(packet, buf_writer);
                } else {
                    // not sure if compression works and im not sure ill try for a while

                    // we need the length of the compressed data :(
                    var compressed_data = try std.ArrayList(u8).initCapacity(compressor.allocator, threshold);
                    // yeah i guess ill just use the compressors allocator. we'll see how that goes
                    defer compressed_data.deinit();
                    defer compressor.reset();
                    var compressed_data_writer = compressed_data.writer();
                    try PacketType.write(packet, compressor.writer(compressed_data_writer));
                    try mcp.VarInt.write(@intCast(i32, compressed_data.items.len + mcp.VarInt.size(actual_len)), self.writer);
                    try mcp.VarInt.write(actual_len, buf_writer);
                    try compressor.flush(compressed_data_writer);
                    try buf_writer.writeAll(compressed_data.items);
                }
                try self.writer.flush();
            }
            pub fn intoUncompressed(self: *Self) PacketClient(ReaderType, WriterType, null) {
                return .{
                    .reader = self.reader,
                    .writer = self.writer,
                };
            }
        } else struct {
            pub fn readPacketLen(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType.UserType {
                var lim_reader = io.limitedReader(self.reader.reader(), len);
                var reader = io.countingReader(lim_reader.reader());
                const result = PacketType.deserialize(alloc, reader.reader()) catch |err| {
                    if (err == error.EndOfStream) {
                        return err;
                    } else {
                        // we need to make sure we read the rest, or else the next packet that reads will intersect with this
                        var r = reader.reader();
                        while (reader.bytes_read < len) {
                            _ = try r.readByte();
                        }
                        // TODO multiple different types of errors could come out of this. handle properly
                        return err;
                    }
                };
                if (reader.bytes_read < len) {
                    std.log.info("read {}/{} bytes in packet, is this a group packet?", .{ reader.bytes_read, len });
                    var r = reader.reader();
                    std.log.info("next byte in potential group packet is 0x{X}", .{try r.readByte()});
                    while (reader.bytes_read < len) {
                        _ = try r.readByte();
                    }
                }
                return result;
            }

            pub fn writePacket(self: *Self, comptime PacketType: type, packet: PacketType.UserType) !void {
                var buf_writer = self.writer.writer();
                try mcp.VarInt.write(@intCast(i32, PacketType.size(packet)), buf_writer);
                // TODO: fill up rest of packet space with garbage on error?
                try PacketType.write(packet, buf_writer);
                try self.writer.flush();
            }
            pub fn intoCompressed(self: *Self, comptime threshold: i32) PacketClient(ReaderType, WriterType, threshold) {
                return .{
                    .reader = self.reader,
                    .writer = self.writer,
                };
            }
        };
        pub fn close(self: *Self) void {
            self.connection.stream.close();
        }
    };
}

pub fn packetClient(conn: net.StreamServer.Connection, reader: anytype, writer: anytype, comptime threshold: ?i32) PacketClient(@TypeOf(reader), @TypeOf(writer), threshold) {
    return .{
        .connection = conn,
        .reader = .{ .unbuffered_reader = reader },
        .writer = .{ .unbuffered_writer = writer },
    };
}
