const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const ReadVarNumError = error{
    TooManyBytes,
};

pub fn bitCountRequiredFor(num: usize) u16 {
    const log = std.math.log2(@intToFloat(f64, num));
    const int_log = @floatToInt(u16, log);
    if (log > @intToFloat(f64, int_log)) {
        return int_log + 1;
    } else {
        return int_log;
    }
}

test "bit count required" {
    try std.testing.expectEqual(bitCountRequiredFor(64), 6);
    try std.testing.expectEqual(bitCountRequiredFor(32), 5);
}

pub fn readVarNum(comptime T: type, reader: anytype, read_length: ?*u16, first_byte: ?u8) !T {
    if (@typeInfo(T) != .Int) {
        @compileError("readVarNum expects an integer type");
    }
    const max_bytes = (@sizeOf(T) * 5) / 4;
    const ShiftType = std.meta.Int(.unsigned, comptime bitCountRequiredFor(@typeInfo(T).Int.bits));
    var value: T = 0;
    var len: u16 = 0;
    var read_byte: u8 = first_byte orelse try reader.readByte();
    while (true) {
        value |= @as(T, read_byte & 0b01111111) << @intCast(ShiftType, len * 7);
        len += 1;
        if (len > max_bytes) {
            return ReadVarNumError.TooManyBytes;
        }
        if ((read_byte & 0b10000000) != 0b10000000) {
            break;
        }
        read_byte = try reader.readByte();
    }
    if (read_length) |ptr| {
        ptr.* = len;
    }
    return value;
}

pub fn writeVarNum(comptime T: type, writer: anytype, value: T, wrote_length: ?*u16) !void {
    if (@typeInfo(T) != .Int) {
        @compileError("writeVarNum expects an integer type");
    }
    const UnsignedInt = std.meta.Int(.unsigned, @typeInfo(T).Int.bits);
    var remaining = @bitCast(UnsignedInt, value);
    var len: u16 = 0;
    while (true) {
        const next_data = @truncate(u8, remaining) & 0b01111111;
        remaining = remaining >> 7;
        try writer.writeByte(if (remaining > 0) next_data | 0b10000000 else next_data);
        len += 1;
        if (remaining == 0) {
            break;
        }
    }
    if (wrote_length) |ptr| {
        ptr.* = len;
    }
}

// tests modified from https://github.com/kvoli/zmcdata/blob/master/src/utils.zig
fn testReadHelper(comptime T: type, expected: T, varInt: []u8) !void {
    var buf = std.io.fixedBufferStream(varInt);
    const out: T = try readVarNum(T, buf.reader(), null, null);
    try std.testing.expectEqual(expected, out);
}
test "test readVarInt" {
    var test1 = [_]u8{0x00};
    var test2 = [_]u8{0x01};
    var test3 = [_]u8{0x02};
    var test4 = [_]u8{0x7f};
    var test5 = [_]u8{ 0x80, 0x01 };
    var test6 = [_]u8{ 0xff, 0x01 };
    var test7 = [_]u8{ 0xff, 0xff, 0x7f };
    var test8 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x07 };
    var test9 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };
    var test10 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x08 };

    try testReadHelper(i32, 0, &test1);
    try testReadHelper(i32, 1, &test2);
    try testReadHelper(i32, 2, &test3);
    try testReadHelper(i32, 127, &test4);
    try testReadHelper(i32, 128, &test5);
    try testReadHelper(i32, 255, &test6);
    try testReadHelper(i32, 2097151, &test7);
    try testReadHelper(i32, 2147483647, &test8);
    try testReadHelper(i32, -1, &test9);
    try testReadHelper(i32, -2147483648, &test10);
}
test "test readVarLong" {
    var test1 = [_]u8{0x00};
    var test2 = [_]u8{0x01};
    var test3 = [_]u8{0x02};
    var test4 = [_]u8{0x7f};
    var test5 = [_]u8{ 0x80, 0x01 };
    var test6 = [_]u8{ 0xff, 0x01 };
    var test7 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x07 };
    var test8 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    var test9 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    var test10 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01 };
    var test11 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };

    try testReadHelper(i64, 0, &test1);
    try testReadHelper(i64, 1, &test2);
    try testReadHelper(i64, 2, &test3);
    try testReadHelper(i64, 127, &test4);
    try testReadHelper(i64, 128, &test5);
    try testReadHelper(i64, 255, &test6);
    try testReadHelper(i64, 2147483647, &test7);
    try testReadHelper(i64, 9223372036854775807, &test8);
    try testReadHelper(i64, -1, &test9);
    try testReadHelper(i64, -2147483648, &test10);
    try testReadHelper(i64, -9223372036854775808, &test11);
}

fn testWriteHelper(comptime T: type, varInt: T, expected: []u8) !void {
    var array_list = std.ArrayList(u8).init(std.testing.allocator);
    defer array_list.deinit();
    var writer = array_list.writer();
    try writeVarNum(T, writer, varInt, null);
    const slice = array_list.toOwnedSlice();
    defer std.testing.allocator.free(slice);
    try std.testing.expectEqualSlices(u8, expected, slice);
}

