const std = @import("std");
const builtin = std.builtin;
const meta = std.meta;
const testing = std.testing;
const assert = std.debug.assert;
const gzip = std.compress.gzip;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const Tag = enum(u8) {
    End = 0,
    Byte = 1,
    Short = 2,
    Int = 3,
    Long = 4,
    Float = 5,
    Double = 6,
    ByteArray = 7,
    String = 8,
    List = 9,
    Compound = 10,
    IntArray = 11,
    LongArray = 12,
};

pub const NamedTag = struct {
    tag: Tag,
    name: []const u8,

    const NameSpec = serde.PrefixedArray(serde.DefaultSpec, u16, u8);

    pub const UserType = @This();
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeByte(@enumToInt(self.tag));
        if (self.tag != .End) {
            try NameSpec.write(self.name, writer);
        }
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        const tag = @intToEnum(Tag, try reader.readByte());
        const name = if (tag != .End) try NameSpec.deserialize(alloc, reader) else "";
        return UserType{
            .tag = tag,
            .name = name,
        };
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        NameSpec.deinit(self.name, alloc);
    }
    pub fn size(self: UserType) usize {
        if (self.tag == .End) return 1;
        return 1 + NameSpec.size(self.name);
    }

    pub fn getNbtType(self: UserType) ?Tag {
        return self.tag;
    }
};

test "named tags" {
    const expected = [_]u8{ @enumToInt(Tag.ByteArray), 0, 4, 't', 'e', 's', 't' };
    const data = NamedTag{
        .name = "test",
        .tag = Tag.ByteArray,
    };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try data.write(&buf.writer());
    try testing.expectEqualSlices(u8, &expected, buf.items);
    try testing.expectEqual(expected.len, data.size());
    var read_stream = std.io.fixedBufferStream(&expected);
    const result = try NamedTag.deserialize(testing.allocator, &read_stream.reader());
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("test", result.name);
    try testing.expectEqual(Tag.ByteArray, result.tag);
}

pub const CompoundError = error{
    InsufficientFields,
    UnexpectedField,
    UnexpectedType,
    DuplicateField,
    NoEnd,
};

pub fn CompoundFieldSpecs(comptime UsedSpec: type, comptime PartialSpec: type) [meta.fields(PartialSpec).len]type {
    const info = @typeInfo(PartialSpec).Struct;
    var specs: [info.fields.len]type = undefined;
    inline for (info.fields) |field, i| {
        const sub_info = @typeInfo(field.field_type);
        const SpecType = UsedSpec.Spec(if (sub_info == .Optional) sub_info.Optional.child else field.field_type);
        specs[i] = SpecType;
    }
    return specs;
}

pub fn CompoundUserType(comptime PartialSpec: type, comptime Specs: []const type) type {
    const info = @typeInfo(PartialSpec).Struct;
    var fields: [info.fields.len]builtin.TypeInfo.StructField = undefined;
    inline for (info.fields) |*field, i| {
        var f = field.*;
        const is_optional = @typeInfo(info.fields[i].field_type) == .Optional;
        f.field_type = if (is_optional) ?Specs[i].UserType else Specs[i].UserType;
        if (is_optional) {
            f.default_value = @as(f.field_type, null); // this doesnt actually work, see https://github.com/ziglang/zig/issues/10555
        } else {
            f.default_value = null;
        }
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Struct = .{
        .layout = info.layout,
        .fields = &fields,
        .decls = &[_]builtin.TypeInfo.Declaration{},
        .is_tuple = info.is_tuple,
    } });
}

