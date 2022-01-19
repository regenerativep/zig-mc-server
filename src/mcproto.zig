const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const unicode = std.unicode;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Uuid = @import("uuid6");

const serde = @import("serde.zig");
const nbt = @import("nbt.zig");
const VarNum = @import("varnum.zig").VarNum;

pub const VarInt = VarNum(i32);
pub const VarLong = VarNum(i64);

pub const PStringError = error{
    StringTooLarge,
};

pub fn PStringMax(comptime max_len_opt: ?usize) type {
    return struct {
        pub const UserType = []const u8;
        pub fn write(self: UserType, writer: anytype) !void {
            try VarInt.write(@intCast(i32, self.len), writer);
            try writer.writeAll(self);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const len = try VarInt.deserialize(alloc, reader);
            if (max_len_opt) |max_len| {
                if (len > max_len) {
                    return error.StringTooLarge;
                }
            }
            var data = try std.ArrayList(u8).initCapacity(alloc, @intCast(usize, len));
            defer data.deinit();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const first_byte = try reader.readByte();
                const codepoint_len = try unicode.utf8ByteSequenceLength(first_byte);
                try data.ensureUnusedCapacity(codepoint_len);
                data.appendAssumeCapacity(first_byte);
                if (codepoint_len > 0) {
                    var codepoint_buf: [3]u8 = undefined;
                    try reader.readNoEof(codepoint_buf[0 .. codepoint_len - 1]);
                    data.appendSliceAssumeCapacity(codepoint_buf[0 .. codepoint_len - 1]);
                }
            }
            return data.toOwnedSlice();
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            alloc.free(self);
        }
        pub fn size(self: UserType) usize {
            return VarInt.size(@intCast(i32, self.len)) + self.len;
        }
    };
}

pub const PString = PStringMax(null);
pub const Identifier = PStringMax(32767);

pub const UuidSpec = struct {
    pub const UserType = Uuid;
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeAll(&self.bytes);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        _ = alloc;
        var uuid: Uuid = undefined;
        try reader.readNoEof(&uuid.bytes);
        return uuid;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return @sizeOf(UserType);
    }
};

// referenced https://github.com/AdoptOpenJDK/openjdk-jdk8u/blob/9a91972c76ddda5c1ce28b50ca38cbd8a30b7a72/jdk/src/share/classes/java/util/UUID.java#L153-L175
pub fn uuidFromUsername(username: []const u8) !Uuid {
    var username_buf: [16 + ("OfflinePlayer:").len]u8 = undefined;
    const padded_username = try std.fmt.bufPrint(&username_buf, "OfflinePlayer:{s}", .{username});
    var uuid: Uuid = undefined;
    std.crypto.hash.Md5.hash(padded_username, &uuid.bytes, .{});
    uuid.setVersion(3);
    uuid.setVariant(.rfc4122);
    return uuid;
}

