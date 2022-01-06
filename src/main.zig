const std = @import("std");
const net = std.net;
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");
const mcp = @import("mcproto.zig");
const mcn = @import("mcnet.zig");

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
    try cl.writePacket(mcp.L.CB, mcp.L.CB.UserType{ .Disconnect = "{\"text\":\"your not allowed lol\"}" });
}

pub fn handleClient(alloc: Allocator, conn: net.StreamServer.Connection) !void {
    std.log.info("connection", .{});
    var cl = mcn.packetClient(conn.stream.reader(), conn.stream.writer());
    const handshake_packet = try cl.readHandshakePacket(mcp.H.SB, alloc);
    std.log.info("handshake: {any}", .{handshake_packet});
    if (handshake_packet == .Legacy) {
        std.log.info("legacy ping...", .{});
        return;
    }
    switch (handshake_packet.Handshake.next_state) {
        .Status => try handleStatus(alloc, &cl),
        .Login => try handleLogin(alloc, &cl),
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
