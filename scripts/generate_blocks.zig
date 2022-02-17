// Generate the necessary blocks.json using a server jar
// https://wiki.vg/Data_Generators#Blocks_report

const std = @import("std");
const fs = std.fs;
const json = std.json;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

pub const BlockProperty = struct {
    name: []const u8,
    variants: [][]const u8,
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
                    try props.append(BlockProperty{
                        .name = prop_name,
                        .variants = owned,
                    });
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
    var file = try fs.cwd().openFile("data/blocks.json", .{});
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
        \\    pub fn toDefaultGlobalPaletteId(material: BlockMaterial) GlobalPaletteInt{
        \\        switch(material) {
        \\
    );
    for (blocks.items) |block| {
        try writer.print("    " ** 3 ++ "BlockMaterial.{s} => return {},\n", .{ block.bareName(), block.begin_id + block.default_state });
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
                try writer.print("    " ** 2 ++ "{s}: enum {{\n", .{prop.name});
                for (prop.variants) |variant| {
                    try writer.print("    " ** 3 ++ "@\"{s}\",\n", .{variant});
                }
                try writer.writeAll("    " ** 2 ++ "},\n");
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
                //try writer.print("    " ** 4 ++ "const @\"{s}\" = switch(variant_id % {}) {{\n", .{ prop.name, prop.variants.len });
                //var j: usize = 0;
                //while (j < prop.variants.len) : (j += 1) {
                //    try writer.print("    " ** 5 ++ "{} => .@\"{s}\",\n", .{ j, prop.variants[j] });
                //}
                //try writer.print("    " ** 5 ++ "else => unreachable,\n", .{});
                //try writer.writeAll("    " ** 4 ++ "};\n");
                try writer.print("    " ** 4 ++ "const @\"{s}\" = @intToEnum(property_fields[{}].field_type, variant_id % {});\n", .{ prop.name, i - 1, prop.variants.len });
                if (i != 1) {
                    try writer.print("    " ** 4 ++ "variant_id /= {};\n", .{prop.variants.len});
                }
            }
            try writer.print("    " ** 4 ++ "return Block{{ .{s} = .{{\n", .{block.bareName()});
            for (block.properties.?) |prop| {
                try writer.print("    " ** 5 ++ ".@\"{s}\" = @\"{s}\",\n", .{ prop.name, prop.name });
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
        \\};
        \\
        \\
    );

    try writer.writeAll(
        \\const testing = std.testing;
        \\test "from global palette id" {
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(160);
        \\        try testing.expect(block.oak_leaves.distance == .@"7");
        \\        try testing.expect(block.oak_leaves.persistent == .@"true");
        \\    }
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(20);
        \\        try testing.expect(block == .dark_oak_planks);
        \\    }
        \\    {
        \\        const block = try Block.fromGlobalPaletteId(21);
        \\        try testing.expect(block.oak_sapling.stage == .@"0");
        \\    }
        \\}
    );
    try buffered_writer.flush();

    std.debug.print("{s}\n", .{data.items});

    var target_file = try fs.cwd().createFile("src/gen/blocks.zig", .{});
    defer target_file.close();
    try target_file.writeAll(data.items);
}