pub const DimensionCodec = struct {
    @"minecraft:dimension_type": struct { @"type": []const u8 = "minecraft:dimension_type", value: []DimensionType },
    @"minecraft:worldgen/biome": struct {
        @"type": []const u8 = "minecraft:worldgen/biome",
        value: []Biome,
    },
    pub const DimensionType = struct {
        name: []const u8,
        id: i32,
        element: Element,

        pub const Element = struct {
            piglin_safe: bool,
            natural: bool,
            ambient_light: f32,
            fixed_time: ?i64 = null,
            infiniburn: []const u8,
            respawn_anchor_works: bool,
            has_skylight: bool,
            bed_works: bool,
            effects: []const u8,
            has_raids: bool,
            min_y: i32,
            height: i32,
            logical_height: i32,
            coordinate_scale: f32,
            ultrawarm: bool,
            has_ceiling: bool,
        };
    };
    pub const Biome = struct {
        name: []const u8,
        id: i32,
        element: Element,

        pub const Element = struct {
            precipitation: []const u8,
            depth: f32,
            temperature: f32,
            scale: f32,
            downfall: f32,
            category: []const u8,
            temperature_modifier: ?[]const u8 = null,
            effects: Effects,
            particle: ?Particle,
            pub const Effects = struct {
                sky_color: i32,
                water_fog_color: i32,
                fog_color: i32,
                water_color: i32,
                foliage_color: ?i32 = null,
                grass_color: ?i32 = null,
                grass_color_modifier: ?[]const u8 = null,
                music: ?Music = null,
                ambient_sound: ?[]const u8 = null,
                additions_sound: ?SoundAdditions = null,
                mood_sound: ?MoodSound = null,
                pub const Music = struct {
                    replace_curent_music: bool,
                    sound: []const u8,
                    max_delay: i32,
                    min_delay: i32,
                };
                pub const SoundAdditions = struct {
                    sound: []const u8,
                    tick_chance: f64,
                };
                pub const MoodSound = struct {
                    sound: []const u8,
                    tick_delay: i32,
                    offset: f64,
                    block_search_extent: i32,
                };
            };
            pub const Particle = struct {
                probability: f32,
                options: []const u8,
            };
        };
    };
};
pub fn default_dimension_codec() DimensionCodecSpec.UserType {
    return .{
        .@"minecraft:dimension_type" = .{
            .@"type" = "minecraft:dimension_type",
            .value = &[_]meta.Child(DimensionCodecSpec.Specs[0].Specs[1].UserType){
                .{
                    .name = "minecraft:overworld",
                    .id = 0,
                    .element = .{
                        .piglin_safe = false,
                        .natural = true,
                        .ambient_light = 0.0,
                        .infiniburn = "minecraft:infiniburn_overworld",
                        .respawn_anchor_works = false,
                        .has_skylight = true,
                        .bed_works = true,
                        .effects = "minecraft:overworld",
                        .has_raids = true,
                        .min_y = 0,
                        .height = 256,
                        .logical_height = 256,
                        .coordinate_scale = 1.0,
                        .ultrawarm = false,
                        .has_ceiling = false,
                        .fixed_time = null,
                    },
                },
            },
        },
        .@"minecraft:worldgen/biome" = .{
            .@"type" = "minecraft:worldgen/biome",
            .value = &[_]meta.Child(DimensionCodecSpec.Specs[1].Specs[1].UserType){
                .{
                    .name = "minecraft:plains",
                    .id = 1,
                    .element = .{
                        .precipitation = "rain",
                        .effects = .{
                            .sky_color = 0x78A7FF,
                            .water_fog_color = 0x050533,
                            .fog_color = 0xC0D8FF,
                            .water_color = 0x3F76E4,
                            .mood_sound = .{
                                .tick_delay = 6000,
                                .offset = 2.0,
                                .sound = "minecraft:ambient.cave",
                                .block_search_extent = 8,
                            },
                            .foliage_color = null,
                            .grass_color = null,
                            .grass_color_modifier = null,
                            .music = null,
                            .ambient_sound = null,
                            .additions_sound = null,
                        },
                        .depth = 0.125,
                        .temperature = 0.8,
                        .scale = 0.05,
                        .downfall = 0.4,
                        .category = "plains",
                        .temperature_modifier = null,
                        .particle = null,
                    },
                },
            },
        },
    };
}

pub const Slot = Ds.Spec(?SlotData);
pub const SlotData = struct {
    item_id: VarInt,
    item_count: i8,
    nbt: nbt.DynamicCompoundSpec,
};

pub const Ingredient = serde.PrefixedArray(Ds, VarInt, Slot);
pub const CraftingShaped = struct {
    // a whole custom type all cause group was put in between width+height and ingredients
    width: VarInt.UserType,
    height: VarInt.UserType,
    group: PString.UserType,
    ingredients: []Ingredient.UserType,
    result: Slot.UserType,

    pub const UserType = @This();
    pub fn write(self: UserType, writer: anytype) !void {
        try VarInt.write(self.width, writer);
        try VarInt.write(self.height, writer);
        try PString.write(self.group, writer);
        for (self.ingredients) |elem| {
            try Ingredient.write(elem, writer);
        }
        try Slot.write(self.result, writer);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        var self: UserType = undefined;
        self.width = try VarInt.deserialize(alloc, reader);
        self.height = try VarInt.deserialize(alloc, reader);
        self.group = try PString.deserialize(alloc, reader);
        errdefer PString.deinit(self.group, alloc);
        const total = @intCast(usize, self.width * self.height);
        self.ingredients = try alloc.alloc(Ingredient.UserType, total);
        errdefer alloc.free(self.ingredients);
        for (self.ingredients) |*elem, i| {
            errdefer {
                var ind: usize = 0;
                while (ind < i) : (ind += 1) {
                    Ingredient.deinit(self.ingredients[i], alloc);
                }
            }
            elem.* = try Ingredient.deserialize(alloc, reader);
        }
        self.result = try Slot.deserialize(alloc, reader);
        return self;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        PString.deinit(self.group, alloc);
        for (self.ingredients) |elem| {
            Ingredient.deinit(elem, alloc);
        }
        alloc.free(self.ingredients);
        Slot.deinit(self.result);
    }
    pub fn size(self: UserType) usize {
        var total_size: usize = VarInt.size(self.width) + VarInt.size(self.height) + PString.size(self.group) + Slot.size(self.result);
        var j: i32 = 0;
        while (j < self.height) : (j += 1) {
            var i: i32 = 0;
            while (i < self.width) : (i += 1) {
                total_size += Ingredient.size(self.ingredients[@intCast(usize, i) + @intCast(usize, j * self.width)]);
            }
        }
        return total_size;
    }
};

