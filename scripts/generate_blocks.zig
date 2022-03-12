// Generate the necessary data from blocks.json using a server jar
// needs blocks.json, can follow https://wiki.vg/Data_Generators#Blocks_report to get

const std = @import("std");
const fs = std.fs;
const json = std.json;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

pub const BlockPropertyVariantsType = union(enum) {
    Enum,
    Bool,
    Number: struct {
        start: usize,
        max: usize,
    },
    pub fn from(self: @This(), name: []const u8, writer: anytype) !void {
        try writer.writeAll("@intCast(GlobalPaletteInt, ");
        switch (self) {
            .Enum => try writer.print("@enumToInt(b.{s})", .{name}),
            .Bool => try writer.print("if(b.{s}) @as(GlobalPaletteInt, 0) else @as(GlobalPaletteInt, 1)", .{name}),
            .Number => |n| try writer.print("b.{s} - {}", .{ name, n.start }),
        }
        try writer.writeAll(");\n");
    }
};
pub const BlockProperty = struct {
    name: []const u8,
    variants: [][]const u8,
    variants_type: BlockPropertyVariantsType,
    pub fn init(name: []const u8, variants: [][]const u8) BlockProperty {
        var prop = BlockProperty{
            .name = name,
            .variants = variants,
            .variants_type = undefined,
        };
        if (variants.len == 2 and mem.eql(u8, "true", variants[0]) and mem.eql(u8, "false", variants[1])) {
            prop.variants_type = .Bool;
        } else {
            var max_num: ?isize = null;
            var start_num: ?isize = null;
            blk: {
                var last: ?isize = null;
                for (variants) |variant| {
                    const val = std.fmt.parseInt(isize, variant, 10) catch |err| {
                        assert(err == error.InvalidCharacter);
                        break :blk;
                    };
                    if (last == null) {
                        start_num = val;
                        last = val;
                    } else {
                        if (val == last.? + 1) {
                            last = val;
                        } else {
                            break :blk;
                        }
                    }
                }
                max_num = last;
                break :blk;
            }
            if (max_num) |num| {
                prop.variants_type = .{ .Number = .{
                    .max = @intCast(usize, num),
                    .start = @intCast(usize, start_num.?),
                } };
            } else {
                for (variants) |variant| {
                    assert(std.ascii.isAlpha(variant[0]));
                }
                prop.variants_type = .Enum;
            }
        }
        return prop;
    }
    pub fn deinit(self: BlockProperty, alloc: Allocator) void {
        alloc.free(self.variants);
    }
};
pub const HuhError = error{Huh};
pub const Block = struct {
    name: []const u8,
    properties: ?[]BlockProperty = null,
    default_state: usize,
    begin_id: usize,

    pub fn init(alloc: Allocator, token_stream: *json.TokenStream) !?Block {
        var block: Block = undefined;

        var token = (try token_stream.next()).?;
        if (token == .ObjectEnd) return null;
        block.name = token.String.slice(token_stream.slice, token_stream.i - 1);

        assert((try token_stream.next()).? == .ObjectBegin);
        var id: ?usize = null;
        var default_ind: ?usize = null;

        while (true) {
            token = (try token_stream.next()).?;
            if (token == .ObjectEnd) break;
            const field_name = token.String.slice(token_stream.slice, token_stream.i - 1);
            if (mem.eql(u8, field_name, "states")) {
                assert((try token_stream.next()).? == .ArrayBegin);
                while (true) {
                    token = (try token_stream.next()).?;
                    if (token == .ArrayEnd) break;
                    assert(token == .ObjectBegin);
                    var state_id: ?usize = null;
                    var is_default: ?bool = null;
                    while (true) {
                        token = (try token_stream.next()).?;
                        if (token == .ObjectEnd) break;
                        const state_field_name = token.String.slice(token_stream.slice, token_stream.i - 1);
                        token = (try token_stream.next()).?;
                        if (mem.eql(u8, state_field_name, "properties")) {
                            assert(token == .ObjectBegin);
                            token = (try token_stream.next()).?;
                            while (token != .ObjectEnd) : (token = (try token_stream.next()).?) {
                                assert(token == .String);
                                assert((try token_stream.next()).? == .String);
                            }
                        } else if (mem.eql(u8, state_field_name, "id")) {
                            assert(token.Number.is_integer);
                            const state_id_slice = token.Number.slice(token_stream.slice, token_stream.i - 1);
                            state_id = try std.fmt.parseInt(usize, state_id_slice, 10);
                        } else if (mem.eql(u8, state_field_name, "default")) {
                            assert(token == .True or token == .False);
                            is_default = token == .True;
                        } else return error.Huh;
                    }
                    if (id == null or (state_id != null and id.? > state_id.?)) {
                        id = state_id;
                    }
                    if (is_default != null and is_default.?) {
                        default_ind = state_id;
                    }
                }
            } else if (mem.eql(u8, field_name, "properties")) {
                assert((try token_stream.next()).? == .ObjectBegin);

                var props = std.ArrayList(BlockProperty).init(alloc);
                defer props.deinit();
                while (true) {
                    token = (try token_stream.next()).?;
                    if (token == .ObjectEnd) break;
                    const prop_name = token.String.slice(token_stream.slice, token_stream.i - 1);

                    assert((try token_stream.next()).? == .ArrayBegin);
                    var variants = std.ArrayList([]const u8).init(alloc);
                    defer variants.deinit();
                    while (true) {
                        token = (try token_stream.next()).?;
                        if (token == .ArrayEnd) break;
                        const variant_name = token.String.slice(token_stream.slice, token_stream.i - 1);
                        try variants.append(variant_name);
                    }
                    const owned = variants.toOwnedSlice();
                    errdefer alloc.free(owned);
                    try props.append(BlockProperty.init(prop_name, owned));
                }
                assert(block.properties == null);
                block.properties = props.toOwnedSlice();
            }
        }
        block.begin_id = id.?;
        block.default_state = default_ind.? - id.?;
        return block;
    }
    pub fn deinit(self: Block, alloc: Allocator) void {
        if (self.properties) |props| {
            for (props) |prop| {
                prop.deinit(alloc);
            }
            alloc.free(props);
        }
    }
    pub fn bareName(self: Block) []const u8 {
        const comp = "minecraft:";
        assert(mem.eql(u8, self.name[0..comp.len], comp));
        return self.name[comp.len..];
    }
    pub fn propPermCount(self: Block) usize {
        if (self.properties) |props| {
            var count: usize = 1;
            for (props) |prop| {
                count *= prop.variants.len;
            }
            return count;
        } else return 1;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 16,
    }){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();
    var file = try fs.cwd().openFile("data/reports/blocks.json", .{});
    var file_data = try file.readToEndAlloc(alloc, 3999999999);
    defer alloc.free(file_data);
    var token_stream = json.TokenStream.init(file_data);

    var blocks = std.ArrayList(Block).init(alloc);
    defer {
        for (blocks.items) |block| {
            block.deinit(alloc);
        }
        blocks.deinit();
    }

    assert((try token_stream.next()).? == .ObjectBegin);
    //var count: usize = 0;
    while (try Block.init(alloc, &token_stream)) |block| {
        try blocks.append(block);
        //count += 1;
        //if (count > 62) break;
    }
    //for (blocks.items) |block| {
    //    std.log.info("{any}", .{block});
    //}

    var data = std.ArrayList(u8).init(alloc);
    defer data.deinit();
    var buffered_writer = std.io.bufferedWriter(data.writer());
    var writer = buffered_writer.writer();

    var largest_id: usize = 0;
    for (blocks.items) |block| {
        const high_block_id = block.begin_id + block.propPermCount() - 1;
        if (high_block_id > largest_id) largest_id = high_block_id;
    }

    try writer.print(
        \\const std = @import("std");
        \\pub const BlockFromIdError = error{{
        \\    InvalidId,
        \\}};
        \\pub const GlobalPaletteMaxId = {};
        \\pub const GlobalPaletteInt = std.math.IntFittingRange(0, GlobalPaletteMaxId);
        \\pub const BlockMaterial = enum {{
        \\
    , .{largest_id});
    for (blocks.items) |block| {
        try writer.print("    {s},\n", .{block.bareName()});
    }
    try writer.writeAll(
        \\    
        \\
        \\    pub fn fromGlobalPaletteId(id: GlobalPaletteInt) !BlockMaterial {
        \\        switch(id) {
        \\
    );
    for (blocks.items) |block| {
        const perm_count = block.propPermCount();
        if (perm_count != 1) {
            try writer.print("    " ** 3 ++ "{}...{} => return BlockMaterial.{s},\n", .{ block.begin_id, block.begin_id + perm_count - 1, block.bareName() });
        } else {
            try writer.print("    " ** 3 ++ "{} => return BlockMaterial.{s},\n", .{ block.begin_id, block.bareName() });
        }
    }

    try writer.writeAll(
        \\            else => return BlockFromIdError.InvalidId,
        \\        }
        \\    }
        \\    
        \\    pub fn toDefaultGlobalPaletteId(material: BlockMaterial) GlobalPaletteInt {
        \\        switch(material) {
        \\
    );
    for (blocks.items) |block| {
        try writer.print("    " ** 3 ++ "BlockMaterial.{s} => return {},\n", .{ block.bareName(), block.begin_id + block.default_state });
    }

    try writer.writeAll(
        \\        }
        \\    }
        \\    pub fn toFirstGlobalPaletteId(material: BlockMaterial) GlobalPaletteInt {
        \\        switch(material) {
        \\
    );
    for (blocks.items) |block| {
        try writer.print("    " ** 3 ++ "BlockMaterial.{s} => return {},\n", .{ block.bareName(), block.begin_id });
    }
    try writer.writeAll(
        \\        }
        \\    }
        \\
    );
    try writer.writeAll(
        \\};
        \\
        \\pub const Block = union(BlockMaterial) {
        \\
    );
    for (blocks.items) |block| {
        if (block.properties) |props| {
            try writer.print("    {s}: struct {{\n", .{block.bareName()});
            for (props) |prop| {
                switch (prop.variants_type) {
                    .Enum => {
                        try writer.print("    " ** 2 ++ "{s}: enum {{\n", .{prop.name});
                        for (prop.variants) |variant| {
                            //try writer.print("    " ** 3 ++ "@\"{s}\",\n", .{variant});
                            try writer.print("    " ** 3 ++ "{s},\n", .{variant});
                        }
                        try writer.writeAll("    " ** 2 ++ "},\n");
                    },
                    .Bool => {
                        try writer.print("    " ** 2 ++ "{s}: bool,\n", .{prop.name});
                    },
                    .Number => |n| {
                        const bit_count = std.math.log2_int_ceil(usize, n.max + n.start + 1);
                        try writer.print("    " ** 2 ++ "{s}: u{},\n", .{ prop.name, bit_count });
                    },
                }
            }
            try writer.writeAll("    },\n");
        } else {
            try writer.print("    {s}: void,\n", .{block.bareName()});
        }
    }

    try writer.writeAll(
        \\    const fields = @typeInfo(Block).Union.fields;
        \\
        \\    pub fn fromGlobalPaletteId(id: GlobalPaletteInt) !Block {
        \\        switch(id) {
        \\
    );
    for (blocks.items) |block, b_ind| {
        const perm_count = block.propPermCount();
        if (perm_count != 1) {
            try writer.print("    " ** 3 ++ "{}...{} => {{\n", .{ block.begin_id, block.begin_id + perm_count - 1 });
            try writer.print("    " ** 4 ++ "var variant_id = id - {};\n", .{block.begin_id});
            try writer.print("    " ** 4 ++ "const property_fields = @typeInfo(fields[{}].field_type).Struct.fields;\n", .{b_ind});
            const props = block.properties.?;
            var i: usize = props.len;
            while (i != 0) : (i -= 1) {
                const prop = props[i - 1];
                try writer.print("    " ** 4 ++ "const @\"{s}\" = ", .{prop.name});
                switch (prop.variants_type) {
                    .Enum => {
                        try writer.print("@intToEnum(property_fields[{}].field_type, variant_id % {});\n", .{ i - 1, prop.variants.len });
                    },
                    .Bool => {
                        try writer.print("(variant_id % 2) == 0;\n", .{});
                    },
                    .Number => |n| {
                        try writer.print("@intCast(u{}, (variant_id % {}) + {});\n", .{ std.math.log2_int_ceil(usize, n.start + n.max + 1), prop.variants.len, n.start });
                    },
                }
                if (i != 1) {
                    try writer.print("    " ** 4 ++ "variant_id /= {};\n", .{prop.variants.len});
                }
            }
            try writer.writeAll("    " ** 4 ++ "_ = property_fields;\n");
            try writer.print("    " ** 4 ++ "return Block{{ .{s} = .{{\n", .{block.bareName()});
            for (block.properties.?) |prop| {
                try writer.print("    " ** 5 ++ ".{s} = @\"{s}\",\n", .{ prop.name, prop.name });
            }
            try writer.writeAll("    " ** 4 ++ "} };\n" ++ ("    " ** 3) ++ "},\n");
        } else {
            try writer.print("    " ** 3 ++ "{} => return Block.{s},\n", .{ block.begin_id, block.bareName() });
        }
    }
    try writer.writeAll(
        \\            else => return BlockFromIdError.InvalidId,
        \\        }
        \\    }
        \\
        \\    pub fn toGlobalPaletteId(self: Block) GlobalPaletteInt {
        \\        switch(self) {
        \\
    );
    for (blocks.items) |block| {
        if (block.properties != null and block.properties.?.len > 0) {
            const props = block.properties.?;
            try writer.print("    " ** 3 ++ "Block.{s} => |b| {{\n", .{block.bareName()});
            //try writer.print("    " ** 4 ++ "const first_id: GlobalPaletteInt = {};\n", .{block.begin_id});
            try writer.writeAll("    " ** 4 ++ "var local_id: GlobalPaletteInt = ");
            try props[0].variants_type.from(props[0].name, writer);
            var i: usize = props.len;
            while (i != 0) : (i -= 1) {
                const prop = props[i - 1];
                if (i != 1) {
                    try writer.print("    " ** 4 ++ "local_id = (local_id * {}) + ", .{prop.variants.len});
                    try prop.variants_type.from(prop.name, writer);
                }
            }
            try writer.print("    " ** 4 ++ "return {} + local_id;\n", .{block.begin_id});
            try writer.writeAll("    " ** 3 ++ "},\n");
        } else {
            try writer.print("    " ** 3 ++ "Block.{s} => return {},\n", .{ block.bareName(), block.begin_id });
        }
    }

    try writer.writeAll(
        \\        }
        \\    }
        \\
        \\};
        \\
        \\
    );

    try writer.writeAll(
        \\const testing = std.testing;
        \\test "from global palette id" {
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(160);
        \\        try testing.expect(block.oak_leaves.distance == 7);
        \\        try testing.expect(block.oak_leaves.persistent == true);
        \\    }
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(20);
        \\        try testing.expect(block == .dark_oak_planks);
        \\    }
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(21);
        \\        try testing.expect(block.oak_sapling.stage == 0);
        \\    }
        \\}
        \\
        \\test "to global palette id" {
        \\    {
        \\        const id = Block.toGlobalPaletteId(try Block.fromGlobalPaletteId(160));
        \\        try testing.expect(id == 160);
        \\    }
        \\}
    );
    try buffered_writer.flush();

    std.debug.print("{s}\n", .{data.items});

    const target_filename = "src/gen/blocks.zig";
    //const target_filename = "blocks.zig";
    var target_file = try fs.cwd().createFile(target_filename, .{});
    defer target_file.close();
    try target_file.writeAll(data.items);
}
