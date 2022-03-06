const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const unicode = std.unicode;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const math = std.math;

const Uuid = @import("uuid6");

const serde = @import("serde.zig");
const nbt = @import("nbt.zig");
const VarNum = @import("varnum.zig").VarNum;
pub const VarInt = VarNum(i32);
pub const VarLong = VarNum(i64);
pub const chunk = @import("chunk.zig");

pub const PROTOCOL_VERSION = 757;

pub const PStringError = error{
    StringTooLarge,
};

pub const PSTRING_ARRAY_MAX_LEN = 64;

// todo: uh, probably want just separate types for the stack vs heap versions. can do fancy auto stuff later once those are around
pub fn PStringMax(comptime max_len_opt: ?usize) type {
    return struct {
        pub const IsArray = max_len_opt != null and max_len_opt.? <= PSTRING_ARRAY_MAX_LEN;
        pub const UserType = if (IsArray) [max_len_opt.? * 4:0]u8 else []const u8;

        pub fn characterCount(self: UserType) !i32 {
            return @intCast(i32, try unicode.utf8CountCodepoints(if (IsArray) std.mem.sliceTo(&self, 0) else self));
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try VarInt.write(try characterCount(self), writer);
            try writer.writeAll(if (IsArray) std.mem.sliceTo(&self, 0) else self);
        }

        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const len = try VarInt.deserialize(alloc, reader);
            if (max_len_opt) |max_len| {
                if (len > max_len) {
                    return error.StringTooLarge;
                }
            }
            var data = if (IsArray) std.BoundedArray(u8, max_len_opt.? * 4 + 1){} else try std.ArrayList(u8).initCapacity(alloc, @intCast(usize, len));
            defer if (!IsArray) data.deinit();
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
            if (IsArray) {
                assert(data.len < data.buffer.len);
                data.buffer[data.len] = 0;
                return @bitCast([max_len_opt.? * 4:0]u8, data.buffer);
            } else {
                return data.toOwnedSlice();
            }
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            if (IsArray) {
                _ = self;
                _ = alloc;
            } else {
                alloc.free(self);
            }
        }
        pub fn size(self: UserType) usize {
            var len = characterCount(self) catch unreachable;
            return VarInt.size(len) + if (IsArray) std.mem.sliceTo(&self, 0).len else self.len;
        }
    };
}

test "pstring" {
    //var reader = std.io.fixedBufferStream();
    const DataType = PStringMax(10);
    var result = try testPacket(DataType, testing.allocator, &[_]u8{10} ++ "你好，我们没有时间。");
    //std.debug.print("result len: {}, {}\n", .{ std.mem.sliceTo(&result, 0).len, DataType.characterCount(result) });
    try testing.expectEqual(@as(usize, 30), std.mem.sliceTo(&result, 0).len);
    try testing.expectEqual(@as(i32, 10), try DataType.characterCount(result));
    try testing.expectEqualStrings("你好，我们没有时间。", std.mem.sliceTo(&result, 0));
    try testing.expectEqual(@as(usize, 31), DataType.size(result));

    const DataType2 = PStringMax(PSTRING_ARRAY_MAX_LEN + 1);
    try testing.expect(!DataType2.IsArray);
    var result2 = try testPacket(DataType2, testing.allocator, &[_]u8{10} ++ "你好，我们没有时间。");
    defer DataType2.deinit(result2, testing.allocator);
    try testing.expectEqual(@as(usize, 30), result2.len);
    try testing.expectEqual(@as(i32, 10), try DataType2.characterCount(result2));
    try testing.expectEqualStrings("你好，我们没有时间。", result2);
    try testing.expectEqual(@as(usize, 31), DataType2.size(result2));
}

pub const PString = PStringMax(32767);
pub const Identifier = PStringMax(32767);
pub const ChatString = PStringMax(262144);