pub const Recipe = struct {
    type: Identifier.UserType,
    recipe_id: Identifier.UserType,
    data: RecipeData.UserType,

    pub const RecipeData = serde.UnionSpec(Ds, union(enum) {
        CraftingShapeless: struct {
            group: PString,
            ingredients: serde.PrefixedArray(Ds, VarInt, Ingredient),
            result: Slot,
        },
        CraftingShaped: CraftingShaped,
        CraftingSpecialArmorDye: void,
        CraftingSpecialBookCloning: void,
        CraftingSpecialMapCloning: void,
        CraftingSpecialMapExtending: void,
        CraftingSpecialFireworkRocket: void,
        CraftingSpecialFireworkStar: void,
        CraftingSpecialFireworkStarFade: void,
        CraftingSpecialRepairItem: void,
        CraftingSpecialTippedArrow: void,
        CraftingSpecialBannedDuplicate: void,
        CraftingSpecialBannerAddPattern: void,
        CraftingSpecialShieldDecoration: void,
        CraftingSpecialShulkerBoxColoring: void,
        CraftingSpecialSuspiciousStew: void,
        Smelting: Smelting,
        Blasting: Smelting,
        Smoking: Smelting,
        CampfireCooking: Smelting,
        Stonecutting: struct {
            group: PString,
            ingredient: Ingredient,
            result: Slot,
        },
        Smithing: struct {
            base: Ingredient,
            addition: Ingredient,
            result: Slot,
        },
        None: void,

        pub const Smelting = struct {
            group: PString,
            ingredient: Ingredient,
            result: Slot,
            experience: f32,
            cooking_time: VarInt,
        };
    });

    const IdentifierMap = std.ComptimeStringMap(meta.Tag(RecipeData.UserType), .{
        .{ "crafting_shapeless", .CraftingShapeless },
        .{ "crafting_shaped", .CraftingShaped },
        .{ "crafting_special_armordye", .CraftingSpecialArmorDye },
        .{ "crafting_special_bookcloning", .CraftingSpecialBookCloning },
        .{ "crafting_special_mapcloning", .CraftingSpecialMapCloning },
        .{ "crafting_special_mapextending", .CraftingSpecialMapExtending },
        .{ "crafting_special_firework_rocket", .CraftingSpecialFireworkRocket },
        .{ "crafting_special_firework_star", .CraftingSpecialFireworkStar },
        .{ "crafting_special_firework_star_fade", .CraftingSpecialFireworkStarFade },
        .{ "crafting_special_repairitem", .CraftingSpecialRepairItem },
        .{ "crafting_special_tippedarrow", .CraftingSpecialTippedArrow },
        .{ "crafting_special_bannerduplicate", .CraftingSpecialBannedDuplicate },
        .{ "crafting_special_banneraddpattern", .CraftingSpecialBannerAddPattern },
        .{ "crafting_special_shielddecoration", .CraftingSpecialShieldDecoration },
        .{ "crafting_special_shulkerboxcoloring", .CraftingSpecialShulkerBoxColoring },
        .{ "crafting_special_suspiciousstew", .CraftingSpecialSuspiciousStew },
        .{ "smelting", .Smelting },
        .{ "blasting", .Blasting },
        .{ "smoking", .Smoking },
        .{ "campfire_cooking", .CampfireCooking },
        .{ "stonecutting", .Stonecutting },
        .{ "smithing", .Smithing },
    });

    pub const UserType = @This();
    pub fn write(self: UserType, writer: anytype) !void {
        try Identifier.write(self.type, writer);
        try Identifier.write(self.recipe_id, writer);
        try RecipeData.write(self.data, writer);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        var self: UserType = undefined;
        self.type = try Identifier.deserialize(alloc, reader);
        errdefer Identifier.deinit(self.type, alloc);
        self.recipe_id = try Identifier.deserialize(alloc, reader);
        errdefer Identifier.deinit(self.recipe_id, alloc);
        const tag: meta.Tag(RecipeData.UserType) = IdentifierMap.get(self.type) orelse .None;
        self.data = try RecipeData.deserialize(alloc, reader, @enumToInt(tag));
        return self;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        Identifier.deinit(self.type, alloc);
        Identifier.deinit(self.recipe_id, alloc);
        RecipeData.deinit(self.data, alloc);
    }
    pub fn size(self: UserType) usize {
        return RecipeData.size(self.data) + Identifier.size(self.type) + Identifier.size(self.recipe_id);
    }
};

