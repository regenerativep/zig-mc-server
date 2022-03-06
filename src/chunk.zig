const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;

const mcp = @import("mcproto.zig");
const serde = @import("serde.zig");
const VarNum = @import("varnum.zig").VarNum;
const VarInt = VarNum(i32);
const VarLong = VarNum(i64);
const nbt = @import("nbt.zig");
pub const blockgen = @import("gen/blocks.zig");
pub const GlobalPaletteMaxId = blockgen.GlobalPaletteMaxId;
pub const GlobalPaletteInt = blockgen.GlobalPaletteInt;

pub const Ds = serde.DefaultSpec;

// yeah its hard coded
pub const MAX_HEIGHT = 256;
pub const MIN_Y = 0;

pub fn isAir(val: GlobalPaletteInt) bool {
    const result = blockgen.BlockMaterial.fromGlobalPaletteId(val) catch return false;
    return switch (result) {
        .air, .cave_air, .void_air => true,
        else => false,
    };
}

pub const DEFAULT_FLAT_SECTIONS = [_]ChunkSection.UserType{
    .{
        .block_count = 4096,
        .block_states = .{
            .bits_per_entry = 0,
            .palette = .{ .single = 6 }, // andesite
            .data_array = &[_]GlobalPaletteInt{},
        },
        .biomes = .{
            .bits_per_entry = 0,
            .palette = .{ .single = 1 }, // plains?
            .data_array = &[_]GlobalPaletteInt{},
        },
    },
} ++ [_]ChunkSection.UserType{
    .{
        .block_count = 0,
        .block_states = .{
            .bits_per_entry = 0,
            .palette = .{ .single = 0 },
            .data_array = &[_]GlobalPaletteInt{},
        },
        .biomes = .{
            .bits_per_entry = 0,
            .palette = .{ .single = 1 },
            .data_array = &[_]GlobalPaletteInt{},
        },
    },
} ** (section_count - 1);

