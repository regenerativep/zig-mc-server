const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");
const mcp = @import("mcproto.zig");

pub const McClientReadError = error{
    LegacyHandshake,
};
pub fn McClient(comptime ReaderType: type, comptime WriterType: type) type {
    return struct {
        reader: ReaderType,
        writer: WriterType,
        buffer: std.ArrayListUnmanaged(u8) = .{},

        const Self = @This();
        pub fn read_handshake_packet(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType {
            const first_byte = try self.reader.readByte();
            var len: i32 = undefined;
            if (first_byte == 0xFE) {
                // legacy server ping. we'll just throw error if we get one
                _ = try self.reader.readByte();
                return McClientReadError.LegacyHandshake;
            } else {
                len = try mcp.readVarNum(i32, self.reader, null, first_byte);
            }
            return self.read_packet_len(PacketType, alloc, @intCast(usize, len));
        }
        pub fn read_packet(self: *Self, comptime PacketType: type, alloc: Allocator) !PacketType {
            var len: i32 = try mcp.readVarNum(i32, self.reader, null, null);
            return self.read_packet_len(PacketType, alloc, @intCast(usize, len));
        }
        pub fn read_packet_len(self: *Self, comptime PacketType: type, alloc: Allocator, len: usize) !PacketType {
            std.log.info("got packet len {}", .{len});
            try self.buffer.resize(alloc, len);
            try self.reader.readNoEof(self.buffer.items);
            std.log.info("packet contents: {any}", .{self.buffer.items});
            var raw_reader = std.io.fixedBufferStream(self.buffer.items).reader();
            return (try serde.SerdeTaggedUnion(mcp.VarInt, PacketType).deserialize(alloc, &raw_reader)).data;
        }
        pub fn write_packet(self: *Self, comptime PacketType: type, alloc: Allocator, packet: PacketType) !void {
            self.buffer.clearRetainingCapacity();
            try (serde.SerdeTaggedUnion(mcp.VarInt, PacketType){ .data = packet }).write(self.buffer.writer(alloc));
            try mcp.writeVarNum(i32, self.writer, @intCast(i32, self.buffer.items.len), null);
            try self.writer.writeAll(self.buffer.items);
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.buffer.deinit(alloc);
        }
    };
}
pub fn mcClient(reader: anytype, writer: anytype) McClient(@TypeOf(reader), @TypeOf(writer)) {
    return .{
        .reader = reader,
        .writer = writer,
    };
}

pub fn handle_client(alloc: Allocator, conn: net.StreamServer.Connection) !void {
    std.log.info("connection", .{});
    //var cl = mcClient(std.io.bufferedReader(conn.stream.reader()).reader(), std.io.bufferedWriter(conn.stream.writer()).writer());
    var cl = mcClient(conn.stream.reader(), conn.stream.writer());
    defer cl.deinit(alloc);

    const handshake_packet = try cl.read_handshake_packet(mcp.ServerboundHandshakingPacket, alloc);
    std.log.info("packet data: {any}", .{handshake_packet});
    switch (handshake_packet.Handshake.next_state.data) {
        .Status => {
            const request_packet = try cl.read_packet(mcp.ServerboundStatusPacket, alloc);
            std.log.info("packet data: {any}", .{request_packet});
            _ = request_packet;
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
            const response_packet = mcp.ClientboundStatusPacket{ .Response = mcp.PString{ .data = response_data[0..] } };
            try cl.write_packet(mcp.ClientboundStatusPacket, alloc, response_packet);
            const ping_packet = try cl.read_packet(mcp.ServerboundStatusPacket, alloc);
            std.log.info("packet data: {any}", .{ping_packet});
            try cl.write_packet(mcp.ClientboundStatusPacket, alloc, mcp.ClientboundStatusPacket{ .Pong = ping_packet.Ping });
        },
        .Login => {
            return;
        },
    }
    //if (handshake_packet.Handshake.next_state.data != mcp.ServerboundHandshakingPacket.NextState.Status) {
    //    std.log.info("not a status", .{});
    //    return;
    //}
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25565);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    //var connected_clients = std.AutoHashMap(net.Address, net.Stream).init(alloc);
    //defer connected_clients.deinit();

    try server.listen(address);

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        handle_client(alloc, conn) catch |err| {
            std.log.err("failed to handle client: {}", .{err});
        };
        std.log.info("closed client", .{});
    }
}