pub fn CompoundSpec(comptime UsedSpec: type, comptime PartialSpec: type) type {
    return struct {
        pub const FieldEnum = meta.FieldEnum(PartialSpec);
        pub const Specs = CompoundFieldSpecs(UsedSpec, PartialSpec);
        pub const UserType = CompoundUserType(PartialSpec, std.mem.span(&Specs));
        pub fn write(self: UserType, writer: anytype) !void {
            // go through each field and write it
            inline for (meta.fields(PartialSpec)) |field, i| {
                // special case for optional field types; if field is optional and null, dont write it
                const is_optional = @typeInfo(field.field_type) == .Optional;
                const data = @field(self, field.name);
                const found_data: if (is_optional) @TypeOf(data) else ?@TypeOf(data) = data;
                // wtf
                if (found_data) |actual_data| {
                    // might want to just compile error if not nbt serializable, TODO
                    if (isNbtSerializable(Specs[i])) {
                        if (Specs[i].getNbtType(actual_data)) |tag| {
                            const named_tag = NamedTag{
                                .tag = tag,
                                .name = field.name,
                            };
                            try named_tag.write(writer);
                        }
                    }
                    try Specs[i].write(actual_data, writer);
                }
            }
            // since this nbt compound type, we need the end tag to say we're done
            const named_tag = NamedTag{
                .tag = .End,
                .name = "",
            };
            try named_tag.write(writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            // this is a fancy function that allows
            // - detecting field overwrites/duplicate fields
            // - detecting if we didnt write all required fields
            // - allowing optional fields not to need to be written to

            // here we have total_written_fields and optional_written_fields
            // optional_written_fields is used to check if we have written to a field at all; we use this to detect overwrites
            // total_written_fields is the set of all the fields that need to be written for deserialization to be considered complete
            //     because of this, total_written_fields starts out with optional fields "written to", such that if we were to finish early
            //     before writing to any optional field, it would be fine since the optional field would just be null
            var total_written_fields = comptime blk: {
                var written_fields = std.StaticBitSet(Specs.len).initEmpty();
                inline for (meta.fields(PartialSpec)) |field, i| {
                    if (@typeInfo(field.field_type) == .Optional) {
                        written_fields.setValue(@as(usize, i), true);
                    }
                }
                break :blk written_fields;
            };
            var optional_written_fields = std.StaticBitSet(Specs.len).initEmpty();
            // data starts out with optional fields set to null
            var data: UserType = comptime blk: {
                var data: UserType = undefined;
                inline for (meta.fields(PartialSpec)) |field| {
                    if (@typeInfo(field.field_type) == .Optional) {
                        @field(data, field.name) = null;
                    }
                }
                break :blk data;
            };
            // if we ever encounter an error, we need to deinitialize all written fields. we used optional_written_fields to find the fields we wrote to.
            // this is an inline for loop since we need to access Specs types
            errdefer {
                inline for (meta.fields(PartialSpec)) |field, i| {
                    if (optional_written_fields.isSet(i)) {
                        const found_data = if (@typeInfo(field.field_type) == .Optional) @field(data, field.name).? else @field(data, field.name);
                        Specs[i].deinit(found_data, alloc);
                    }
                }
            }
            // this is the loop that goes through all available tag value pairs
            // found_end is here because we may find an End tag before we write all fields, so we use it to cancel the End read after the loop
            var found_end = false;
            while (optional_written_fields.count() < Specs.len) {
                const named_tag = try NamedTag.deserialize(alloc, reader);
                defer NamedTag.deinit(named_tag, alloc);
                if (named_tag.tag == .End) {
                    if (total_written_fields.count() < Specs.len) {
                        return error.InsufficientFields;
                    } else {
                        found_end = true;
                        break;
                    }
                }
                // since the fields of the serialized compound may be in any order, we need to find the field from a string
                const field_ind = @enumToInt(meta.stringToEnum(FieldEnum, named_tag.name) orelse return error.UnexpectedField);
                if (optional_written_fields.isSet(@intCast(usize, field_ind))) {
                    return error.DuplicateField;
                }
                blk: {
                    // use inline for to find and use corresponding Specs type to deserialize
                    inline for (meta.fields(PartialSpec)) |field, i| {
                        if (i == field_ind) {
                            const res = Specs[i].deserialize(alloc, reader);
                            if (meta.isError(res)) _ = res catch |err| return err;
                            const val = res catch unreachable;
                            @field(data, field.name) = val;
                            break :blk;
                        }
                    }
                    unreachable;
                }
                // tell the bit sets that this field is "written to"
                total_written_fields.setValue(@intCast(usize, field_ind), true);
                optional_written_fields.setValue(@intCast(usize, field_ind), true);
            }
            if (!found_end) {
                const named_tag = try NamedTag.deserialize(alloc, reader);
                defer NamedTag.deinit(named_tag, alloc);
                if (named_tag.tag != .End) {
                    return error.NoEnd;
                }
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            inline for (meta.fields(PartialSpec)) |field, i| {
                if (@typeInfo(field.field_type) == .Optional) {
                    if (@field(self, field.name)) |found_data| {
                        Specs[i].deinit(found_data, alloc);
                    }
                } else {
                    Specs[i].deinit(@field(self, field.name), alloc);
                }
            }
        }
        pub fn size(self: UserType) usize {
            var total_size: usize = 1; // Tag.End
            inline for (meta.fields(PartialSpec)) |field, i| {
                const is_optional = @typeInfo(field.field_type) == .Optional;
                const data = @field(self, field.name);
                const found_data: if (is_optional) @TypeOf(data) else ?@TypeOf(data) = data;
                // wtf
                if (found_data) |actual_data| {
                    if (isNbtSerializable(Specs[i])) {
                        if (Specs[i].getNbtType(actual_data)) |tag| {
                            const named_tag = NamedTag{
                                .tag = tag,
                                .name = field.name,
                            };
                            total_size += named_tag.size();
                        }
                    }
                    total_size += Specs[i].size(actual_data);
                }
            }
            return total_size;
        }
        pub fn getNbtType(self: UserType) ?Tag {
            _ = self;
            return Tag.Compound;
        }
    };
}

pub const TagDynNbtPair = struct {
    name: []const u8,
    value: DynamicNbtItem,
};

// note this cannot be used as a normal ser/de type
pub const DynamicNbtItem = union(Tag) {
    End: void,
    Byte: i8,
    Short: i16,
    Int: i32,
    Long: i64,
    Float: f32,
    Double: f64,
    ByteArray: []const i8,
    String: []const u8,
    List: []const DynamicNbtItem,
    Compound: DynamicCompoundSpec.UserType,
    IntArray: []const i32,
    LongArray: []const i64,

    pub const UserType = @This();
    pub fn write(self: UserType, writer: anytype) meta.Child(@TypeOf(writer)).Error!void {
        switch (self) {
            .End => {},
            .Byte => |d| try writer.writeIntBig(i8, d),
            .Short => |d| try writer.writeIntBig(i16, d),
            .Int => |d| try writer.writeIntBig(i32, d),
            .Long => |d| try writer.writeIntBig(i64, d),
            .Float => |d| try writer.writeIntBig(u32, @bitCast(u32, d)),
            .Double => |d| try writer.writeIntBig(u64, @bitCast(u64, d)),
            .ByteArray => |d| {
                try writer.writeIntBig(i32, @intCast(i32, d.len));
                for (d) |b| {
                    try writer.writeIntBig(i8, b);
                }
            },
            .String => |d| {
                try writer.writeIntBig(u16, @intCast(u16, d.len));
                try writer.writeAll(d);
            },
            .List => |d| {
                try writer.writeByte(if (d.len == 0) 0x00 else @enumToInt(meta.activeTag(d[0])));
                try writer.writeIntBig(i32, @intCast(i32, d.len));
                for (d) |b| {
                    try b.write(writer);
                }
            },
            .IntArray => |d| {
                try writer.writeIntBig(i32, @intCast(i32, d.len));
                for (d) |b| {
                    try writer.writeIntBig(i32, b);
                }
            },
            .LongArray => |d| {
                try writer.writeIntBig(i32, @intCast(i32, d.len));
                for (d) |b| {
                    try writer.writeIntBig(i64, b);
                }
            },
            .Compound => |d| try DynamicCompoundSpec.write(d, writer),
        }
    }
    pub fn deserialize(alloc: Allocator, reader: anytype, tag: Tag) (meta.Child(@TypeOf(reader)).Error || Allocator.Error || error{EndOfStream} || CompoundError)!UserType {
        switch (tag) {
            .End => return DynamicNbtItem.End,
            .Byte => return DynamicNbtItem{ .Byte = try NumSpec(i8).deserialize(alloc, reader) },
            .Short => return DynamicNbtItem{ .Short = try NumSpec(i16).deserialize(alloc, reader) },
            .Int => return DynamicNbtItem{ .Int = try NumSpec(i32).deserialize(alloc, reader) },
            .Long => return DynamicNbtItem{ .Long = try NumSpec(i64).deserialize(alloc, reader) },
            .Float => return DynamicNbtItem{ .Float = try NumSpec(f32).deserialize(alloc, reader) },
            .Double => return DynamicNbtItem{ .Double = try NumSpec(f64).deserialize(alloc, reader) },
            .ByteArray => {
                const len = @intCast(usize, try NumSpec(i32).deserialize(alloc, reader));
                var data = try alloc.alloc(i8, len);
                errdefer alloc.free(data);
                for (data) |*item| {
                    item.* = try NumSpec(i8).deserialize(alloc, reader);
                }
                return DynamicNbtItem{ .ByteArray = data };
            },
            .String => {
                const len = @intCast(usize, try NumSpec(u16).deserialize(alloc, reader));
                var data = try alloc.alloc(u8, len);
                errdefer alloc.free(data);
                try reader.readNoEof(data);
                return DynamicNbtItem{ .String = data };
            },
            .List => {
                const inner_tag = @intToEnum(Tag, try reader.readByte());
                const len = @intCast(usize, try NumSpec(i32).deserialize(alloc, reader));
                var data = try alloc.alloc(DynamicNbtItem, len);
                errdefer alloc.free(data);
                for (data) |*item, i| {
                    errdefer {
                        var ind: usize = 0;
                        while (ind < i) : (ind += 1) {
                            data[i].deinit(alloc);
                        }
                    }
                    item.* = try DynamicNbtItem.deserialize(alloc, reader, inner_tag);
                }
                return DynamicNbtItem{ .List = data };
            },
            .IntArray => {
                const len = @intCast(usize, try NumSpec(i32).deserialize(alloc, reader));
                var data = try alloc.alloc(i32, len);
                errdefer alloc.free(data);
                for (data) |*item| {
                    item.* = try NumSpec(i32).deserialize(alloc, reader);
                }
                return DynamicNbtItem{ .IntArray = data };
            },
            .LongArray => {
                const len = @intCast(usize, try NumSpec(i32).deserialize(alloc, reader));
                var data = try alloc.alloc(i64, len);
                errdefer alloc.free(data);
                for (data) |*item| {
                    item.* = try NumSpec(i64).deserialize(alloc, reader);
                }
                return DynamicNbtItem{ .LongArray = data };
            },
            .Compound => return DynamicNbtItem{ .Compound = try DynamicCompoundSpec.deserialize(alloc, reader) },
        }
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        switch (self) {
            .End, .Byte, .Short, .Int, .Long, .Float, .Double => {},
            .ByteArray => |d| alloc.free(d),
            .String => |d| alloc.free(d),
            .List => |d| {
                for (d) |item| {
                    item.deinit(alloc);
                }
                alloc.free(d);
            },
            .IntArray => |d| alloc.free(d),
            .LongArray => |d| alloc.free(d),
            .Compound => |d| DynamicCompoundSpec.deinit(d, alloc),
        }
    }
    pub fn size(self: UserType) usize {
        var total_size: usize = 0;
        switch (self) {
            .End => {},
            .Byte => total_size += 1,
            .Short => total_size += 2,
            .Int => total_size += 4,
            .Long => total_size += 8,
            .Float => total_size += 4,
            .Double => total_size += 8,
            .ByteArray => |d| total_size += 4 + d.len,
            .String => |d| total_size += 2 + d.len,
            .List => |d| {
                total_size += 1 + 4;
                for (d) |b| {
                    total_size += b.size();
                }
            },
            .IntArray => |d| total_size += 4 + d.len * 4,
            .LongArray => |d| total_size += 4 + d.len * 8,
            .Compound => |d| {
                for (d) |pair| {
                    const named_tag = NamedTag{
                        .tag = meta.activeTag(pair.value),
                        .name = pair.name,
                    };
                    total_size += named_tag.size() + pair.value.size();
                }
                total_size += 1;
            },
        }
        return total_size;
    }
    pub fn getNbtType(self: UserType) ?Tag {
        return meta.activeTag(self);
    }
};

test "dynamic nbt item" {
    const data = DynamicNbtItem{ .Compound = &[_]TagDynNbtPair{
        .{ .name = "test", .value = DynamicNbtItem{ .ByteArray = &[_]i8{ 1, 2, 3 } } },
        .{ .name = "again", .value = DynamicNbtItem{ .List = &[_]DynamicNbtItem{.{ .Short = 5 }} } },
    } };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try data.write(&buf.writer());
    // https://wiki.vg/NBT#test.nbt
    const expected = [_]u8{ @enumToInt(Tag.ByteArray), 0, 4, 't', 'e', 's', 't', 0, 0, 0, 3, 0x01, 0x02, 0x03, @enumToInt(Tag.List), 0, 5, 'a', 'g', 'a', 'i', 'n', @enumToInt(Tag.Short), 0, 0, 0, 1, 0, 5, @enumToInt(Tag.End) };
    try testing.expectEqualSlices(u8, &expected, buf.items);
    try testing.expectEqual(expected.len, data.size());
    var read_stream = std.io.fixedBufferStream(&expected);
    const de_res = try DynamicNbtItem.deserialize(testing.allocator, &read_stream.reader(), Tag.Compound);
    defer de_res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), de_res.Compound.len);
    try testing.expectEqualStrings("test", de_res.Compound[0].name);
    try testing.expectEqualStrings("again", de_res.Compound[1].name);
    try testing.expectEqual(@as(usize, 3), de_res.Compound[0].value.ByteArray.len);
    try testing.expectEqualSlices(i8, data.Compound[0].value.ByteArray, de_res.Compound[0].value.ByteArray);
    try testing.expectEqual(@as(usize, 1), de_res.Compound[1].value.List.len);
    try testing.expectEqual(@as(i16, 5), de_res.Compound[1].value.List[0].Short);
}