pub const Difficulty = enum(u8) {
    Peaceful = 0,
    Easy = 1,
    Normal = 2,
    Hard = 3,
};
pub const Gamemode = enum(u8) {
    Survival = 0,
    Creative = 1,
    Adventure = 2,
    Spectator = 3,
};
pub const PreviousGamemode = enum(i8) {
    None = -1,
    Survival = 0,
    Creative = 1,
    Adventure = 2,
    Spectator = 3,
};

pub const CommandNode = struct {
    // TODO: complete implementation https://wiki.vg/Command_Data
    flags: CommandNodeFlags,
    children: serde.PrefixedArray(Ds, VarInt, VarInt),
    redirect_node: ?VarInt,
    //name: ?PStringMax(32767),
    //parser: ?Identifier,
    //properties: ?
};
pub const CommandNodeFlags = packed struct {
    node_type: enum(u2) {
        Root = 0,
        Literal = 1,
        Argument = 2,
    },
    is_executable: bool,
    has_redirect: bool,
    has_suggestions_type: bool,
};

pub const DimensionCodecSpec = nbt.NbtSpec.Spec(DimensionCodec);
pub const TagsSpec = serde.PrefixedArray(Ds, VarInt, struct {
    tag_type: Identifier,
    tags: serde.PrefixedArray(Ds, VarInt, TagEntries),
});
pub const TagEntries = Ds.Spec(struct {
    tag_name: Identifier,
    entries: serde.PrefixedArray(Ds, VarInt, VarInt),
});
pub const PlayerInfoSpec = serde.TaggedUnionSpec(Ds, VarInt, union(PlayerInfoAction) {
    pub const PlayerInfoAction = enum(i32) {
        AddPlayer = 0,
        UpdateGamemode = 1,
        UpdateLatency = 2,
        UpdateDisplayName = 3,
        RemovePlayer = 4,
    };
    AddPlayer: PlayerInfoVariant(struct {
        name: PStringMax(16),
        properties: serde.PrefixedArray(Ds, VarInt, PlayerProperty),
        gamemode: Gamemode,
        ping: VarInt,
        display_name: ?PString,
    }),
    UpdateGamemode: PlayerInfoVariant(Gamemode),
    UpdateLatency: PlayerInfoVariant(VarInt),
    UpdateDisplayName: PlayerInfoVariant(?PString),
    RemovePlayer: PlayerInfoVariant(void),
    pub fn PlayerInfoVariant(comptime T: type) type {
        return serde.PrefixedArray(Ds, VarInt, struct {
            uuid: UuidSpec,
            data: T,
        });
    }
});
pub const PlayerProperty = Ds.Spec(struct {
    name: PStringMax(32767),
    value: PStringMax(32767),
    signature: ?PStringMax(32767),
});
pub const BlockEntity = Ds.Spec(struct {
    xz: packed struct {
        z: u4,
        x: u4,
    },
    z: i16,
    entity_type: VarInt,
    data: nbt.DynamicCompoundSpec,
});

