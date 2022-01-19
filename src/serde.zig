const std = @import("std");
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = std.builtin;
const Allocator = std.mem.Allocator;

pub fn NumSpec(comptime T: type, endian: std.builtin.Endian) type {
    const info = @typeInfo(T);
    if (info != .Int and info != .Float) {
        @compileError("expected an int or a float");
    }
    return struct {
        const IntType = if (info == .Float) meta.Int(.unsigned, info.Float.bits) else T;
        pub const UserType = T;
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeInt(IntType, @bitCast(IntType, self), endian);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            _ = alloc;
            const val = try reader.readInt(IntType, endian);
            return @bitCast(T, val);
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
        pub fn size(self: UserType) usize {
            _ = self;
            return @sizeOf(T);
        }
    };
}

pub const BoolSpec = struct {
    pub const UserType = bool;
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeByte(if (self) 0x01 else 0x00);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        _ = alloc;
        return (try reader.readByte()) == 0x01;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return 1;
    }
};

pub const VoidSpec = struct {
    pub const UserType = void;
    pub fn write(self: UserType, writer: anytype) !void {
        _ = self;
        _ = writer;
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        _ = alloc;
        _ = reader;
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn size(self: UserType) usize {
        _ = self;
        return 0;
    }
};

pub fn StructFieldSpecs(comptime UsedSpec: type, comptime PartialSpec: type) [meta.fields(PartialSpec).len]type {
    const info = @typeInfo(PartialSpec).Struct;
    var specs: [info.fields.len]type = undefined;
    inline for (info.fields) |field, i| {
        const SpecType = UsedSpec.Spec(field.field_type);
        specs[i] = SpecType;
    }
    return specs;
}

pub fn StructUserType(comptime PartialSpec: type, comptime Specs: []const type) type {
    const info = @typeInfo(PartialSpec).Struct;
    var fields: [info.fields.len]builtin.TypeInfo.StructField = undefined;
    inline for (info.fields) |*field, i| {
        var f = field.*;
        f.field_type = Specs[i].UserType;
        f.default_value = null;
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Struct = .{
        .layout = info.layout,
        .fields = &fields,
        .decls = &[_]builtin.TypeInfo.Declaration{},
        .is_tuple = info.is_tuple,
    } });
}