pub const DynamicCompoundSpec = struct {
    pub const UserType = []const TagDynNbtPair;
    pub fn write(self: UserType, writer: anytype) !void {
        for (self) |pair| {
            const named_tag = NamedTag{
                .tag = meta.activeTag(pair.value),
                .name = pair.name,
            };
            try named_tag.write(writer);
            try pair.value.write(writer);
        }
        try (NamedTag{ .tag = .End, .name = "" }).write(writer);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        var data = std.ArrayList(TagDynNbtPair).init(alloc);
        defer data.deinit();
        errdefer {
            for (data.items) |item| {
                alloc.free(item.name);
                item.value.deinit(alloc);
            }
        }
        while (true) {
            const named_tag = try NamedTag.deserialize(alloc, reader);
            if (named_tag.tag == .End) {
                break;
            }
            const item = try DynamicNbtItem.deserialize(alloc, reader, named_tag.tag);
            errdefer item.deinit(alloc);
            try data.append(.{
                .name = named_tag.name,
                .value = item,
            });
        }
        return data.toOwnedSlice();
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        for (self) |pair| {
            alloc.free(pair.name);
            pair.value.deinit(alloc);
        }
        alloc.free(self);
    }
    pub fn size(self: UserType) usize {
        var total_size: usize = 1; // Tag.End
        for (self) |pair| {
            const named_tag = NamedTag{
                .tag = meta.activeTag(pair.value),
                .name = pair.name,
            };
            total_size += named_tag.size() + pair.value.size();
        }
        return total_size;
    }
    pub fn getNbtType(self: UserType) ?Tag {
        _ = self;
        return Tag.Compound;
    }
};

