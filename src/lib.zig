const mcp = @import("mcp");
const mcv = mcp.vlatest;

pub const XevClient = @import("xevclient.zig").XevClient;

pub const config = @import("config.zig");

pub const Client = @import("client.zig");
pub const Entity = @import("entity.zig");

pub const Command = @import("commands.zig").Command;

pub const ChunkPosition = @import("chunk.zig").ChunkPosition;
pub const ChunkColumn = @import("chunk.zig").ChunkColumn;

pub const Position = mcv.V3(f64);

pub const Server = @import("server.zig");

test {
    _ = Client;
    _ = Entity;
    _ = config;
    _ = Command;
}
