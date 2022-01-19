const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const deflate = std.compress.deflate;

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
            const Writer = std.io.Writer(InnerSelf, WriterError, write);
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
        reader: ReaderType,
        writer: WriterType,

        const Self = @This();
        pub fn readHandshakePacket(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType.UserType {
            var len = try mcp.VarInt.deserialize(alloc, self.reader);
            if (len == 0xFE) {
                return PacketType.UserType.Legacy;
            }
            return try self.readPacketLen(PacketType, alloc, @intCast(usize, len));
        }
        pub fn readPacket(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType.UserType {
            var len = try mcp.VarInt.deserialize(alloc, self.reader);
            return try self.readPacketLen(PacketType, alloc, @intCast(usize, len));
        }
        usingnamespace if (compression_threshold) |threshold| struct {
            pub fn readPacketLen(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType.UserType {
                var reader = std.io.limitedReader(self.reader, len);
                const data_len = try mcp.VarInt.deserialize(alloc, self.reader);
                if (data_len == 0) {
                    return try PacketType.deserialize(alloc, &reader.reader());
                } else {
                    var decompressor = std.zlib.zlibStream(alloc, reader.reader());
                    defer decompressor.deinit();
                    return try PacketType.deserialize(alloc, &decompressor.reader()); // TODO can these readers not be pointers?
                }
            }

            pub fn writePacket(self: *Self, comptime PacketType: type, packet: PacketType.UserType, compressor: *ZlibCompressor) !void {
                const actual_len = @intCast(i32, PacketType.size(packet));
                if (actual_len < compression_threshold) {
                    try mcp.VarInt.write(actual_len, &self.writer);
                    try self.writer.writeByte(0x00); // varint of 0
                    try PacketType.write(packet, &self.writer);
                } else {
                    // not sure if compression works and im not sure ill try for a while

                    // we need the length of the compressed data :(
                    var compressed_data = try std.ArrayList(u8).initCapacity(compressor.allocator, threshold);
                    // yeah i guess ill just use the compressors allocator. we'll see how that goes
                    defer compressed_data.deinit();
                    defer compressor.reset();
                    var compressed_data_writer = compressed_data.writer();
                    try PacketType.write(packet, &compressor.writer(compressed_data_writer));
                    try mcp.VarInt.write(@intCast(i32, compressed_data.items.len + mcp.VarInt.size(actual_len)), &self.writer);
                    try mcp.VarInt.write(actual_len, &self.writer);
                    try compressor.flush(compressed_data_writer);
                    try self.writer.writeAll(compressed_data.items);
                }
            }
            pub fn intoUncompressed(self: *Self) PacketClient(ReaderType, WriterType, null) {
                return .{
                    .reader = self.reader,
                    .writer = self.writer,
                };
            }
        } else struct {
            pub fn readPacketLen(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType.UserType {
                var reader = std.io.limitedReader(self.reader, len);
                const packet_res = PacketType.deserialize(alloc, &reader.reader());
                if (meta.isError(packet_res)) _ = packet_res catch |err| return err;
                var packet = packet_res catch unreachable;
                return packet;
            }

            pub fn writePacket(self: *Self, comptime PacketType: type, packet: PacketType.UserType) !void {
                try mcp.VarInt.write(@intCast(i32, PacketType.size(packet)), &self.writer);
                try PacketType.write(packet, &self.writer);
            }
            pub fn intoCompressed(self: *Self, comptime threshold: i32) PacketClient(ReaderType, WriterType, threshold) {
                return .{
                    .reader = self.reader,
                    .writer = self.writer,
                };
            }
        };
    };
}

pub fn packetClient(reader: anytype, writer: anytype, comptime threshold: ?i32) PacketClient(@TypeOf(reader), @TypeOf(writer), threshold) {
    return .{
        .reader = reader,
        .writer = writer,
    };
}