pub fn intoAngle(val: f32) u8 {
    var new_val: isize = @floatToInt(isize, (val / 360.0) * 256.0);
    while (new_val < 0) new_val += 256;
    while (new_val >= 256) new_val -= 256;
    return @intCast(u8, new_val);
}

pub const UuidS = struct {
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

pub const DimensionCodecDimensionTypeElement = struct {
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

pub const DimensionCodec = struct {
    @"minecraft:dimension_type": struct { @"type": []const u8 = "minecraft:dimension_type", value: []DimensionType },
    @"minecraft:worldgen/biome": struct {
        @"type": []const u8 = "minecraft:worldgen/biome",
        value: []Biome,
    },
    pub const DimensionType = struct {
        name: []const u8,
        id: i32,
        element: DimensionCodecDimensionTypeElement,
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
pub const DEFAULT_DIMENSION_TYPE_ELEMENT: DimensionCodecTypeElementS.UserType = .{
    .piglin_safe = false,
    .natural = true,
    .ambient_light = 0.0,
    .infiniburn = "minecraft:infiniburn_overworld",
    .respawn_anchor_works = false,
    .has_skylight = true,
    .bed_works = true,
    .effects = "minecraft:overworld",
    .has_raids = true,
    .min_y = chunk.MIN_Y,
    .height = chunk.MAX_HEIGHT,
    .logical_height = 256,
    .coordinate_scale = 1.0,
    .ultrawarm = false,
    .has_ceiling = false,
    .fixed_time = null,
};
pub const DEFUALT_DIMENSION_CODEC: DimensionCodecS.UserType = .{
    .@"minecraft:dimension_type" = .{
        .@"type" = "minecraft:dimension_type",
        .value = &[_]meta.Child(DimensionCodecS.Specs[0].Specs[1].UserType){
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
                    .min_y = chunk.MIN_Y,
                    .height = chunk.MAX_HEIGHT,
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
        .value = &[_]meta.Child(DimensionCodecS.Specs[1].Specs[1].UserType){
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

pub const Slot = Ds.Spec(?SlotData);
pub const SlotData = struct {
    item_id: VarInt,
    item_count: i8,
    nbt: nbt.DynamicCompound,
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

    pub const RecipeData = serde.Union(Ds, union(enum) {
        crafting_shapeless: struct {
            group: PString,
            ingredients: serde.PrefixedArray(Ds, VarInt, Ingredient),
            result: Slot,
        },
        crafting_shaped: CraftingShaped,
        crafting_special_armor_dye: void,
        crafting_special_book_cloning: void,
        crafting_special_map_cloning: void,
        crafting_special_map_extending: void,
        crafting_special_firework_rocket: void,
        crafting_special_firework_star: void,
        crafting_special_firework_star_fade: void,
        crafting_special_repair_item: void,
        crafting_special_tipped_arrow: void,
        crafting_special_banned_duplicate: void,
        crafting_special_banner_add_pattern: void,
        crafting_special_shield_decoration: void,
        crafting_special_shulker_box_coloring: void,
        crafting_special_suspicious_stew: void,
        smelting: Smelting,
        blasting: Smelting,
        smoking: Smelting,
        campfire_cooking: Smelting,
        stonecutting: struct {
            group: PString,
            ingredient: Ingredient,
            result: Slot,
        },
        smithing: struct {
            base: Ingredient,
            addition: Ingredient,
            result: Slot,
        },
        none: void,

        pub const Smelting = struct {
            group: PString,
            ingredient: Ingredient,
            result: Slot,
            experience: f32,
            cooking_time: VarInt,
        };
    });

    // TODO since we're not using pascal case for the variant names here anymore, we could probably automate the string to enum conversion
    const IdentifierMap = std.ComptimeStringMap(meta.Tag(RecipeData.UserType), .{
        .{ "crafting_shapeless", .crafting_shapeless },
        .{ "crafting_shaped", .crafting_shaped },
        .{ "crafting_special_armordye", .crafting_special_armor_dye },
        .{ "crafting_special_bookcloning", .crafting_special_book_cloning },
        .{ "crafting_special_mapcloning", .crafting_special_map_cloning },
        .{ "crafting_special_mapextending", .crafting_special_map_extending },
        .{ "crafting_special_firework_rocket", .crafting_special_firework_rocket },
        .{ "crafting_special_firework_star", .crafting_special_firework_star },
        .{ "crafting_special_firework_star_fade", .crafting_special_firework_star_fade },
        .{ "crafting_special_repairitem", .crafting_special_repair_item },
        .{ "crafting_special_tippedarrow", .crafting_special_tipped_arrow },
        .{ "crafting_special_bannerduplicate", .crafting_special_banned_duplicate },
        .{ "crafting_special_banneraddpattern", .crafting_special_banner_add_pattern },
        .{ "crafting_special_shielddecoration", .crafting_special_shield_decoration },
        .{ "crafting_special_shulkerboxcoloring", .crafting_special_shulker_box_coloring },
        .{ "crafting_special_suspiciousstew", .crafting_special_suspicious_stew },
        .{ "smelting", .smelting },
        .{ "blasting", .blasting },
        .{ "smoking", .smoking },
        .{ "campfire_cooking", .campfire_cooking },
        .{ "stonecutting", .stonecutting },
        .{ "smithing", .smithing },
    });

    pub const UserType = @This();
    pub fn write(self: anytype, writer: anytype) !void {
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
        const tag: meta.Tag(RecipeData.UserType) = IdentifierMap.get(self.type) orelse .none;
        self.data = try RecipeData.deserialize(alloc, reader, @enumToInt(tag));
        return self;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        Identifier.deinit(self.type, alloc);
        Identifier.deinit(self.recipe_id, alloc);
        RecipeData.deinit(self.data, alloc);
    }
    pub fn size(self: anytype) usize {
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

pub const DimensionCodecS = nbt.NbtSpec.Spec(DimensionCodec);
pub const DimensionCodecTypeElementS = nbt.NbtSpec.Spec(DimensionCodecDimensionTypeElement);
pub const Tags = serde.PrefixedArray(Ds, VarInt, struct {
    tag_type: Identifier,
    tags: serde.PrefixedArray(Ds, VarInt, TagEntries),
});
pub const TagEntries = Ds.Spec(struct {
    tag_name: Identifier,
    entries: serde.PrefixedArray(Ds, VarInt, VarInt),
});
pub const PlayerInfo = serde.TaggedUnion(Ds, VarInt, union(PlayerInfoAction) {
    pub const PlayerInfoAction = enum(i32) {
        add_player = 0,
        update_gamemode = 1,
        update_latency = 2,
        update_display_name = 3,
        remove_player = 4,
    };
    add_player: PlayerInfoVariant(struct {
        name: PStringMax(16),
        properties: serde.PrefixedArray(Ds, VarInt, PlayerProperty),
        gamemode: Gamemode,
        ping: VarInt,
        display_name: ?ChatString,
    }),
    update_gamemode: PlayerInfoVariant(Gamemode),
    update_latency: PlayerInfoVariant(VarInt),
    update_display_name: PlayerInfoVariant(?ChatString),
    remove_player: PlayerInfoVariant(void),
    pub fn PlayerInfoVariant(comptime T: type) type {
        return serde.PrefixedArray(Ds, VarInt, struct {
            uuid: UuidS,
            data: T,
        });
    }
});
pub const PlayerProperty = Ds.Spec(struct {
    name: PStringMax(32767),
    value: PStringMax(32767),
    signature: ?PStringMax(32767),
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
pub const Hand = enum(i32) {
    Main = 0,
    Off = 1,
};
pub const ClientStatus = enum(i32) {
    PerformRespawn = 0,
    RequestStats = 1,
};

pub const EntityActionId = enum(i32) {
    StartSneaking = 0,
    StopSneaking = 1,
    LeaveBed = 2,
    StartSprinting = 3,
    StopSprinting = 4,
    StartJumpWithHorse = 5,
    StopJumpWithHorse = 6,
    OpenHorseInventory = 7,
    StartFlyingWithElytra = 8,
};

pub const PlayerDiggingStatus = enum(i32) {
    Started = 0,
    Cancelled = 1,
    Finished = 2,
    DropItemStack = 3,
    DropItem = 4,
    ShootArrowOrFinishEating = 5,
    SwapItemInHand = 6,
};
pub const BlockFace = enum(u8) {
    Bottom = 0,
    Top = 1,
    North = 2,
    South = 3,
    West = 4,
    East = 5,
};
pub const ChatPosition = enum(u8) {
    Chat = 0,
    SystemMessage = 1,
    GameInfo = 2,
};
pub const ClientSettings = Ds.Spec(struct {
    locale: PStringMax(16),
    view_distance: i8,
    chat_mode: serde.Enum(Ds, VarInt, ChatMode),
    chat_colors: bool,
    displayed_skin_parts: DisplayedSkinParts,
    main_hand: serde.Enum(Ds, VarInt, MainHand),
    enable_text_filtering: bool,
    allow_server_listings: bool,
});

pub const Ds = serde.DefaultSpec;
pub const H = struct {
    pub const SB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            handshake = 0x00,
            legacy = 0xFE,
        };
        handshake: struct {
            protocol_version: VarInt,
            server_address: PStringMax(255),
            server_port: u16,
            next_state: serde.Enum(Ds, VarInt, NextState),
        },
        legacy: void,

        pub const NextState = enum(i32) {
            Status = 0x01,
            Login = 0x02,
        };
    });
};
pub const S = struct {
    pub const SB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            request = 0x00,
            ping = 0x01,
        };
        request: void,
        ping: i64,
    });
    pub const CB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            response = 0x00,
            pong = 0x01,
        };
        response: PStringMax(32767),
        pong: i64,
    });
};
pub const L = struct {
    pub const SB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            login_start = 0x00,
            encryption_response = 0x01,
            login_plugin_response = 0x02,
        };
        login_start: PStringMax(16),
        encryption_response: struct {
            shared_secret: serde.PrefixedArray(Ds, VarInt, u8),
            verify_token: serde.PrefixedArray(Ds, VarInt, u8),
        },
        login_plugin_response: struct {
            message_id: VarInt,
            data: ?serde.Remaining,
        },
    });
    pub const CB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            disconnect = 0x00,
            encryption_request = 0x01,
            login_success = 0x02,
            set_compression = 0x03,
            login_plugin_request = 0x04,
        };
        disconnect: ChatString,
        encryption_request: struct {
            server_id: PStringMax(20),
            public_key: serde.PrefixedArray(Ds, VarInt, u8),
            verify_token: serde.PrefixedArray(Ds, VarInt, u8),
        },
        login_success: struct {
            uuid: UuidS,
            username: PStringMax(16),
        },
        set_compression: VarInt,
        login_plugin_request: struct {
            message_id: VarInt,
            channel: Identifier,
            data: serde.Remaining,
        },
    });
};