// copied from stdlib
const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
fn numMasks(bit_length: usize) usize {
    return (bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
}

const section_count = MAX_HEIGHT / 16;

pub const Chunk = struct {
    chunk_x: i32,
    chunk_z: i32,
    block_entities: std.ArrayListUnmanaged(BlockEntity.UserType),

    // yeah, so, height is hardcoded as 0-256. we'll just use an array
    sections: [section_count]ChunkSection.UserType,
    height_map: [16][16]MbInt,

    const MbInt = std.math.IntFittingRange(0, MAX_HEIGHT - 1);
    const ratio = 64 / meta.bitCount(MbInt);
    const long_count = ((16 * 16) + (ratio - 1)) / ratio;

    const Self = @This();

    pub fn generateHeightMap(sections: []const ChunkSection.UserType) [16][16]MbInt {
        // TODO: this is probably not compliant to what a client is actually expecting from MOTION_BLOCKING
        var map = [_][16]MbInt{[_]MbInt{0} ** 16} ** 16;
        var i: usize = sections.len;
        while (i > 0) {
            i -= 1;
            const section = sections[i];
            if (section.block_states.palette == .single) {
                if (!isAir(@intCast(GlobalPaletteInt, section.block_states.palette.single))) {
                    for (map) |*row| {
                        for (row) |*cell| {
                            cell.* = @intCast(MbInt, (i + 1) * 16);
                        }
                    }
                    break;
                }
            } else {
                var z: u4 = 0;
                while (z < 16) : (z += 1) {
                    var x: u4 = 0;
                    while (x < 16) : (x += 1) {
                        var y5: u5 = 16;
                        while (y5 > 0) {
                            y5 -= 1;
                            const y = @intCast(u4, y5);
                            if (!isAir(section.block_states.entryAt(x, y, z))) {
                                map[z][x] = @intCast(MbInt, y + (16 * i) + 1);
                            }
                        }
                    }
                }
            }
        }
        return map;
    }
    pub fn generateCompactHeightMap(height_map: [16][16]MbInt) [long_count]i64 {
        var longs: [long_count]i64 = undefined;
        //var total: usize = 0;
        var x: u4 = 0;
        var z: u4 = 0;
        var i: usize = 0;
        while (i < long_count) : (i += 1) {
            var current_long: i64 = 0;
            var j: usize = 0;
            while (j < ratio) : (j += 1) {
                const height = height_map[z][x];
                current_long = (current_long << meta.bitCount(MbInt)) | height;
                if (x == 15) {
                    x = 0;
                    if (z == 15) {
                        break;
                    } else {
                        z += 1;
                    }
                } else {
                    x += 1;
                }
            }
            const remainder = 64 % meta.bitCount(MbInt);
            longs[i] = current_long << remainder;
        }
        return longs;
    }

    pub fn send(self: Self, cl: anytype) !void {
        var longs = generateCompactHeightMap(self.height_map);

        const mask_count = comptime numMasks(section_count + 2);
        var sky_light_masks = [_]MaskInt{0} ** mask_count;
        var sky_light_mask = std.DynamicBitSetUnmanaged{ .masks = &sky_light_masks, .bit_length = section_count + 2 };
        sky_light_mask.setValue(0, false);
        sky_light_mask.setValue(1, false);

        var empty_sky_light_masks: [mask_count]MaskInt = undefined;
        std.mem.copy(MaskInt, &empty_sky_light_masks, &sky_light_masks);
        var empty_sky_light_mask = std.DynamicBitSetUnmanaged{ .masks = &empty_sky_light_masks, .bit_length = section_count + 2 };
        empty_sky_light_mask.toggleAll();

        var block_light_masks = [_]MaskInt{0} ** mask_count;
        var block_light_mask = std.DynamicBitSetUnmanaged{ .masks = &block_light_masks, .bit_length = section_count + 2 };
        var empty_block_light_masks: [mask_count]MaskInt = undefined;
        std.mem.copy(MaskInt, &empty_block_light_masks, &block_light_masks);
        var empty_block_light_mask = std.DynamicBitSetUnmanaged{ .masks = &empty_block_light_masks, .bit_length = section_count + 2 };
        empty_block_light_mask.toggleAll();

        const full_light = [_]u8{0xFF} ** 2048;
        const sky_light_arrays = [_][]const u8{&full_light} ** section_count; // section count + 2 - 2

        try cl.writePacket(mcp.P.CB, mcp.P.CB.UserType{
            .chunk_data_and_update_light = .{
                .chunk_x = self.chunk_x,
                .chunk_z = self.chunk_z,
                .heightmaps = .{
                    .MOTION_BLOCKING = &longs,
                    .WORLD_SURFACE = null,
                },
                .data = &self.sections,
                .block_entities = self.block_entities.items,
                .trust_edges = true,
                .sky_light_mask = sky_light_mask,
                .block_light_mask = block_light_mask,
                .empty_sky_light_mask = empty_sky_light_mask,
                .empty_block_light_mask = empty_block_light_mask,
                .sky_light_arrays = std.mem.span(&sky_light_arrays),
                .block_light_arrays = &[_][]const u8{},
            },
        });
    }
    // TODO: tbc here
};

pub const BlockEntity = Ds.Spec(struct {
    xz: packed struct {
        z: u4,
        x: u4,
    },
    z: i16,
    entity_type: VarInt,
    data: nbt.DynamicCompound,
});

pub const PaletteType = enum {
    Block,
    Biome,
};
pub const PalettedContainerError = error{
    InvalidBitCount,
};

pub fn readCompactedDataArray(comptime T: type, alloc: Allocator, reader: anytype, bit_count: usize) ![]T {
    const long_count = @intCast(usize, try VarInt.deserialize(alloc, reader));
    const total_per_long = 64 / bit_count;
    var data = try std.ArrayList(T).initCapacity(alloc, long_count * total_per_long);
    const shift_amount = @intCast(u6, bit_count);
    defer data.deinit();
    const mask: u64 = (1 << shift_amount) - 1;
    var i: usize = 0;
    while (i < long_count) : (i += 1) {
        const long = try reader.readIntBig(u64);
        var j: usize = 0;
        while (j < total_per_long) : (j += 1) {
            data.appendAssumeCapacity(@intCast(T, long & mask));
            long = long >> shift_amount;
        }
    }
    try data.resize((data.items.len / 64) * 64);
    return data.toOwnedSlice();
}
pub fn writeCompactedDataArray(comptime T: type, data: []T, writer: anytype, bit_count: usize) !void {
    const total_per_long = 64 / bit_count;
    const long_count = (data.len + (total_per_long - 1)) / total_per_long;
    try VarInt.write(@intCast(i32, long_count), writer);
    const shift_amount = @intCast(u6, bit_count);
    var i: usize = 0;
    while (i < long_count) : (i += 1) {
        var long: u64 = 0;
        var j: u6 = 0;
        while (j < total_per_long) : (j += 1) {
            const ind = i * total_per_long + j;
            if (ind < data.len) {
                long = long | (@intCast(u64, data[ind]) << (j * shift_amount));
            } else {
                break;
            }
        }
        try writer.writeIntBig(u64, long);
    }
}
pub fn compactedDataArraySize(comptime T: type, data: []T, bit_count: usize) usize {
    if (bit_count == 0) return 1;
    const total_per_long = 64 / bit_count;
    const long_count = (data.len + (total_per_long - 1)) / total_per_long;
    return VarInt.size(@intCast(i32, long_count)) + @sizeOf(u64) * long_count;
}

pub fn PalettedContainer(comptime which_palette: PaletteType) type {
    return struct {
        bits_per_entry: u8,
        palette: Palette.UserType,
        data_array: []GlobalPaletteInt,

        pub const Palette = serde.Union(Ds, union(enum) {
            single: VarInt,
            indirect: serde.PrefixedArray(Ds, VarInt, VarInt),
            direct: void,
        });
        const max_bits = switch (which_palette) {
            .Block => meta.bitCount(GlobalPaletteInt),
            .Biome => 6,
        }; // 61 total biomes i think (which means if just 4 more are added, this needs to be updated)
        const max_indirect_bits = switch (which_palette) {
            .Block => 8,
            .Biome => 3,
        }; // https://wiki.vg/Chunk_Format

        pub const UserType = @This();
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeByte(self.bits_per_entry);
            try Palette.write(self.palette, writer);
            const actual_bits = switch (self.bits_per_entry) {
                0 => 0,
                1...max_indirect_bits => |b| if (which_palette == .Block) (if (b < 4) 4 else b) else b,
                (max_indirect_bits + 1)...max_bits => max_bits,
                else => return error.InvalidBitCount,
            };
            if (actual_bits == 0) {
                try writer.writeByte(0);
            } else {
                try writeCompactedDataArray(GlobalPaletteInt, self.data_array, writer, actual_bits);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            var self: UserType = undefined;
            self.bits_per_entry = try reader.readByte();
            var actual_bits: usize = undefined;
            var tag: meta.Tag(Palette.UserType) = undefined;
            switch (self.bits_per_entry) {
                0 => {
                    actual_bits = 0;
                    tag = .single;
                },
                1...max_indirect_bits => |b| {
                    actual_bits = if (which_palette == .Block) (if (b < 4) 4 else b) else b;
                    tag = .indirect;
                },
                (max_indirect_bits + 1)...max_bits => {
                    actual_bits = max_bits;
                    tag = .direct;
                },
                else => return error.InvalidBitCount,
            }
            self.palette = try Palette.deserialize(alloc, reader, @enumToInt(tag));
            if (actual_bits == 0) {
                _ = try VarInt.deserialize(alloc, reader);
                self.data_array = &[_]u8{};
            } else {
                self.data_array = try readCompactedDataArray(GlobalPaletteInt, alloc, reader, actual_bits);
            }
            return self;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            Palette.deinit(self.palette, alloc);
            alloc.free(self.data_array);
        }
        pub fn size(self: UserType) usize {
            const actual_bits = switch (self.bits_per_entry) {
                0 => 0,
                1...max_indirect_bits => |b| if (which_palette == .Block) (if (b < 4) 4 else b) else b,
                (max_indirect_bits + 1)...max_bits => max_bits,
                else => unreachable,
            };
            return 1 + Palette.size(self.palette) + compactedDataArraySize(GlobalPaletteInt, self.data_array, actual_bits);
        }

        pub const AxisLocation = switch (which_palette) {
            .Block => u4,
            .Biome => u2,
        };
        pub const AxisWidth = switch (which_palette) {
            .Block => 4,
            .Biome => 2,
        };
        pub fn entryAt(self: UserType, x: AxisLocation, y: AxisLocation, z: AxisLocation) GlobalPaletteInt {
            const air = blockgen.BlockMaterial.toDefaultGlobalPaletteId(.air); // TODO: use cave and void air as well?
            const ind: usize = @intCast(usize, x) + (AxisWidth * @intCast(usize, z)) + ((AxisWidth * AxisWidth) * @intCast(usize, y));
            switch (self.palette) { // TODO: it might also work to just directly access data_array instead of making sure block_count is followed
                .single => |id| return @intCast(GlobalPaletteInt, id),
                .indirect => |ids| {
                    if (ind >= self.data_array.len) {
                        return air;
                    } else {
                        return @intCast(GlobalPaletteInt, ids[@intCast(usize, self.data_array[ind])]);
                    }
                },
                .direct => return if (ind >= self.data_array.len) air else self.data_array[ind],
            }
        }
    };
}

pub const ChunkSection = Ds.Spec(struct {
    block_count: i16,
    block_states: PalettedContainer(.Block),
    biomes: PalettedContainer(.Biome),
});
