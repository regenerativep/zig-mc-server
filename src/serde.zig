const std = @import("std");
const Reader = std.io.Reader;
const meta = std.meta;
const Allocator = std.mem.Allocator;

pub fn Num(comptime T: type, comptime endianness: std.builtin.Endian) type {
    return struct {
        data: T,
        pub const IntType = T;

        const Self = @This();
        pub fn deserialize(alloc: Allocator, reader: anytype) !Self {
            _ = alloc;
            return Self{ .data = try reader.readInt(T, endianness) };
        }
        pub fn write(self: T, writer: anytype) !void {
            try writer.writeInt(T, self.data, endianness);
        }
        pub fn deinit(self: Self, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
}

pub fn SerdeIntType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .Int) {
        return T;
    } else if (@hasDecl(T, "IntType")) {
        return @field(T, "IntType");
    }
    @compileError(@typeName(T) ++ " does not have an integer type");
}
pub fn getSerdeInt(val: anytype) SerdeIntType(@TypeOf(val)) {
    if (@typeInfo(@TypeOf(val)) == .Int) {
        return val;
    } else if (@hasField(@TypeOf(val), "data")) {
        return @field(val, "data");
    }
}

pub fn SerdeEnum(comptime SerializableType: type, comptime EnumType: type) type {
    return struct {
        data: EnumType,

        const Self = @This();
        pub fn deserialize(alloc: Allocator, reader: anytype) !Self {
            const val = getSerdeInt(try SerdeType(SerializableType).deserialize(alloc, reader));
            return Self{ .data = @intToEnum(EnumType, @intCast(meta.Tag(EnumType), val)) };
        }
        pub fn write(self: Self, writer: anytype) !void {
            const val = @intCast(SerdeIntType(SerializableType), @enumToInt(self.data));
            try SerdeType(SerializableType).write(if (@typeInfo(SerializableType) == .Int) val else SerializableType{ .data = val }, writer);
        }
        pub fn deinit(self: Self, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
}

test "serde enum" {
    const TestEnum = enum(u8) {
        A = 0,
        B = 1,
        C = 2,
    };
    var stream = std.io.fixedBufferStream(&[_]u8{0});
    try std.testing.expect((try SerdeEnum(u8, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .A);
    stream = std.io.fixedBufferStream(&[_]u8{1});
    try std.testing.expect((try SerdeEnum(u8, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .B);
    stream = std.io.fixedBufferStream(&[_]u8{2});
    try std.testing.expect((try SerdeEnum(u8, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .C);
}

pub const DeserializeTaggedUnionError = error{
    InvalidTag,
};
pub fn SerdeTaggedUnion(comptime SerializableTagType: type, comptime UnionType: type) type {
    return struct {
        data: UnionType,

        const Self = @This();
        pub fn deserialize(alloc: Allocator, reader: anytype) !Self {
            const val = getSerdeInt(try SerdeType(SerializableTagType).deserialize(alloc, reader));
            const tag_int = @intCast(meta.Tag(meta.Tag(UnionType)), val);
            inline for (meta.fields(UnionType)) |_field, _i| {
                const i = _i;
                const field = _field;
                const enum_field = meta.fieldInfo(meta.Tag(UnionType), @intToEnum(meta.FieldEnum(meta.Tag(UnionType)), i));
                if (enum_field.value == tag_int) {
                    const serde_type = SerdeType(field.field_type);
                    const de_val_result = serde_type.deserialize(alloc, reader);
                    if (meta.isError(de_val_result)) { // hack. compiler bug: https://github.com/ziglang/zig/issues/10087
                        _ = de_val_result catch |err| return err;
                    }
                    const de_val = de_val_result catch unreachable;
                    const data = @unionInit(UnionType, field.name, de_val);
                    return Self{ .data = data };
                }
            }
            return DeserializeTaggedUnionError.InvalidTag;
        }
        pub fn write(self: Self, writer: anytype) !void {
            const tag_int = @enumToInt(self.data);
            const target_casted_tag = @intCast(SerdeIntType(SerializableTagType), tag_int);
            try SerdeType(SerializableTagType).write(if (@typeInfo(SerializableTagType) == .Int) target_casted_tag else SerializableTagType{ .data = target_casted_tag }, writer);
            inline for (meta.fields(UnionType)) |field| {
                if (@enumToInt(comptime meta.stringToEnum(meta.Tag(UnionType), field.name).?) == tag_int) {
                    const serde_type = SerdeType(field.field_type);
                    try serde_type.write(@field(self.data, field.name), writer);
                    return;
                }
            }
        }
        pub fn deinit(self: Self, alloc: Allocator) void {
            const tag_int = @enumToInt(self.data);
            inline for (meta.fields(UnionType)) |field| {
                if (@enumToInt(comptime meta.stringToEnum(meta.Tag(UnionType), field.name).?) == tag_int) {
                    const serde_type = SerdeType(field.field_type);
                    serde_type.deinit(@field(self.data, field.name), alloc);
                    return;
                }
            }
        }
    };
}

test "serde tagged union" {
    const TestEnum = enum(u8) {
        A = 0,
        B = 1,
        C = 2,
    };
    const TestUnion = union(TestEnum) {
        A: u8,
        B: u16,
        C: void,
    };
    inline for (.{
        .{ .buf = [_]u8{ 0, 5 }, .desired = TestUnion{ .A = 5 } },
        .{ .buf = [_]u8{ 1, 1, 0 }, .desired = TestUnion{ .B = 256 } },
        .{ .buf = [_]u8{2}, .desired = TestUnion.C },
    }) |pair| {
        var stream = std.io.fixedBufferStream(&pair.buf);
        const result = try SerdeTaggedUnion(u8, TestUnion).deserialize(std.testing.allocator, stream.reader());
        try std.testing.expect(meta.eql(result, pair.desired));
    }
}

pub fn SerdeNum(comptime T: type) type {
    return struct {
        pub fn deserialize(alloc: Allocator, reader: anytype) !T {
            _ = alloc;
            return try reader.readInt(T, .Big);
        }
        pub fn write(self: T, writer: anytype) !void {
            try writer.writeInt(T, self, .Big);
        }
        pub fn deinit(self: T, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
}

pub fn SerdeType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .Void) {
        return struct {
            pub fn deserialize(alloc: Allocator, reader: anytype) !void {
                _ = alloc;
                _ = reader;
            }
            pub fn write(self: T, writer: anytype) !void {
                _ = self;
                _ = writer;
            }
            pub fn deinit(self: T, alloc: Allocator) void {
                _ = self;
                _ = alloc;
            }
        };
    }
    if (info == .Int) {
        return SerdeNum(T);
    }
    if (info == .Bool) {
        return SerdeEnum(u8, enum(u8) {
            False = 0x00,
            True = 0x01,
            pub fn to_bool(self: @This()) bool {
                switch (self) {
                    .False => return false,
                    .True => return true,
                }
            }
        });
    }
    if (@hasDecl(T, "deserialize") and @hasDecl(T, "deinit") and @hasDecl(T, "write")) {
        return T;
    }
    if (info == .Struct) {
        return struct {
            pub fn deserialize(alloc: Allocator, reader: anytype) !T {
                var packet: T = undefined;
                inline for (meta.fields(T)) |field| {
                    @field(packet, field.name) = try SerdeType(field.field_type).deserialize(alloc, reader);
                }
                return packet;
            }
            pub fn write(self: T, writer: anytype) !void {
                inline for (meta.fields(T)) |field| {
                    try SerdeType(field.field_type).write(@field(self, field.name), writer);
                }
            }
            pub fn deinit(self: T, alloc: Allocator) void {
                inline for (meta.fields(T)) |field| {
                    SerdeType(field.field_type).deinit(@field(self, field.name), alloc);
                }
            }
        };
    }
    @compileError("Don't know how to serde " ++ @typeName(T));
}