pub const NamedSpecError = error{
    IncorrectTag,
    IncorrectName,
};

pub fn NamedSpec(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub const SubSpec = T;
        pub const UserType = T.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            if (T.getNbtType(self)) |tag| {
                try (NamedTag{ .tag = tag, .name = name }).write(writer);
            }
            try T.write(self, writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const named_tag = try NamedTag.deserialize(alloc, reader);
            defer NamedTag.deinit(named_tag, alloc);
            if (!std.mem.eql(u8, named_tag.name, name)) {
                return error.IncorrectName;
            }
            const result = try T.deserialize(alloc, reader);
            errdefer T.deinit(result, alloc);
            if (T.getNbtType(result)) |tag| {
                if (named_tag.tag != tag) {
                    return error.IncorrectTag;
                }
            }
            return result;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            return T.deinit(self, alloc);
        }
        pub fn size(self: UserType) usize {
            var total_size: usize = 0;
            if (T.getNbtType(self)) |tag| {
                total_size += (NamedTag{ .tag = tag, .name = name }).size();
            }
            total_size += T.size(self);
            return total_size;
        }
        pub fn getNbtType(self: UserType) ?Tag {
            return T.getNbtType(self);
        }
    };
}

pub fn NbtTypeWrapperSpec(comptime T: type, comptime tag: ?Tag) type {
    return struct {
        pub const UserType = T.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            return T.write(self, writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            return T.deserialize(alloc, reader);
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            T.deinit(self, alloc);
        }
        pub fn size(self: UserType) usize {
            return T.size(self);
        }
        pub fn getNbtType(self: UserType) ?Tag {
            _ = self;
            return tag;
        }
    };
}