pub const BitSet = struct {
    pub const UserType = std.DynamicBitSetUnmanaged;
    const mask_size = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
    const ratio = 64 / mask_size;
    pub fn write(self: UserType, writer: anytype) !void {
        const total_masks = (self.bit_length + (mask_size - 1)) / mask_size;
        const total_longs = (total_masks + (ratio - 1)) / ratio;
        try VarInt.write(@intCast(i32, total_longs), writer);
        var i: usize = 0;
        while (i < total_masks) : (i += ratio) {
            var current_long: u64 = 0;
            blk: {
                comptime var j = 0;
                inline while (j < ratio) : (j += 1) {
                    if (i + j < total_masks) {
                        current_long = (current_long << @truncate(u6, mask_size)) | self.masks[i];
                    } else {
                        break :blk;
                    }
                }
            }
            try writer.writeIntBig(i64, @bitCast(i64, current_long)); // might not need to bit cast
        }
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        const len = @intCast(usize, try VarInt.deserialize(alloc, reader));
        var bitset = UserType.initEmpty(alloc, len * 64);
        errdefer bitset.deinit(alloc);
        //const total_masks = (len + (mask_size - 1)) / mask_size;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            var long = @bitCast(u64, try reader.readIntBig(i64));
            comptime var j = 0;
            inline while (j < ratio) : (j += 1) {
                bitset.masks[i + j] = @truncate(UserType.MaskInt, long);
                long = long << mask_size;
            }
        }
        return bitset;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        self.deinit(alloc);
    }
    pub fn size(self: UserType) usize {
        const total_masks = (self.bit_length + (mask_size - 1)) / mask_size;
        const total_longs = (total_masks + (ratio - 1)) / ratio;
        return total_longs * @sizeOf(i64) + VarInt.size(@intCast(i32, total_longs));
    }
};
pub const Position = packed struct {
    y: i12,
    z: i26,
    x: i26,
};

test "packed position" {
    const pos = Position{
        .x = 5,
        .z = -12,
        .y = -1,
    };
    const x = @intCast(u64, @bitCast(u26, pos.x));
    const z = @intCast(u64, @bitCast(u26, pos.z));
    const y = @intCast(u64, @bitCast(u12, pos.y));
    const expected: u64 = ((x & 0x3FFFFFF) << 38) | ((z & 0x3FFFFFF) << 12) | (y & 0xFFF);
    try testing.expectEqual(expected, @bitCast(u64, pos));
}

pub const ChatMode = enum(i32) {
    Enabled = 0,
    CommandsOnly = 1,
    Hidden = 2,
};
pub const DisplayedSkinParts = packed struct {
    cape: bool,
    jacket: bool,
    left_sleeve: bool,
    right_sleeve: bool,
    left_pants_leg: bool,
    right_pants_leg: bool,
    hat: bool,
};
pub const MainHand = enum(i32) {
    Left = 0,
    Right = 1,
};
pub const ClientStatus = enum(i32) {
    PerformRespawn = 0,
    RequestStats = 1,
};

pub const GlobalPaletteMaxId = 20341; // https://wiki.vg/Data_Generators#Blocks_report . got this from my 1.18.1 server jar
pub const GlobalPaletteInt = std.math.IntFittingRange(0, GlobalPaletteMaxId);
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

