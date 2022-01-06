const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;

const mcp = @import("mcproto.zig");

pub fn PacketClient(comptime ReaderType: type, comptime WriterType: type) type {
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
        pub fn readPacketLen(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType.UserType {
            var reader = std.io.limitedReader(self.reader, len);
            return try PacketType.deserialize(alloc, &reader.reader());
        }

        pub fn writePacket(self: *Self, comptime PacketType: type, packet: PacketType.UserType) !void {
            try mcp.VarInt.write(@intCast(i32, PacketType.size(packet)), &self.writer);
            try PacketType.write(packet, &self.writer);
        }
    };
}

pub fn packetClient(reader: anytype, writer: anytype) PacketClient(@TypeOf(reader), @TypeOf(writer)) {
    return .{
        .reader = reader,
        .writer = writer,
    };
}