pub const ListSpecError = error{
    IncorrectTag,
};

pub fn ListSpec(comptime UsedSpec: type, comptime T: type) type {
    const tag = tagFromType(T);
    return struct {
        const ElemType = UsedSpec.Spec(T);
        const ListType = serde.PrefixedArray(UsedSpec, serde.NumSpec(i32, .Big), ElemType);
        pub const UserType = ListType.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeByte(@enumToInt(tag));
            try ListType.write(self, writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const read_tag = @intToEnum(Tag, try reader.readByte());
            if (read_tag != tag) {
                return error.IncorrectTag;
            }
            return try ListType.deserialize(alloc, reader);
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            ListType.deinit(self, alloc);
        }
        pub fn size(self: UserType) usize {
            return 1 + ListType.size(self);
        }
        pub fn getNbtType(self: UserType) ?Tag {
            _ = self;
            return Tag.List;
        }
    };
}

pub fn tagFromType(comptime T: type) Tag {
    switch (@typeInfo(T)) {
        .Struct => return .Compound,
        .Bool => return .Byte,
        .Int => |info| {
            return switch (info.bits) {
                8 => .Byte,
                16 => .Short,
                32 => .Int,
                64 => .Long,
                else => unreachable,
            };
        },
        .Float => |info| {
            return switch (info.bits) {
                32 => .Float,
                64 => .Double,
                else => unreachable,
            };
        },
        .Pointer => |info| {
            if (meta.trait.isZigString(T)) {
                return .String;
            }
            const child_info = @typeInfo(info.child);
            if (child_info == .Int) {
                return switch (child_info.Int.bits) {
                    8 => .ByteArray,
                    32 => .IntArray,
                    64 => .LongArray,
                    else => unreachable,
                };
            }
            return .List;
        },
        else => @compileError("cant find tag from type " ++ @typeName(T)),
    }
}