pub fn PalettedContainerSpec(comptime which_palette: PaletteType) type {
    return struct {
        bits_per_entry: u8,
        palette: Palette.UserType,
        data_array: []GlobalPaletteInt,

        pub const Palette = serde.UnionSpec(Ds, union(enum) {
            Single: VarInt,
            Indirect: serde.PrefixedArray(Ds, VarInt, VarInt),
            Direct: void,
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
                    tag = .Single;
                },
                1...max_indirect_bits => |b| {
                    actual_bits = if (which_palette == .Block) (if (b < 4) 4 else b) else b;
                    tag = .Indirect;
                },
                (max_indirect_bits + 1)...max_bits => {
                    actual_bits = max_bits;
                    tag = .Direct;
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
    };
}

pub const ChunkSectionSpec = Ds.Spec(struct {
    block_count: i16,
    block_states: PalettedContainerSpec(.Block),
    biomes: PalettedContainerSpec(.Biome),
});

pub const Ds = serde.DefaultSpec;
pub const H = struct {
    pub const SB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Handshake = 0x00,
            Legacy = 0xFE,
        };
        Handshake: struct {
            protocol_version: VarInt,
            server_address: PStringMax(255),
            server_port: u16,
            next_state: serde.EnumSpec(Ds, VarInt, NextState),
        },
        Legacy: void,

        pub const NextState = enum(i32) {
            Status = 0x01,
            Login = 0x02,
        };
    });
};
pub const S = struct {
    pub const SB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Request = 0x00,
            Ping = 0x01,
        };
        Request: void,
        Ping: i64,
    });
    pub const CB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Response = 0x00,
            Pong = 0x01,
        };
        Response: PStringMax(32767),
        Pong: i64,
    });
};
pub const L = struct {
    pub const SB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            LoginStart = 0x00,
            EncryptionResponse = 0x01,
            LoginPluginResponse = 0x02,
        };
        LoginStart: PString,
        EncryptionResponse: struct {
            shared_secret: serde.PrefixedArray(Ds, VarInt, u8),
            verify_token: serde.PrefixedArray(Ds, VarInt, u8),
        },
        LoginPluginResponse: struct {
            message_id: VarInt,
            data: ?serde.Remaining,
        },
    });
    pub const CB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Disconnect = 0x00,
            EncryptionRequest = 0x01,
            LoginSuccess = 0x02,
            SetCompression = 0x03,
            LoginPluginRequest = 0x04,
        };
        Disconnect: PString,
        EncryptionRequest: struct {
            server_id: PStringMax(20),
            public_key: serde.PrefixedArray(Ds, VarInt, u8),
            verify_token: serde.PrefixedArray(Ds, VarInt, u8),
        },
        LoginSuccess: struct {
            uuid: UuidSpec,
            username: PStringMax(16),
        },
        SetCompression: VarInt,
        LoginPluginRequest: struct {
            message_id: VarInt,
            channel: Identifier,
            data: serde.Remaining,
        },
    });
};

