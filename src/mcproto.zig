const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const unicode = std.unicode;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const serde = @import("serde.zig");

pub const ReadVarNumError = error{
    TooManyBytes,
};

// https://wiki.vg/Protocol#VarInt_and_VarLong
pub fn readVarNum(comptime T: type, reader: anytype, read_length: ?*u16) !T {
    if (@typeInfo(T) != .Int) {
        @compileError("readVarNum expects an integer type");
    }
    const max_bytes = (@sizeOf(T) * 5) / 4;
    var value: T = 0;
    var len: std.math.Log2Int(T) = 0;
    while (true) {
        const read_byte = try reader.readByte();
        value |= @as(T, read_byte & 0b01111111) << (len * 7);
        len += 1;
        if (len > max_bytes) {
            return ReadVarNumError.TooManyBytes;
        }
        if ((read_byte & 0b10000000) != 0b10000000) {
            break;
        }
    }
    if (read_length) |ptr| {
        ptr.* = @intCast(u16, len);
    }
    return value;
}

pub fn writeVarNum(comptime T: type, writer: anytype, value: T, write_length: ?*u16) !void {
    if (@typeInfo(T) != .Int) {
        @compileError("writeVarNum expects an integer type");
    }
    var remaining = @bitCast(meta.Int(.unsigned, @typeInfo(T).Int.bits), value);
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
    if (write_length) |ptr| {
        ptr.* = len;
    }
}

pub const VarNumTestCases = .{
    .{ .T = i32, .r = 0, .v = .{0x00} },
    .{ .T = i32, .r = 1, .v = .{0x01} },
    .{ .T = i32, .r = 2, .v = .{0x02} },
    .{ .T = i32, .r = 127, .v = .{0x7f} },
    .{ .T = i32, .r = 128, .v = .{ 0x80, 0x01 } },
    .{ .T = i32, .r = 255, .v = .{ 0xff, 0x01 } },
    .{ .T = i32, .r = 25565, .v = .{ 0xdd, 0xc7, 0x01 } },
    .{ .T = i32, .r = 2097151, .v = .{ 0xff, 0xff, 0x7f } },
    .{ .T = i32, .r = 2147483647, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x07 } },
    .{ .T = i32, .r = -1, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x0f } },
    .{ .T = i32, .r = -2147483648, .v = .{ 0x80, 0x80, 0x80, 0x80, 0x08 } },
    .{ .T = i64, .r = 2147483647, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x07 } },
    .{ .T = i64, .r = -1, .v = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 } },
    .{ .T = i64, .r = -2147483648, .v = .{ 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01 } },
    .{ .T = i64, .r = 9223372036854775807, .v = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
    .{ .T = i64, .r = -9223372036854775808, .v = .{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 } },
};

test "read var num" {
    inline for (VarNumTestCases) |pair| {
        const buf: [pair.v.len]u8 = pair.v;
        var reader = std.io.fixedBufferStream(&buf);
        try testing.expectEqual(@intCast(pair.T, pair.r), try readVarNum(pair.T, reader.reader(), null));
    }
}

test "write var num" {
    inline for (VarNumTestCases) |pair| {
        var wrote = std.ArrayList(u8).init(testing.allocator);
        defer wrote.deinit();
        try writeVarNum(pair.T, wrote.writer(), @intCast(pair.T, pair.r), null);
        const buf: [pair.v.len]u8 = pair.v;
        try testing.expect(std.mem.eql(u8, &buf, wrote.items));
    }
}

pub fn VarNum(comptime T: type) type {
    assert(@typeInfo(T) == .Int);
    return struct {
        pub const UserType = T;

        pub fn write(self: UserType, writer: anytype) !void {
            try writeVarNum(T, writer, self, null);
        }
        pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
            _ = alloc;
            return readVarNum(T, reader, null);
        }
        pub fn deinit(self: UserType, alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
        pub fn size(self: UserType) usize {
            var temp_val = self;
            var total_size: usize = 0;
            while (true) {
                total_size += 1;
                temp_val = temp_val >> 7;
                if (temp_val == 0) {
                    break;
                }
            }
            return total_size;
        }
    };
}

pub const VarInt = VarNum(i32);
pub const VarLong = VarNum(i64);

pub const PString = struct {
    pub const UserType = []const u8;
    pub fn write(self: UserType, writer: anytype) !void {
        try VarInt.write(@intCast(i32, self.len), writer);
        try writer.writeAll(self);
    }
    pub fn deserialize(alloc: Allocator, reader: anytype) !UserType {
        const len = try VarInt.deserialize(alloc, reader);
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

pub const H = struct {
    pub const SB = serde.TaggedUnionSpec(VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Handshake = 0x00,
            Legacy = 0xFE,
        };
        Handshake: struct {
            protocol_version: VarInt,
            server_address: PString,
            server_port: u16,
            next_state: serde.EnumSpec(VarInt, NextState),
        },
        Legacy: void,

        pub const NextState = enum(i32) {
            Status = 0x01,
            Login = 0x02,
        };
    });
};
pub const S = struct {
    pub const SB = serde.TaggedUnionSpec(VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Request = 0x00,
            Ping = 0x01,
        };
        Request: void,
        Ping: i64,
    });
    pub const CB = serde.TaggedUnionSpec(VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Response = 0x00,
            Pong = 0x01,
        };
        Response: PString,
        Pong: i64,
    });
};
pub const L = struct {
    pub const SB = serde.TaggedUnionSpec(VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            LoginStart = 0x00,
            EncryptionResponse = 0x01,
            LoginPluginResponse = 0x02,
        };
        LoginStart: PString,
        EncryptionResponse: struct {
            shared_secret: serde.LengthPrefixedArray(VarInt, u8),
            verify_token: serde.LengthPrefixedArray(VarInt, u8),
        },
        LoginPluginResponse: struct {
            message_id: VarInt,
            data: ?serde.Remaining,
        },
    });
    pub const CB = serde.TaggedUnionSpec(VarInt, union(PacketIds) {
        pub const PacketIds = enum(i32) {
            Disconnect = 0x00,
            EncryptionRequest = 0x01,
            LoginSuccess = 0x02,
            SetCompression = 0x03,
            LoginPluginRequest = 0x04,
        };
        Disconnect: PString,
        EncryptionRequest: struct {
            server_id: PString,
            public_key: serde.LengthPrefixedArray(VarInt, u8),
            verify_token: serde.LengthPrefixedArray(VarInt, u8),
        },
        LoginSuccess: struct {
            uuid: u128,
            username: PString,
        },
        SetCompression: VarInt,
        LoginPluginRequest: struct {
            message_id: VarInt,
            channel: PString,
            data: serde.Remaining,
        },
    });
};