pub fn NumSpec(comptime T: type) type {
    return NbtTypeWrapperSpec(serde.NumSpec(T, .Big), tagFromType(T));
}
pub const VoidSpec = NbtTypeWrapperSpec(serde.VoidSpec, null);
pub const BoolSpec = NbtTypeWrapperSpec(serde.BoolSpec, .Byte);
pub const StringSpec = NbtTypeWrapperSpec(serde.PrefixedArray(serde.DefaultSpec, u16, u8), .String);
pub fn SpecificListSpec(comptime PartialSpec: type) type {
    const info = @typeInfo(PartialSpec).Pointer;
    return NbtTypeWrapperSpec(serde.PrefixedArray(NbtSpec, serde.NumSpec(i32, .Big), info.child), tagFromType(PartialSpec));
}

pub const NbtSpec = struct {
    pub fn Spec(comptime PartialSpec: type) type {
        if (serde.isSerializable(PartialSpec)) {
            if (isNbtSerializable(PartialSpec)) {
                return PartialSpec;
            } else {
                return NbtTypeWrapperSpec(PartialSpec, null);
            }
        }
        switch (@typeInfo(PartialSpec)) {
            .Void => return VoidSpec,
            .Struct => return CompoundSpec(@This(), PartialSpec),
            .Bool => return BoolSpec,
            .Int => |info| {
                assert(info.signedness == .signed);
                return NumSpec(PartialSpec);
            },
            .Float => return NumSpec(PartialSpec),
            .Pointer => |info| {
                assert(info.size == .Slice);
                if (meta.trait.isZigString(PartialSpec)) {
                    return StringSpec;
                }
                const child_info = @typeInfo(info.child);
                if (child_info == .Int and child_info.Int.bits != 16) {
                    return SpecificListSpec(PartialSpec);
                }
                return ListSpec(@This(), info.child);
            },
            else => @compileError("dont know how to nbt spec " ++ @typeName(PartialSpec)),
        }
    }
};

