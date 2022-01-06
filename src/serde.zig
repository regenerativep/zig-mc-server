const std = @import("std");
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub fn NumSpec(comptime T: type, endian: std.builtin.Endian) type {
    if (@typeInfo(T) != .Int) {
        @compileError("expected an int");
    }
    return struct {
        pub const UserType = T;
        pub fn write(self: UserType, writer: anytype) !void {
            try writer.writeInt(T, self, endian);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            _ = alloc;
            return reader.readInt(T, endian);
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

pub fn StructSpec(comptime PartialSpec: type, comptime UserType: type) type {
    const info = @typeInfo(PartialSpec);
    const userInfo = @typeInfo(UserType);
    var specs: [info.Struct.fields.len]type = undefined;
    inline for (info.Struct.fields) |field, i| {
        const user_field = userInfo.Struct.fields[i];
        comptime assert(std.mem.eql(u8, field.name, user_field.name));
        const SpecType = FullSpec(field.field_type, user_field.field_type);
        specs[i] = SpecType;
    }
    const spec_list = specs;
    return struct {
        pub const UserType = UserType;
        pub const Specs = spec_list;
        pub fn write(self: UserType, writer: anytype) !void {
            inline for (info.Struct.fields) |field, i| {
                try Specs[i].write(@field(self, field.name), writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            var data: UserType = undefined;
            inline for (info.Struct.fields) |field, i| {
                @field(data, field.name) = try Specs[i].deserialize(alloc, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            inline for (info.Struct.fields) |field, i| {
                Specs[i].deinit(@field(self, field.name), alloc);
            }
        }
        pub fn size(self: UserType) usize {
            var total_size: usize = 0;
            inline for (info.Struct.fields) |field, i| {
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

pub fn EnumSpec(comptime TagType: type, comptime UserType: type) type {
    const TagSpec = FullSpec(TagType, meta.Tag(UserType));
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

pub fn TaggedUnionSpec(comptime TagType: type, comptime PartialUnionSpec: type) type {
    const UserType = FullUser(PartialUnionSpec);
    //const UnionSpec = FullSpec(PartialUnionSpec, UserType);
    const TagSpec = FullSpec(TagType, meta.Tag(meta.Tag(UserType)));
    assert(@typeInfo(TagSpec.UserType) == .Int);
    assert(@typeInfo(PartialUnionSpec) == .Union); // UnionSpec.UserType should be same as UserType
    assert(@typeInfo(UserType) == .Union);
    const info = @typeInfo(PartialUnionSpec);
    const userInfo = @typeInfo(UserType);
    var specs: [info.Union.fields.len]type = undefined;
    inline for (info.Union.fields) |field, i| {
        const user_field = userInfo.Union.fields[i];
        comptime assert(std.mem.eql(u8, field.name, user_field.name));
        specs[i] = FullSpec(field.field_type, user_field.field_type);
    }
    const spec_list = specs;
    return struct {
        pub const UserType = UserType;
        pub const Specs = spec_list;
        pub fn getInt(self: UserType) TagSpec.UserType {
            return @intCast(TagSpec.UserType, @enumToInt(self));
        }
        pub fn write(self: UserType, writer: anytype) !void {
            const tag_int = getInt(self);
            try TagSpec.write(tag_int, writer);
            inline for (meta.fields(UserType)) |field, i| {
                const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                if (enum_field.value == tag_int) {
                    const res = Specs[i].write(@field(self, field.name), writer);
                    if (meta.isError(res)) res catch |err| return err;
                    return;
                }
            }
            return error.InvalidTag;
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const tag_int = try TagSpec.deserialize(alloc, reader);
            inline for (meta.fields(UserType)) |field, i| {
                const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
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
                const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
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
                const enum_field = meta.fieldInfo(meta.Tag(UserType), @intToEnum(meta.FieldEnum(meta.Tag(UserType)), i));
                if (enum_field.value == tag_int) {
                    return TagSpec.size(tag_int) + Specs[i].size(@field(self, field.name));
                }
            }
            return 0;
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
    const SerdeUnion = TaggedUnionSpec(u8, TestUnion);
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

pub fn FullSpec(comptime PartialSpec: type, comptime UserType: type) type {
    if (isSerializable(PartialSpec)) {
        // PartialSpec.UserType should be the same as UserType
        return PartialSpec;
    }
    switch (@typeInfo(PartialSpec)) {
        .Void => return VoidSpec,
        .Bool => return BoolSpec,
        .Int => return NumSpec(UserType, .Big), // UserType should be the same type as PartialSpec
        .Struct => return StructSpec(PartialSpec, UserType),
        .Optional => return OptionalSpec(PartialSpec, UserType),
        else => @compileError("dont know how to do full spec for " ++ @typeName(PartialSpec) ++ " and " ++ @typeName(UserType)),
    }
}

pub fn isSerializable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .Struct or info == .Union or info == .Enum) {
        inline for (.{ "write", "deserialize", "size", "UserType" }) |name| {
            if (!@hasDecl(T, name)) {
                return false;
            }
        }
        return true;
    }
    return false;
}

pub fn FullUser(comptime T: type) type {
    if (isSerializable(T)) {
        return T.UserType;
    }
    switch (@typeInfo(T)) {
        .Int, .Float, .Enum, .Bool, .Void => return T,
        .Struct => |info| {
            var fields: [info.fields.len]std.builtin.TypeInfo.StructField = undefined;
            inline for (info.fields) |*field, i| {
                var f = field.*;
                f.field_type = FullUser(field.field_type);
                f.default_value = null;
                fields[i] = f;
            }
            return @Type(std.builtin.TypeInfo{ .Struct = .{
                .layout = info.layout,
                .fields = &fields,
                .decls = &[_]std.builtin.TypeInfo.Declaration{},
                .is_tuple = info.is_tuple,
            } });
        },
        .Union => |info| {
            var fields: [info.fields.len]std.builtin.TypeInfo.UnionField = undefined;
            inline for (info.fields) |*field, i| {
                var f = field.*;
                f.field_type = FullUser(field.field_type);
                fields[i] = f;
            }
            return @Type(std.builtin.TypeInfo{ .Union = .{
                .layout = info.layout,
                .tag_type = info.tag_type,
                .fields = &fields,
                .decls = &[_]std.builtin.TypeInfo.Declaration{},
            } });
        },
        .Optional => |info| return @Type(std.builtin.TypeInfo{ .Optional = .{ .child = FullUser(info.child) } }),
        else => @compileError("dont know how to generate user type for " ++ @typeName(T)),
    }
}

test "serder" {
    const EnumType = enum(u8) { A = 0x00, B = 0x01, C = 0x02 };
    const PartialSpecType = struct {
        a: i32,
        b: struct {
            c: bool,
            d: u8,
            e: NumSpec(u16, .Little),
        },
        c: EnumSpec(u8, EnumType),
    };
    const UserType = FullUser(PartialSpecType);
    const SpecType = FullSpec(PartialSpecType, UserType);

    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02 };
    var reader = std.io.fixedBufferStream(&buf);
    const result: UserType = try SpecType.deserialize(testing.allocator, &reader.reader());
    try testing.expectEqual(result.a, 258);
    try testing.expectEqual(result.b.c, true);
    try testing.expectEqual(result.b.d, 0x08);
    try testing.expectEqual(result.b.e, 0x10);
    try testing.expectEqual(EnumType.C, result.c);
}

pub const Remaining = struct {
    pub const UserType = []const u8;
    pub fn write(self: UserType, writer: anytype) !void {
        try writer.writeAll(self);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        var data = std.ArrayList(u8).init(alloc);
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

pub fn LengthPrefixedArray(comptime PartialLengthSpec: type, comptime PartialSpec: type) type {
    const LengthSpec = FullSpec(PartialLengthSpec, void);
    const UserElementType = FullUser(PartialSpec);
    const SpecType = FullSpec(PartialSpec, UserElementType);
    return struct {
        pub const UserType = []const UserElementType;
        pub fn write(self: UserType, writer: anytype) !void {
            try LengthSpec.write(@intCast(LengthSpec.UserType, self.len), writer);
            for (self) |elem| {
                try SpecType.write(elem, writer);
            }
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            const len = @intCast(usize, try LengthSpec.deserialize(alloc, reader));
            var data = try alloc.alloc(UserElementType, len);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                data[i] = try SpecType.deserialize(alloc, reader);
            }
            return data;
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
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

pub fn OptionalSpec(comptime PartialSpec: type, comptime UserType: type) type {
    const InnerUserType = @typeInfo(UserType).Optional.child;
    const InnerSpec = FullSpec(@typeInfo(PartialSpec).Optional.child, InnerUserType);
    return struct {
        pub const UserType = UserType;
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
