const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

const mcp = @import("mcp");
const mcio = mcp.packetio;
const mcv = mcp.vlatest;

const Server = @import("lib.zig").Server;

pub const ChunkPosition = struct { x: isize, z: isize };
pub const BlockAxis = mcp.chunk.BlockAxis;
pub const BlockY = mcp.chunk.BlockY;

/// a location of a block within a given chunk column
pub const BlockPosition = struct {
    x: BlockAxis,
    z: BlockAxis,
    y: BlockY,
};

pub const ChunkColumn = struct {
    pub const Hard = *mcp.chunk.Column;
    pub const Soft = struct {
        pub const Block = struct {
            position: BlockPosition,
            state: mcv.BlockState.Id,
        };

        parent: *ChunkColumn,
        blocks: std.MultiArrayList(Block) = .{},
    };
    lock: std.Thread.RwLock = .{},
    position: ChunkPosition,

    inner: union(enum) {
        hard: Hard,
        soft: Soft,
    },

    viewers: usize = 0,

    /// A partial clone that only stores modifications and a reference to the original
    /// data.
    pub fn softClone(self: *ChunkColumn) ChunkColumn {
        return .{
            .position = self.position,
            .viewers = self.viewers,
            .inner = .{ .soft = .{ .parent = self } },
        };
    }

    pub fn getBlock(self: ChunkColumn, position: BlockPosition) mcv.BlockState.Id {
        switch (self.inner) {
            .hard => |d| return d.blockAt(position.x, position.z, position.y),
            .soft => |d| {
                const slice = d.blocks.items(.position);
                var i = slice.len;
                while (i > 0) {
                    i -= 1;
                    if (std.meta.eql(slice[i], position)) {
                        return d.blocks.items(.state)[i];
                    }
                }
                return d.parent.getBlock(position);
            },
        }
    }

    pub fn setBlock(
        self: *ChunkColumn,
        a: Allocator,
        position: BlockPosition,
        value: mcv.BlockState.Id,
    ) void {
        switch (self.inner) {
            .hard => |d| d.setBlock(position.x, position.z, position.y, value),
            .soft => |*d| {
                const slice = d.blocks.items(.position);
                var i = slice.len;
                while (i > 0) {
                    i -= 1;
                    if (std.meta.eql(slice[i], position)) {
                        d.blocks.items(.state)[i] = value;
                        return;
                    }
                }
                // TODO: or we could just add onto the end and just leave previous
                //     sets to the same position be?
                try d.blocks.append(a, .{ .position = position, .state = value });
            },
        }
    }

    pub fn deinit(self: *ChunkColumn, a: Allocator) void {
        switch (self.inner) {
            .hard => |d| {
                d.deinit(a);
                a.destroy(d);
            },
            .soft => |*d| d.blocks.deinit(a),
        }
    }
};