pub const P = struct {
    pub const SB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            teleport_confirm = 0x00,
            chat_message = 0x03,
            client_status = 0x04,
            client_settings = 0x05,
            close_window = 0x09,
            plugin_message = 0x0A,
            keep_alive = 0x0F,
            player_position = 0x11,
            player_position_and_rotation = 0x12,
            player_rotation = 0x13,
            player_movement = 0x14,
            player_abilities = 0x19,
            player_digging = 0x1A,
            entity_action = 0x1B,
            held_item_change = 0x25,
            creative_inventory_action = 0x28,
            animation = 0x2C,
            player_block_placement = 0x2E,
            use_item = 0x2F,
        };
        teleport_confirm: VarInt,
        chat_message: PStringMax(256),
        client_status: serde.Enum(Ds, VarInt, ClientStatus),
        client_settings: ClientSettings,
        close_window: u8,
        plugin_message: struct {
            channel: Identifier,
            data: serde.Remaining,
        },
        keep_alive: i64,
        player_position: struct {
            x: f64,
            y: f64,
            z: f64,
            on_ground: bool,
        },
        player_position_and_rotation: struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            on_ground: bool,
        },
        player_rotation: struct {
            yaw: f32,
            pitch: f32,
            on_ground: bool,
        },
        player_movement: bool,
        player_abilities: packed struct {
            // spec just says for flying but im going to assume it includes the other stuff
            invulnerable: bool,
            flying: bool,
            allow_flying: bool,
            creative_mode: bool,
        },
        player_digging: struct {
            status: serde.Enum(Ds, VarInt, PlayerDiggingStatus),
            location: Position,
            face: BlockFace,
        },
        entity_action: struct {
            entity_id: VarInt,
            action_id: serde.Enum(Ds, VarInt, EntityActionId),
            jump_boost: VarInt,
        },
        held_item_change: i16,
        creative_inventory_action: struct {
            slot: i16,
            clicked_item: Slot,
        },
        animation: serde.Enum(Ds, VarInt, Hand),
        player_block_placement: struct {
            hand: serde.Enum(Ds, VarInt, Hand),
            location: Position,
            face: BlockFace,
            cursor_position_x: f32,
            cursor_position_y: f32,
            cursor_position_z: f32,
            inside_block: bool,
        },
        use_item: serde.Enum(Ds, VarInt, Hand),
    });
    pub const CB = serde.TaggedUnion(Ds, VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            spawn_player = 0x04,
            server_difficulty = 0x0E,
            chat_message = 0x0F,
            declare_commands = 0x12,
            plugin_message = 0x18,
            disconnect = 0x1A,
            entity_status = 0x1B,
            keep_alive = 0x21,
            chunk_data_and_update_light = 0x22,
            join_game = 0x26,
            entity_position = 0x29,
            entity_position_and_rotation = 0x2A,
            entity_rotation = 0x2B,
            player_abilities = 0x32,
            player_info = 0x36,
            player_position_and_look = 0x38,
            unlock_recipes = 0x39,
            destroy_entities = 0x3A,
            entity_head_look = 0x3E,
            world_border_center = 0x42,
            world_border_lerp_size = 0x43,
            world_border_size = 0x44,
            world_border_warning_delay = 0x45,
            world_border_warning_reach = 0x46,
            held_item_change = 0x48,
            update_view_position = 0x49,
            entity_teleport = 0x62,
            spawn_position = 0x4B,
            declare_recipes = 0x66,
            tags = 0x67,
        };
        spawn_player: struct {
            entity_id: VarInt,
            player_uuid: UuidS,
            x: f64,
            y: f64,
            z: f64,
            yaw: u8,
            pitch: u8,
        },
        server_difficulty: struct {
            difficulty: Difficulty,
            difficulty_locked: bool,
        },
        chat_message: struct {
            message: ChatString,
            position: ChatPosition,
            sender: UuidS,
        },
        declare_commands: struct {
            nodes: serde.PrefixedArray(Ds, VarInt, CommandNode),
            root_index: VarInt,
        },
        plugin_message: struct {
            channel: Identifier,
            data: serde.Remaining,
        },
        disconnect: ChatString,
        entity_status: struct {
            entity_id: i32,
            entity_status: i8,
        },
        keep_alive: i64,
        chunk_data_and_update_light: struct {
            chunk_x: i32,
            chunk_z: i32,
            heightmaps: nbt.Named(struct {
                MOTION_BLOCKING: []i64,
                WORLD_SURFACE: ?[]i64,
            }, ""),
            data: serde.SizePrefixedArray(Ds, VarInt, chunk.ChunkSection),
            block_entities: serde.PrefixedArray(Ds, VarInt, chunk.BlockEntity),
            trust_edges: bool,
            sky_light_mask: BitSet,
            block_light_mask: BitSet,
            empty_sky_light_mask: BitSet,
            empty_block_light_mask: BitSet,
            sky_light_arrays: serde.PrefixedArray(Ds, VarInt, serde.PrefixedArray(Ds, VarInt, u8)),
            block_light_arrays: serde.PrefixedArray(Ds, VarInt, serde.PrefixedArray(Ds, VarInt, u8)),
        },
        join_game: struct {
            entity_id: i32,
            is_hardcore: bool,
            gamemode: Gamemode,
            previous_gamemode: PreviousGamemode,
            dimension_names: serde.PrefixedArray(Ds, VarInt, Identifier),
            dimension_codec: nbt.Named(DimensionCodecS, ""),
            dimension: nbt.Named(DimensionCodecTypeElementS, ""),
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
        entity_position: struct {
            entity_id: VarInt,
            dx: i16,
            dy: i16,
            dz: i16,
            on_ground: bool,
        },
        entity_position_and_rotation: struct {
            entity_id: VarInt,
            dx: i16,
            dy: i16,
            dz: i16,
            yaw: u8,
            pitch: u8,
            on_ground: bool,
        },
        entity_rotation: struct {
            entity_id: VarInt,
            yaw: u8,
            pitch: u8,
            on_ground: bool,
        },
        player_abilities: struct {
            flags: packed struct {
                invulnerable: bool,
                flying: bool,
                allow_flying: bool,
                creative_mode: bool,
            },
            flying_speed: f32,
            field_of_view_modifier: f32,
        },
        player_info: PlayerInfo,
        player_position_and_look: struct {
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
        unlock_recipes: serde.TaggedUnion(Ds, VarInt, union(UnlockRecipesAction) {
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
        destroy_entities: serde.PrefixedArray(Ds, VarInt, VarInt),
        entity_head_look: struct {
            entity_id: VarInt,
            yaw: u8,
        },
        world_border_center: struct {
            x: f64,
            z: f64,
        },
        world_border_lerp_size: struct {
            old_diameter: f64,
            new_diameter: f64,
            speed: VarLong,
        },
        world_border_size: f64,
        world_border_warning_delay: VarInt,
        world_border_warning_reach: VarInt,
        held_item_change: i8,
        update_view_position: struct {
            chunk_x: VarInt,
            chunk_z: VarInt,
        },
        entity_teleport: struct {
            entity_id: VarInt,
            x: f64,
            y: f64,
            z: f64,
            yaw: u8,
            pitch: u8,
            on_ground: bool,
        },
        spawn_position: struct {
            location: Position,
            angle: f32,
        },
        declare_recipes: serde.PrefixedArray(Ds, VarInt, Recipe),
        tags: Tags,
    });
};

fn testPacket(comptime PacketType: type, alloc: Allocator, data: []const u8) !PacketType.UserType {
    var stream = std.io.fixedBufferStream(data);
    var result = try PacketType.deserialize(alloc, stream.reader());
    errdefer PacketType.deinit(result, alloc);
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    try PacketType.write(result, buffer.writer());
    try testing.expectEqualSlices(u8, data, buffer.items);
    return result;
}

test "protocol" {
    const alloc = testing.allocator;
    var packet: P.SB.UserType = undefined;
    packet = try testPacket(P.SB, alloc, &[_]u8{ 0x0A, 2, 'h', 'i', 't', 'h', 'e', 'r', 'e' });
    try testing.expectEqualStrings("hi", packet.plugin_message.channel);
    try testing.expectEqualSlices(u8, "there", packet.plugin_message.data);
    P.SB.deinit(packet, alloc);
}
