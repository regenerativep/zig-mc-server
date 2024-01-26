const std = @import("std");

const mcp = @import("mcp");
const mcs = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const a = gpa.allocator();

    const config_text = std.fs.cwd().readFileAlloc(a, "config.txt", 1 << 20) catch "";
    defer a.free(config_text);
    var config_tokenizer = mcs.config.Tokenizer{ .text = config_text };
    var config_ast = try mcs.config.Ast.parse(a, &config_tokenizer);
    defer config_ast.deinit(a);

    var ip_str: []const u8 = "127.0.0.1";
    if (config_ast.object.get("ip")) |ip_node| {
        if (ip_node == .string) {
            ip_str = ip_node.string;
        } else {
            return error.InvalidIp;
        }
    }
    var port: u16 = 25565;
    blk: {
        if (config_ast.object.get("port")) |port_node| {
            if (port_node == .integer) {
                if (std.math.cast(u16, port_node.integer)) |read_port| {
                    port = read_port;
                    break :blk;
                }
            }
            return error.InvalidPort;
        }
    }

    var height: mcp.chunk.UBlockY = 384;
    if (config_ast.object.get("height")) |height_node| blk: {
        if (height_node == .integer) {
            if (std.math.cast(mcp.chunk.UBlockY, height_node.integer)) |read_height| {
                height = read_height;
                break :blk;
            }
        }
        return error.InvalidHeight;
    }
    var min_y: mcp.chunk.BlockY = -64;
    if (config_ast.object.get("min_y")) |min_y_node| blk: {
        if (min_y_node == .integer) {
            if (std.math.cast(mcp.chunk.BlockY, min_y_node.integer)) |read_min_y| {
                min_y = read_min_y;
                break :blk;
            }
        }
        return error.InvalidHeight;
    }

    const address = try std.net.Address.resolveIp(ip_str, port);

    var server = mcs.Server{
        .allocator = gpa.allocator(),
        .world_min_y = min_y,
        .world_height = height,
    };

    std.log.info("Initializing server on {}", .{address});
    try server.init(address);
    defer server.deinit();

    std.log.info("Starting server", .{});
    try server.start();
}
