const std = @import("std");

const mcs = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var server = mcs.Server{
        .allocator = gpa.allocator(),
    };

    std.log.info("Initializing server", .{});
    try server.init(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 25565));
    defer server.deinit();

    std.log.info("Starting server", .{});
    try server.start();
}