test "test writeVarInt" {
    var test1 = [_]u8{0x00};
    var test2 = [_]u8{0x01};
    var test3 = [_]u8{0x02};
    var test4 = [_]u8{0x7f};
    var test5 = [_]u8{ 0x80, 0x01 };
    var test6 = [_]u8{ 0xff, 0x01 };
    var test7 = [_]u8{ 0xff, 0xff, 0x7f };
    var test8 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x07 };
    var test9 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };
    var test10 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x08 };

    try testWriteHelper(i32, 0, &test1);
    try testWriteHelper(i32, 1, &test2);
    try testWriteHelper(i32, 2, &test3);
    try testWriteHelper(i32, 127, &test4);
    try testWriteHelper(i32, 128, &test5);
    try testWriteHelper(i32, 255, &test6);
    try testWriteHelper(i32, 2097151, &test7);
    try testWriteHelper(i32, 2147483647, &test8);
    try testWriteHelper(i32, -1, &test9);
    try testWriteHelper(i32, -2147483648, &test10);
}

test "test writeVarLong" {
    var test1 = [_]u8{0x00};
    var test2 = [_]u8{0x01};
    var test3 = [_]u8{0x02};
    var test4 = [_]u8{0x7f};
    var test5 = [_]u8{ 0x80, 0x01 };
    var test6 = [_]u8{ 0xff, 0x01 };
    var test7 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x07 };
    var test8 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    var test9 = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    var test10 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01 };
    var test11 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };

    try testWriteHelper(i64, 0, &test1);
    try testWriteHelper(i64, 1, &test2);
    try testWriteHelper(i64, 2, &test3);
    try testWriteHelper(i64, 127, &test4);
    try testWriteHelper(i64, 128, &test5);
    try testWriteHelper(i64, 255, &test6);
    try testWriteHelper(i64, 2147483647, &test7);
    try testWriteHelper(i64, 9223372036854775807, &test8);
    try testWriteHelper(i64, -1, &test9);
    try testWriteHelper(i64, -2147483648, &test10);
    try testWriteHelper(i64, -9223372036854775808, &test11);
}

pub fn VarNum(comptime T: type) type {
    return struct {
        data: T,
        pub const IntType = T;

        const Self = @This();
        pub fn deserialize(alloc: Allocator, reader: anytype) !Self {
            _ = alloc;
            return Self{ .data = try readVarNum(T, reader, null, null) };
        }
        pub fn write(self: Self, writer: anytype) !void {
            try writeVarNum(T, writer, self.data, null);
        }
        pub fn deinit(self: Self, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
}

test "serde enum" {
    const TestEnum = enum(i32) {
        A = 0,
        B = 1,
        C = 2,
    };
    var stream = std.io.fixedBufferStream(&[_]u8{0});
    try std.testing.expect((try serde.SerdeEnum(VarInt, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .A);
    stream = std.io.fixedBufferStream(&[_]u8{1});
    try std.testing.expect((try serde.SerdeEnum(VarInt, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .B);
    stream = std.io.fixedBufferStream(&[_]u8{2});
    try std.testing.expect((try serde.SerdeEnum(VarInt, TestEnum).deserialize(std.testing.allocator, stream.reader())) == .C);
}

pub const VarInt = VarNum(i32);
pub const VarLong = VarNum(i64);

pub const PString = struct {
    data: []const u8,

    const Self = @This();
    pub fn deserialize(alloc: Allocator, reader: anytype) !Self {
        const len = try readVarNum(i32, reader, null, null);
        var text = try alloc.alloc(u8, @intCast(usize, len));
        // TODO: handle unicode
        try reader.readNoEof(text);
        return Self{ .data = text };
    }
    pub fn write(self: Self, writer: anytype) !void {
        try writeVarNum(i32, writer, @intCast(i32, self.data.len), null);
        for (self.data) |byte| {
            try writer.writeByte(byte);
        }
    }
    pub fn deinit(self: Self, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

//pub const DeserializePacketError = error{
//    InvalidId,
//};

pub const ServerboundHandshakingPacket = union(PacketIds) {
    pub const PacketIds = enum(i32) {
        Handshake = 0x00,
        LegacyHandshake = 0xFE,
    };
    Handshake: struct {
        protocol_version: VarInt,
        server_address: PString,
        server_port: u16,
        next_state: serde.SerdeEnum(VarInt, NextState),
    },
    LegacyHandshake: u8,

    pub const NextState = enum(u8) {
        Status = 0x01,
        Login = 0x02,
    };
};
pub const ClientboundStatusPacket = union(PacketIds) {
    pub const PacketIds = enum(i32) {
        Response = 0x00,
        Pong = 0x01,
    };
    Response: PString,
    Pong: i64,
};

pub const ServerboundStatusPacket = union(PacketIds) {
    pub const PacketIds = enum(i32) {
        Request = 0x00,
        Ping = 0x01,
    };
    Request: void,
    Ping: i64,
};