pub fn isNbtSerializable(comptime T: type) bool {
    return serde.isSerializable(T) and @hasDecl(T, "getNbtType");
}

test "test.nbt" {
    const DataType = NamedSpec(NbtSpec.Spec(struct {
        name: []const u8,
    }), "hello world");
    const data = DataType.UserType{ .name = "Bananrama" };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try DataType.write(data, &buf.writer());
    // https://wiki.vg/NBT#test.nbt
    const expected = [_]u8{ 0x0a, 0x00, 0x0b, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x08, 0x00, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x00, 0x09, 0x42, 0x61, 0x6e, 0x61, 0x6e, 0x72, 0x61, 0x6d, 0x61, 0x00 };
    try testing.expectEqualSlices(u8, &expected, buf.items);
    try testing.expectEqual(expected.len, DataType.size(data));
    var read_stream = std.io.fixedBufferStream(&expected);
    const de_res = try DataType.deserialize(testing.allocator, &read_stream.reader());
    defer DataType.deinit(de_res, testing.allocator);
    try testing.expect(std.mem.eql(u8, data.name, de_res.name));
}

test "bigtest.nbt" {
    const DataType = NamedSpec(NbtSpec.Spec(struct {
        @"nested compound test": struct {
            egg: struct {
                name: []const u8,
                value: f32,
            },
            ham: struct {
                name: []const u8,
                value: f32,
            },
        },
        intTest: i32,
        byteTest: i8,
        stringTest: []const u8,
        @"listTest (long)": ListSpec(NbtSpec, i64),
        // cant do []i64 cause itll autodetect as LongArray
        doubleTest: f64,
        floatTest: f32,
        longTest: i64,
        @"listTest (compound)": []struct {
            @"created-on": i64,
            name: []const u8,
        },
        @"byteArrayTest (the first 1000 values of (n*n*255+n*7)%100, starting with n=0 (0, 62, 34, 16, 8, ...))": []i8,
        shortTest: i16,
    }), "Level");
    const bigtest_raw = @embedFile("test/bigtest.nbt");
    var bigtest_raw_stream = std.io.fixedBufferStream(bigtest_raw);
    var gzip_stream = try gzip.gzipStream(testing.allocator, bigtest_raw_stream.reader());
    defer gzip_stream.deinit();
    const result = try DataType.deserialize(testing.allocator, gzip_stream.reader());
    defer DataType.deinit(result, testing.allocator);
    //std.debug.print("result: {any}\n", .{result});
    try testing.expectEqual(@as(i32, 2147483647), result.intTest);
    try testing.expectEqualStrings("Eggbert", result.@"nested compound test".egg.name);
    try testing.expectEqualStrings("Hampus", result.@"nested compound test".ham.name);
    try testing.expect(std.math.approxEqAbs(f32, 0.5, result.@"nested compound test".egg.value, std.math.epsilon(f32) * 10));
    try testing.expect(std.math.approxEqAbs(f32, 0.75, result.@"nested compound test".ham.value, std.math.epsilon(f32) * 10));
    try testing.expect(std.math.approxEqAbs(f32, 0.49823147058486938, result.floatTest, std.math.epsilon(f32) * 10));
    try testing.expect(std.math.approxEqAbs(f64, 0.49312871321823148, result.doubleTest, std.math.epsilon(f64) * 10));
    try testing.expectEqualStrings("HELLO WORLD THIS IS A TEST STRING \xc3\x85\xc3\x84\xc3\x96!", result.stringTest); // strings in bigtest.nbt are in utf8, not ascii
    try testing.expectEqual(@as(usize, 5), result.@"listTest (long)".len);
    inline for (.{ 11, 12, 13, 14, 15 }) |item, i| {
        try testing.expectEqual(@as(i64, item), result.@"listTest (long)"[i]);
    }
    try testing.expectEqual(@as(i64, 9223372036854775807), result.longTest);
    try testing.expectEqual(@as(usize, 2), result.@"listTest (compound)".len);
    inline for (.{ .{ 1264099775885, "Compound tag #0" }, .{ 1264099775885, "Compound tag #1" } }) |pair, i| {
        try testing.expectEqualStrings(pair[1], result.@"listTest (compound)"[i].name);
        try testing.expectEqual(@as(i64, pair[0]), result.@"listTest (compound)"[i].@"created-on");
    }
    try testing.expectEqual(@as(usize, 1000), result.@"byteArrayTest (the first 1000 values of (n*n*255+n*7)%100, starting with n=0 (0, 62, 34, 16, 8, ...))".len);
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const expected = @intCast(i8, @truncate(u8, (n * n * 255 + n * 7) % 100));
        try testing.expectEqual(expected, result.@"byteArrayTest (the first 1000 values of (n*n*255+n*7)%100, starting with n=0 (0, 62, 34, 16, 8, ...))"[n]);
    }
    try testing.expectEqual(@as(i16, 32767), result.shortTest);
}