pub fn StructSpec(comptime UsedSpec: type, comptime PartialSpec: type) type {
    const info = @typeInfo(PartialSpec).Struct;
    return struct {
        pub const Specs = StructFieldSpecs(UsedSpec, PartialSpec);
        pub const UserType = StructUserType(PartialSpec, std.mem.span(&Specs));
        pub fn write(self: UserType, writer: anytype) !void {
            inline for (info.fields) |field, i| {
                try Specs[i].write(@field(self, field.name), writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            var data: UserType = undefined;
            inline for (info.fields) |field, i| {
                @field(data, field.name) = try Specs[i].deserialize(alloc, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            inline for (info.fields) |field, i| {
                Specs[i].deinit(@field(self, field.name), alloc);
            }
        }
        pub fn size(self: UserType) usize {
            var total_size: usize = 0;
            inline for (info.fields) |field, i| {
                total_size += Specs[i].size(@field(self, field.name));
            }
            return total_size;
        }
    };
}

pub fn isIntType(comptime SpecType: type) bool {
    if (isSerializable(SpecType)) {
        return @typeInfo(SpecType.UserType) == .Int;
    } else {
        return @typeInfo(SpecType) == .Int;
    }
}

pub fn EnumSpec(comptime UsedSpec: type, comptime TagType: type, comptime UserType: type) type {
    const TagSpec = UsedSpec.Spec(TagType);
    assert(@typeInfo(TagSpec.UserType) == .Int);
    assert(@typeInfo(UserType) == .Enum);
    return struct {
        pub const UserType = UserType;
        pub fn getInt(self: UserType) TagSpec.UserType {
            return @intCast(TagSpec.UserType, @enumToInt(self));
        }
        pub fn write(self: UserType, writer: anytype) !void {
            try TagSpec.write(getInt(self), writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            return @intToEnum(UserType, try TagSpec.deserialize(alloc, reader));
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
        pub fn size(self: UserType) usize {
            return TagSpec.size(getInt(self));
        }
    };
}

pub fn UnionSpecs(comptime UsedSpec: type, comptime PartialUnionSpec: type) [meta.fields(PartialUnionSpec).len]type {
    const info = @typeInfo(PartialUnionSpec).Union;
    var specs: [info.fields.len]type = undefined;
    inline for (info.fields) |field, i| {
        specs[i] = UsedSpec.Spec(field.field_type);
    }
    return specs;
}

pub fn UnionUserType(comptime PartialSpec: type, comptime Specs: []const type) type {
    const info = @typeInfo(PartialSpec).Union;
    var fields: [info.fields.len]builtin.TypeInfo.UnionField = undefined;
    inline for (info.fields) |*field, i| {
        var f = field.*;
        f.field_type = Specs[i].UserType;
        fields[i] = f;
    }
    return @Type(builtin.TypeInfo{ .Union = .{
        .layout = info.layout,
        .tag_type = info.tag_type,
        .fields = &fields,
        .decls = &[_]std.builtin.TypeInfo.Declaration{},
    } });
}

// special (incompatible with normal ser/de)
pub fn UnionSpec(comptime UsedSpec: type, comptime PartialUnionSpec: type) type {
    assert(@typeInfo(PartialUnionSpec) == .Union);
    return struct {
        pub const Specs = UnionSpecs(UsedSpec, PartialUnionSpec);
        pub const UserType = UnionUserType(PartialUnionSpec, std.mem.span(&Specs));
        pub const IntType = meta.Tag(meta.Tag(UserType));
        pub fn getInt(self: UserType) IntType {
            return @intCast(IntType, @enumToInt(self));
        }
        fn tagEnumField(comptime i: comptime_int) builtin.TypeInfo.EnumField {
            return meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
        }
        pub fn write(self: UserType, writer: anytype) !void {
            const tag_int = getInt(self);
            inline for (meta.fields(UserType)) |field, i| {
                //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                const enum_field = tagEnumField(i);
                if (enum_field.value == tag_int) {
                    const res = Specs[i].write(@field(self, field.name), writer);
                    if (meta.isError(res)) res catch |err| return err;
                    return;
                }
            }
            return error.InvalidTag;
        }
        pub fn deserialize(alloc: Allocator, reader: anytype, tag_int: IntType) !UserType {
            inline for (meta.fields(UserType)) |field, i| {
                //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                const enum_field = tagEnumField(i);
                if (enum_field.value == tag_int) {
                    // untested if this workaround is necessary for write, but it
                    // is necessary for deserialize https://github.com/ziglang/zig/issues/10087
                    const res = Specs[i].deserialize(alloc, reader);
                    if (meta.isError(res)) _ = res catch |err| return err;
                    const val = res catch unreachable;
                    return @unionInit(UserType, field.name, val);
                }
            }
            return error.InvalidTag;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            const tag_int = getInt(self);
            inline for (meta.fields(UserType)) |field, i| {
                _ = field;
                //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                const enum_field = tagEnumField(i);
                if (enum_field.value == tag_int) {
                    Specs[i].deinit(@field(self, field.name), alloc);
                    return;
                }
            }
        }
        pub fn size(self: UserType) usize {
            const tag_int = getInt(self);
            inline for (meta.fields(UserType)) |field, i| {
                _ = field;
                //const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                const enum_field = tagEnumField(i);
                if (enum_field.value == tag_int) {
                    return Specs[i].size(@field(self, field.name));
                }
            }
            return 0;
        }
    };
}

pub fn TaggedUnionSpec(comptime UsedSpec: type, comptime TagType: type, comptime PartialUnionSpec: type) type {
    const TagSpec = UsedSpec.Spec(TagType);
    assert(@typeInfo(TagSpec.UserType) == .Int);
    return struct {
        pub const UnionType = UnionSpec(UsedSpec, PartialUnionSpec);
        pub const UserType = UnionType.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            const tag_int = UnionType.getInt(self);
            try TagSpec.write(tag_int, writer);
            try UnionType.write(self, writer);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const tag_int = try TagSpec.deserialize(alloc, reader);
            return try UnionType.deserialize(alloc, reader, tag_int);
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            UnionType.deinit(self, alloc);
        }
        pub fn size(self: UserType) usize {
            const tag_int = UnionType.getInt(self);
            return TagSpec.size(tag_int) + UnionType.size(self);
        }
    };
}

test "serde tagged union" {
    const TestEnum = enum(u8) {
        A = 0,
        B = 1,
        C = 2,
        D = 4,
    };
    const TestUnion = union(TestEnum) {
        A: u8,
        B: u16,
        C: void,
        D: struct {
            a: i32,
            b: bool,
        },
    };
    const SerdeUnion = TaggedUnionSpec(DefaultSpec, u8, TestUnion);
    inline for (.{
        .{ .buf = [_]u8{ 0x00, 0x05 }, .desired = SerdeUnion.UserType{ .A = 5 } },
        .{ .buf = [_]u8{ 0x01, 0x01, 0x00 }, .desired = SerdeUnion.UserType{ .B = 256 } },
        .{ .buf = [_]u8{0x02}, .desired = SerdeUnion.UserType.C },
        .{ .buf = [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x08, 0x01 }, .desired = SerdeUnion.UserType{ .D = .{ .a = 8, .b = true } } },
    }) |pair| {
        var stream = std.io.fixedBufferStream(&pair.buf);
        const result = try SerdeUnion.deserialize(testing.allocator, &stream.reader());
        try testing.expect(meta.eql(result, pair.desired));
    }
}

pub fn PackedSpec(comptime T: type) type {
    return struct {
        pub const UserType = T;
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeStruct(self);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            _ = alloc;
            return reader.readStruct(UserType);
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
}

test "packed spec" {
    const TestStruct = PackedSpec(packed struct {
        a: bool,
        b: bool,
        c: bool,
        d: bool,
        e: bool,
        f: bool,
    });
    // 0b11010000 -> 0xD0
    //       4321
    const buf = [_]u8{0xD0};
    var stream = std.io.fixedBufferStream(&buf);
    const result = try TestStruct.deserialize(testing.allocator, &stream.reader());
    try testing.expect(meta.eql(result, .{
        .a = false,
        .b = false,
        .c = false,
        .d = false,
        .e = true,
        .f = false,
    }));
}

pub fn ArraySpec(comptime UsedSpec: type, comptime PartialSpec: type) type {
    const info = @typeInfo(PartialSpec).Array;
    return struct {
        pub const ElemSpec = UsedSpec.Spec(info.child);
        pub const UserType = [info.len]ElemSpec.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            for (self) |item| {
                try ElemSpec.write(item, writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            var data: UserType = undefined;
            for (data) |*item, i| {
                errdefer {
                    var ind: usize = 0;
                    while (ind < i) : (i += 1) {
                        ElemSpec.deinit(data[i], alloc);
                    }
                }
                item.* = try ElemSpec.deserialize(alloc, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            for (self) |item| {
                ElemSpec.deinit(item, alloc);
            }
        }
        pub fn size(self: UserType) usize {
            var total_size: usize = 0;
            for (self) |item| {
                total_size += ElemSpec.size(item);
            }
            return total_size;
        }
    };
}

pub const DefaultSpec = struct {
    pub fn Spec(comptime PartialSpec: type) type {
        if (isSerializable(PartialSpec)) {
            // partial spec is already a full spec
            return PartialSpec;
        }
        switch (@typeInfo(PartialSpec)) {
            .Void => return VoidSpec,
            .Bool => return BoolSpec,
            .Int => return NumSpec(PartialSpec, .Big),
            .Float => return NumSpec(PartialSpec, .Big),
            .Struct => |info| {
                if (info.layout == .Packed) {
                    return PackedSpec(PartialSpec);
                } else {
                    return StructSpec(@This(), PartialSpec);
                }
            },
            .Optional => return OptionalSpec(@This(), PartialSpec),
            .Enum => return EnumSpec(@This(), meta.Tag(PartialSpec), PartialSpec),
            else => @compileError("dont know how to do full spec for " ++ @typeName(PartialSpec)),
        }
    }
};

pub fn isSerializable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .Struct and info != .Union and info != .Enum) return false;
    inline for (.{ "write", "deserialize", "size", "UserType" }) |name| {
        if (!@hasDecl(T, name)) {
            return false;
        }
    }
    return true;
}

test "serde full spec" {
    const SpecType = DefaultSpec.Spec(struct {
        a: i32,
        b: struct {
            c: bool,
            d: u8,
            e: NumSpec(u16, .Little),
        },
        c: enum(u8) { A = 0x00, B = 0x01, C = 0x02 },
    });

    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02 };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.deserialize(testing.allocator, &reader.reader());
    try testing.expect(meta.eql(SpecType.UserType{
        .a = 258,
        .b = .{
            .c = true,
            .d = 0x08,
            .e = 0x10,
        },
        .c = .C,
    }, result));
    try testing.expectEqual(buf.len, SpecType.size(result));
}

pub const Remaining = struct {
    pub const UserType = []const u8;
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeAll(self);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        var data = std.ArrayList(u8).init(alloc);
        defer data.deinit(); // also should act as errdefer
        var buf: [1024]u8 = undefined;
        while (true) {
            const len = try reader.read(&buf);
            if (len == 0) {
                break;
            }
            try data.appendSlice(buf[0..len]);
        }
        return data.toOwnedSlice();
    }
    pub fn deinit(self: UserType, alloc: Allocator) void {
        alloc.free(self);
    }
    pub fn size(self: UserType) usize {
        return self.len;
    }
};

test "serde remaining" {
    const SpecType = DefaultSpec.Spec(struct {
        a: i32,
        data: Remaining,
    });

    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02 };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.deserialize(testing.allocator, &reader.reader());
    defer SpecType.deinit(result, testing.allocator);
    try testing.expectEqual(@as(i32, 258), result.a);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x08, 0x10, 0x00, 0x02 }, result.data);
    try testing.expectEqual(buf.len, SpecType.size(result));
}

pub fn SizePrefixedArray(comptime UsedSpec: type, comptime PartialLengthSpec: type, comptime T: type) type {
    return struct {
        pub const ElemType = UsedSpec.Spec(T);
        pub const LengthType = UsedSpec.Spec(PartialLengthSpec);
        pub const UserType = []const ElemType.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            var elements_size: usize = 0;
            for (self) |item| {
                elements_size += ElemType.size(item);
            }
            try LengthType.write(@intCast(LengthType.UserType, elements_size), writer);
            for (self) |item| {
                try ElemType.write(item, writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const bytes_len = @intCast(usize, try LengthType.deserialize(alloc, reader));
            var limited_reader = std.io.limitedReader(reader, @intCast(usize, bytes_len));
            var lim_reader = limited_reader.reader();
            var data = std.ArrayList(ElemType.UserType).init(alloc);
            defer data.deinit();
            errdefer {
                for (data) |item| {
                    ElemType.deinit(item, alloc);
                }
            }
            while (true) {
                const result = try ElemType.deserialize(alloc, lim_reader);
                if (result == error.EndOfStream) {
                    break;
                }
                try data.append(try result);
            }
            return data.toOwnedSlice();
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            for (self) |item| {
                ElemType.deinit(item, alloc);
            }
            alloc.free(self);
        }
        pub fn size(self: UserType) usize {
            var elements_size: usize = 0;
            for (self) |item| {
                elements_size += ElemType.size(item);
            }
            return LengthType.size(@intCast(LengthType.UserType, elements_size)) + elements_size;
        }
    };
}

pub fn PrefixedArray(comptime UsedSpec: type, comptime PartialLengthSpec: type, comptime PartialSpec: type) type {
    const LengthSpec = UsedSpec.Spec(PartialLengthSpec);
    const SpecType = UsedSpec.Spec(PartialSpec);
    return struct {
        pub const UserType = []const SpecType.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            try LengthSpec.write(@intCast(LengthSpec.UserType, self.len), writer);
            for (self) |elem| {
                try SpecType.write(elem, writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const len = @intCast(usize, try LengthSpec.deserialize(alloc, reader));
            var data = try alloc.alloc(SpecType.UserType, len);
            errdefer alloc.free(data);
            for (data) |*elem, i| {
                errdefer {
                    var ind: usize = 0;
                    while (ind < i) : (ind += 1) {
                        SpecType.deinit(data[ind], alloc);
                    }
                }
                elem.* = try SpecType.deserialize(alloc, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            for (self) |elem| {
                SpecType.deinit(elem, alloc);
            }
            alloc.free(self);
        }
        pub fn size(self: UserType) usize {
            var total_size = LengthSpec.size(@intCast(LengthSpec.UserType, self.len));
            for (self) |elem| {
                total_size += SpecType.size(elem);
            }
            return total_size;
        }
    };
}

test "serde prefixed array" {
    const SpecType = PrefixedArray(DefaultSpec, u8, u16);

    const buf = [_]u8{
        0x04, // <-- length
        0x00, // beginning of data
        0x01,
        0x02,
        0x01,
        0x08,
        0x10,
        0x00,
        0x02,
    };
    var reader = std.io.fixedBufferStream(&buf);
    const result = try SpecType.deserialize(testing.allocator, &reader.reader());
    defer SpecType.deinit(result, testing.allocator);
    try testing.expectEqualSlices(u16, &[_]u16{ 0x0001, 0x0201, 0x0810, 0x0002 }, result);
    try testing.expectEqual(buf.len, SpecType.size(result));
}

pub fn OptionalSpec(comptime UsedSpec: type, comptime PartialSpec: type) type {
    const InnerSpec = UsedSpec.Spec(@typeInfo(PartialSpec).Optional.child);
    return struct {
        pub const UserType = ?InnerSpec.UserType;
        pub fn write(self: UserType, writer: anytype) !void {
            try BoolSpec.write(self != null, writer);
            if (self) |inner| {
                try InnerSpec.write(inner, writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            if (try BoolSpec.deserialize(alloc, reader)) {
                return try InnerSpec.deserialize(alloc, reader);
            }
            return null;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            if (self) |inner| {
                InnerSpec.deinit(inner, alloc);
            }
        }
        pub fn size(self: UserType) usize {
            if (self) |inner| {
                return 1 + InnerSpec.size(inner);
            }
            return 1;
        }
    };
}