pub const P = struct {
    pub const SB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            TeleportConfirm = 0x00,
            ClientStatus = 0x04,
            ClientSettings = 0x05,
            PluginMessage = 0x0A,
            PlayerPositionAndRotation = 0x12,
        };
        TeleportConfirm: VarInt,
        ClientStatus: serde.EnumSpec(Ds, VarInt, ClientStatus),
        ClientSettings: struct {
            locale: PStringMax(16),
            view_distance: i8,
            chat_mode: serde.EnumSpec(Ds, VarInt, ChatMode),
            chat_colors: bool,
            displayed_skin_parts: DisplayedSkinParts,
            main_hand: serde.EnumSpec(Ds, VarInt, MainHand),
            enable_text_filtering: bool,
            allow_server_listings: bool,
        },
        PluginMessage: struct {
            channel: Identifier,
            data: serde.Remaining,
        },
        PlayerPositionAndRotation: struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            on_ground: bool,
        },
    });
    pub const CB = serde.TaggedUnionSpec(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            ServerDifficulty = 0x0E,
            DeclareCommands = 0x12,
            PluginMessage = 0x18,
            EntityStatus = 0x1B,
            ChunkDataAndUpdateLight = 0x22,
            JoinGame = 0x26,
            PlayerAbilities = 0x32,
            PlayerInfo = 0x36,
            PlayerPositionAndLook = 0x38,
            UnlockRecipes = 0x39,
            WorldBorderCenter = 0x42,
            WorldBorderLerpSize = 0x43,
            WorldBorderSize = 0x44,
            WorldBorderWarningDelay = 0x45,
            WorldBorderWarningReach = 0x46,
            HeldItemChange = 0x48,
            UpdateViewPosition = 0x49,
            SpawnPosition = 0x4B,
            DeclareRecipes = 0x66,
            Tags = 0x67,
        };
        ServerDifficulty: struct {
            difficulty: Difficulty,
            difficulty_locked: bool,
        },
        DeclareCommands: struct {
            nodes: serde.PrefixedArray(Ds, VarInt, CommandNode),
            root_index: VarInt,
        },
        PluginMessage: struct {
            channel: Identifier,
            data: serde.Remaining,
        },
        EntityStatus: struct {
            entity_id: i32,
            entity_status: i8,
        },
        ChunkDataAndUpdateLight: struct {
            chunk_x: i32,
            chunk_z: i32,
            heightmaps: nbt.NbtSpec.Spec(struct {
                MOTION_BLOCKING: []i64,
                WORLD_SURFACE: ?[]i64,
            }),
            data: serde.SizePrefixedArray(Ds, VarInt, ChunkSectionSpec),
            block_entities: serde.PrefixedArray(Ds, VarInt, BlockEntity),
            trust_edges: bool,
            sky_light_mask: BitSet,
            block_light_mask: BitSet,
            empty_sky_light_mask: BitSet,
            empty_block_light_mask: BitSet,
            sky_light_arrays: serde.PrefixedArray(Ds, VarInt, serde.PrefixedArray(Ds, VarInt, u8)),
            block_light_arrays: serde.PrefixedArray(Ds, VarInt, serde.PrefixedArray(Ds, VarInt, u8)),
        },
        JoinGame: struct {
            entity_id: i32,
            is_hardcore: bool,
            gamemode: Gamemode,
            previous_gamemode: PreviousGamemode,
            dimension_names: serde.PrefixedArray(Ds, VarInt, PString),
            dimension_codec: nbt.NamedSpec(DimensionCodecSpec, ""),
            dimension: nbt.NamedSpec(nbt.NbtSpec.Spec(DimensionCodec.DimensionType.Element), ""),
            dimension_name: Identifier,
            hashed_seed: i64,
            max_players: VarInt,
            view_distance: VarInt,
            simulation_distance: VarInt,
            reduced_debug_info: bool,
            enable_respawn_screen: bool,
            is_debug: bool,
            is_flat: bool,
        },
        PlayerAbilities: struct {
            flags: packed struct {
                invulnerable: bool,
                flying: bool,
                allow_flying: bool,
                creative_mode: bool,
            },
            flying_speed: f32,
            field_of_view_modifier: f32,
        },
        PlayerInfo: PlayerInfoSpec,
        PlayerPositionAndLook: struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            relative: packed struct {
                x: bool,
                y: bool,
                z: bool,
                y_rot: bool,
                x_rot: bool,
            },
            teleport_id: VarInt,
            dismount_vehicle: bool,
        },
        UnlockRecipes: serde.TaggedUnionSpec(Ds, VarInt, union(UnlockRecipesAction) {
            pub const UnlockRecipesAction = enum(i32) {
                Init = 0,
                Add = 1,
                Remove = 2,
            };
            pub fn UnlockRecipesVariant(comptime T: type) type {
                return struct {
                    crafting_recipe_book_open: bool,
                    crafting_recipe_book_filter_active: bool,
                    smelting_recipe_book_open: bool,
                    smelting_recipe_book_filter_active: bool,
                    blast_furnace_recipe_book_open: bool,
                    blast_furnace_recipe_book_filter_active: bool,
                    smoker_recipe_book_open: bool,
                    smoker_recipe_book_filter_active: bool,
                    recipe_ids: serde.PrefixedArray(Ds, VarInt, Identifier),
                    recipe_ids_2: T,
                };
            }
            Init: UnlockRecipesVariant(serde.PrefixedArray(Ds, VarInt, Identifier)),
            Add: UnlockRecipesVariant(void),
            Remove: UnlockRecipesVariant(void),
        }),
        WorldBorderCenter: struct {
            x: f64,
            z: f64,
        },
        WorldBorderLerpSize: struct {
            old_diameter: f64,
            new_diameter: f64,
            speed: VarLong,
        },
        WorldBorderSize: f64,
        WorldBorderWarningDelay: VarInt,
        WorldBorderWarningReach: VarInt,
        HeldItemChange: i8,
        UpdateViewPosition: struct {
            chunk_x: VarInt,
            chunk_z: VarInt,
        },
        SpawnPosition: struct {
            location: Position,
            angle: f32,
        },
        DeclareRecipes: serde.PrefixedArray(Ds, VarInt, Recipe),
        Tags: TagsSpec,
    });
};

fn testPacket(comptime PacketType: type, alloc: Allocator, data: []const u8) !PacketType.UserType {
    var stream = std.io.fixedBufferStream(data);
    var result = try PacketType.deserialize(alloc, &stream.reader());
    errdefer PacketType.deinit(result, alloc);
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    try PacketType.write(result, &buffer.writer());
    try testing.expectEqualSlices(u8, data, buffer.items);
    return result;
}

test "protocol" {
    const alloc = testing.allocator;
    var packet: P.SB.UserType = undefined;
    packet = try testPacket(P.SB, alloc, &[_]u8{ 0x0A, 2, 'h', 'i', 't', 'h', 'e', 'r', 'e' });
    try testing.expectEqualStrings("hi", packet.PluginMessage.channel);
    try testing.expectEqualSlices(u8, "there", packet.PluginMessage.data);
    P.SB.deinit(packet, alloc);
}