test "optional compound fields" {
    const SubType = struct {
        name: ?[]const u8,
        id: ?i16,
        alive: bool,
    };
    const DataType = NamedSpec(NbtSpec.Spec([]SubType), "test");
    const data: DataType.UserType = &.{
        .{ .name = null, .id = null, .alive = true },
        .{ .name = "hi", .id = 5, .alive = false },
    };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try DataType.write(data, &buf.writer());
    const expected_0 = [_]u8{ @enumToInt(Tag.Byte), 0, 5, 'a', 'l', 'i', 'v', 'e', 0x01, @enumToInt(Tag.End) };
    const expected_1 = [_]u8{ @enumToInt(Tag.String), 0, 4, 'n', 'a', 'm', 'e', 0, 2, 'h', 'i', @enumToInt(Tag.Short), 0, 2, 'i', 'd', 0, 5, @enumToInt(Tag.Byte), 0, 5, 'a', 'l', 'i', 'v', 'e', 0x00, @enumToInt(Tag.End) };
    const expected = [_]u8{ @enumToInt(Tag.List), 0, 4, 't', 'e', 's', 't', @enumToInt(Tag.Compound), 0, 0, 0, 2 } ++ expected_0 ++ expected_1;
    //std.debug.print("\nexpected: {any}\nfound   : {any}\n", .{ std.mem.span(&expected), buf.items });
    try testing.expectEqualSlices(u8, &expected, buf.items);
    try testing.expectEqual(expected.len, DataType.size(data));
    var read_stream = std.io.fixedBufferStream(&expected);
    const de_res = try DataType.deserialize(testing.allocator, &read_stream.reader());
    defer DataType.deinit(de_res, testing.allocator);
    try testing.expectEqual(@as(usize, 2), de_res.len);
    inline for (data) |elem, i| {
        if (elem.name) |name| {
            try testing.expectEqualStrings(name, de_res[i].name.?);
        } else {
            try testing.expectEqual(@as(?[]const u8, null), de_res[i].name);
        }
        if (elem.id) |id| {
            try testing.expectEqual(id, de_res[i].id.?);
        } else {
            try testing.expectEqual(@as(?i16, null), de_res[i].id);
        }
        try testing.expectEqual(elem.alive, de_res[i].alive);
    }
}
