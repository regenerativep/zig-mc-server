const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

pub const Command = union(enum) {
    list: void,
    say: struct {
        pub const kind = .remaining;
        text: []const u8,
    },
    teleport: struct {
        name: []const u8,
        x: f64,
        y: f64,
        z: f64,
    },

    pub fn parse(a: Allocator, text: []const u8) !?Command {
        return try readCommand(a, Command, text);
    }

    pub fn deinit(self: *Command, a: Allocator) void {
        deinitCommand(a, Command, self);
        self.* = undefined;
    }
};

// TODO: we're gonna need to store more error data than we can with an error union if
//     we want this experience to be nice
pub fn readCommand(
    a: Allocator,
    comptime Cmd: type,
    text_: []const u8,
) Allocator.Error!?Cmd {
    const text = mem.trim(u8, text_, &std.ascii.whitespace);
    switch (@typeInfo(Cmd)) {
        .Union => |info| {
            inline for (info.fields) |field| {
                if (mem.startsWith(u8, text, field.name) and // if starts with name
                    (text.len == field.name.len or // and then has whitespace or eol
                    for (&std.ascii.whitespace) |c|
                {
                    if (c == text[field.name.len])
                        break true;
                } else false)) {
                    return @unionInit(
                        Cmd,
                        field.name,
                        (try readCommand(a, field.type, text[field.name.len..])) orelse
                            return null,
                    );
                }
            }
            return null;
        },
        .Struct => |info| {
            if (@hasDecl(Cmd, "kind")) {
                if (Cmd.kind == .remaining) {
                    return .{ .text = try a.dupe(u8, text) };
                } else {
                    @compileError("unknown command kind");
                }
            } else {
                var result: Cmd = undefined;
                var i: usize = 0;
                inline for (info.fields) |field| {
                    i = mem.indexOfNonePos(u8, text, i, &std.ascii.whitespace) orelse
                        text.len;
                    const next_i =
                        mem.indexOfAnyPos(u8, text, i, &std.ascii.whitespace) orelse
                        text.len;
                    @field(result, field.name) =
                        try readCommand(a, field.type, text[i..next_i]) orelse
                        return null;
                    i = next_i;
                }
                return result;
            }
        },
        .Pointer => {
            if (Cmd == []const u8) {
                return try a.dupe(u8, text);
            }
        },
        .Float => {
            return std.fmt.parseFloat(Cmd, text) catch null;
        },
        .Int => {
            return std.fmt.parseInt(Cmd, text, 0) catch null;
        },
        .Void => return {},
        else => @compileError("unsupported command type " ++ @typeName(Cmd)),
    }
}

pub fn deinitCommand(a: Allocator, comptime Cmd: type, value: *Cmd) void {
    switch (@typeInfo(Cmd)) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                deinitCommand(a, field.type, &@field(value, field.name));
            }
        },
        .Pointer => |info| {
            if (info.size == .Slice) {
                var i = value.len;
                while (i > 0) {
                    i -= 1;
                    deinitCommand(a, info.child, @constCast(&value.*[i]));
                }
                a.free(value.*);
            }
        },
        .Union => {
            switch (value.*) {
                inline else => |*d| {
                    deinitCommand(a, @TypeOf(d.*), d);
                },
            }
        },
        .Void, .Float, .Int => {},
        else => unreachable,
    }
}

test "commands" {
    const a = testing.allocator;

    inline for ([_](struct { []const u8, ?Command }){
        .{ "list", .{ .list = {} } },
        .{ "say hi", .{ .say = .{ .text = "hi" } } },
        .{ "say hello world", .{ .say = .{ .text = "hello world" } } },
        .{ "asdf", null },
        .{ "teleport Regen 0 20 0", .{ .teleport = .{
            .name = "Regen",
            .x = 0,
            .y = 20,
            .z = 0,
        } } },
    }) |pair| {
        var read_cmd = try readCommand(a, Command, pair[0]);
        defer if (read_cmd) |*cmd| cmd.deinit(a);
        try testing.expectEqualDeep(pair[1], read_cmd);
    }
}
