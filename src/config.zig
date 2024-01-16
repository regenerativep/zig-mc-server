// yeah theres not much reason for this. i just wanted to make a config language
//
// ```
// ip = 127.0.0.1
// port = 25565
// ```

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

pub const TokenKind = enum {
    identifier,
    string_identifier,
    equals,
    obj_begin,
    obj_end,
    list_begin,
    list_end,
    pub fn isString(self: TokenKind) bool {
        return switch (self) {
            .identifier, .string_identifier => true,
            else => false,
        };
    }
};
pub const Token = struct {
    kind: TokenKind,
    text: []const u8 = "",

    pub fn getString(self: Token, a: Allocator) ![]const u8 {
        std.debug.assert(self.kind.isString());
        return if (self.kind == .string_identifier)
            try escapedToString(a, self.text)
        else
            try a.dupe(u8, self.text);
    }
};
pub const Tokenizer = struct {
    state: enum {
        identifier,
        string,
        string_escaped,
        string_escaped_b1,
        string_escaped_b2,
        slash,
        comment,
    } = .identifier,
    i: usize = 0,
    id_len: usize = 0,
    text: []const u8,
    queued: ?Token = null,

    pub fn next(self: *Tokenizer) ?Token {
        if (self.queued) |token| {
            self.queued = null;
            return token;
        }
        while (self.i < self.text.len) {
            defer self.i += 1;
            const c = self.text[self.i];
            switch (self.state) {
                .identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {
                        // identifier character
                        self.id_len += 1;
                    },
                    else => {
                        if (std.unicode.utf8ByteSequenceLength(c)) |len| {
                            if (len > 1) {
                                self.i += len - 1;
                                self.id_len += len;
                                continue;
                            }
                        } else |_| {}
                        const text = std.mem.trim(
                            u8,
                            self.text[self.i - self.id_len .. self.i],
                            &std.ascii.whitespace,
                        );
                        self.id_len = 0;
                        switch (c) {
                            '"' => self.state = .string,
                            '=' => self.queued = .{ .kind = .equals },
                            '{' => self.queued = .{ .kind = .obj_begin },
                            '}' => self.queued = .{ .kind = .obj_end },
                            '[' => self.queued = .{ .kind = .list_begin },
                            ']' => self.queued = .{ .kind = .list_end },
                            '/' => self.state = .slash,
                            else => {},
                        }
                        if (text.len == 0) {
                            if (self.queued) |token| {
                                self.queued = null;
                                return token;
                            } else {
                                continue;
                            }
                        }
                        return .{ .kind = .identifier, .text = text };
                    },
                },
                .string => switch (c) {
                    '"' => {
                        const text = self.text[self.i - self.id_len .. self.i];
                        self.state = .identifier;
                        self.id_len = 0;
                        return .{ .kind = .string_identifier, .text = text };
                    },
                    '\\' => {
                        self.state = .string_escaped;
                        self.id_len += 1;
                    },
                    else => {
                        if (std.unicode.utf8ByteSequenceLength(c)) |len| {
                            self.i += len - 1;
                            self.id_len += len;
                        } else |_| {
                            self.id_len += 1;
                        }
                    },
                },
                .string_escaped => {
                    if (c == 'x') {
                        self.state = .string_escaped_b1;
                    } else {
                        self.state = .string;
                    }
                    if (std.unicode.utf8ByteSequenceLength(c)) |len| {
                        self.i += len - 1;
                        self.id_len += len;
                    } else |_| {
                        self.id_len += 1;
                    }
                },
                .string_escaped_b1 => {
                    self.state = .string_escaped_b2;
                    self.id_len += 1;
                    if (std.unicode.utf8ByteSequenceLength(c)) |len| {
                        self.i += len - 1;
                        self.id_len += len;
                    } else |_| {
                        self.id_len += 1;
                    }
                },
                .string_escaped_b2 => {
                    self.state = .string;
                    self.id_len += 1;
                    if (std.unicode.utf8ByteSequenceLength(c)) |len| {
                        self.i += len - 1;
                        self.id_len += len;
                    } else |_| {
                        self.id_len += 1;
                    }
                },
                .slash => {
                    self.state = if (c == '/') .comment else .identifier;
                    self.id_len = 0;
                },
                .comment => if (c == '\n') {
                    self.state = .identifier;
                },
            }
        }
        return null;
    }
};

const test_text =
    \\hello = 5
    \\asdf = asdff
    \\// omg
    \\welcome = {
    \\    to = "\"hell\"!"
    \\}
    \\lemao = [ wow 5 ]
    \\北京 = "去过"
    \\fdkjfdkjdf = {
    \\    slkdlk = 5.5
    \\    jmskd = 20
    \\    asdkljasd = {}
    \\    dsjksd = [
    \\        {
    \\            fdhjkdfjkfd = kjdfkjdc
    \\            asdjhasd = [ 1 2 3 4 ]
    \\        }
    \\        {
    \\            asdf = fghj
    \\        }
    \\    ]
    \\}
    \\
;
test "tokenizer" {
    var tokenizer = Tokenizer{ .text = test_text };

    while (tokenizer.next()) |token| {
        _ = token;
        //std.debug.print("{s}, \"{s}\"\n", .{ @tagName(token.kind), token.text });
    }
}

pub fn PeekIterator(comptime T: type) type {
    return struct {
        pub const E =
            @typeInfo(@typeInfo(@TypeOf(@field(T, "next"))).return_type.?).child;

        inner: T,
        peeked: ?E = null,

        pub fn next(self: *@This()) ?E {
            return self.peeked orelse self.inner.next();
        }
        pub fn peek(self: *@This()) ?E {
            if (self.peeked == null) {
                self.peeked = self.inner.next();
            }
            return self.peeked;
        }
    };
}
pub fn peekIterator(iter: anytype) PeekIterator(@TypeOf(iter)) {
    return .{ .inner = iter };
}

pub const Ast = union(enum) {
    object: std.StringArrayHashMapUnmanaged(Ast),
    list: []Ast,
    string: []const u8,
    integer: i64,
    float: f64,

    pub fn deinit(self: *Ast, a: Allocator) void {
        switch (self.*) {
            .object => |*d| {
                for (d.keys()) |k| a.free(k);
                for (d.values()) |*v| v.deinit(a);
                d.deinit(a);
            },
            .list => |d| {
                var i = d.len;
                while (i > 0) {
                    i -= 1;
                    d[i].deinit(a);
                }
                a.free(d);
            },
            .string => |d| a.free(d),
            else => {},
        }
    }

    const PartialAst = union(enum) {
        object: struct {
            data: std.StringArrayHashMapUnmanaged(Ast) = .{},
            next_key: ?[]const u8 = null,
        },
        list: std.ArrayListUnmanaged(Ast),

        pub fn deinit(self: *PartialAst, a: Allocator) void {
            switch (self.*) {
                .object => |*d| {
                    if (d.next_key) |next_key| a.free(next_key);
                    for (d.data.keys()) |k| a.free(k);
                    for (d.data.values()) |*v| v.deinit(a);
                    d.data.deinit(a);
                },
                .list => |*d| {
                    var i = d.items.len;
                    while (i > 0) {
                        i -= 1;
                        d.items[i].deinit(a);
                    }
                    d.deinit(a);
                },
            }
            self.* = undefined;
        }

        pub fn toAst(self: *PartialAst, a: Allocator) !Ast {
            switch (self.*) {
                .object => |*d| {
                    if (d.next_key != null) return error.UnexpectedEof;
                    defer d.data = .{};
                    return .{ .object = d.data };
                },
                .list => |*d| return .{ .list = try d.toOwnedSlice(a) },
            }
        }
    };

    pub fn parse(
        a: Allocator,
        t: *Tokenizer,
    ) (AstParseError || Allocator.Error)!Ast {
        var stack = try std.ArrayListUnmanaged(PartialAst).initCapacity(a, 1);
        defer stack.deinit(a);
        errdefer {
            var i = stack.items.len;
            while (i > 0) {
                i -= 1;
                stack.items[i].deinit(a);
            }
        }
        stack.appendAssumeCapacity(.{ .object = .{} });
        while (true) {
            const top = &stack.items[stack.items.len - 1];
            var token = t.next() orelse {
                if (stack.items.len == 1) {
                    return try top.toAst(a);
                } else {
                    return error.UnexpectedEof;
                }
            };

            if ((top.* == .object and token.kind == .obj_end) or
                (top.* == .list and token.kind == .list_end))
            {
                if (stack.items.len == 1) return error.UnexpectedToken;
                const next_top = &stack.items[stack.items.len - 2];
                var node = try top.toAst(a);
                errdefer node.deinit(a);
                stack.items.len -= 1;

                switch (next_top.*) {
                    .object => |*d| {
                        try d.data.putNoClobber(a, d.next_key.?, node);
                        d.next_key = null;
                    },
                    .list => |*d| {
                        try d.append(a, node);
                    },
                }
            } else if (top.* == .object and top.object.next_key == null) {
                const key = try token.getString(a);
                errdefer a.free(key);
                if (top.object.data.contains(key)) return error.DuplicateKey;
                token = t.next() orelse return error.UnexpectedEof;
                if (token.kind != .equals) return error.UnexpectedToken;
                top.object.next_key = key;
            } else if (token.kind.isString()) {
                const str = try token.getString(a);

                var node: Ast = if (std.fmt.parseInt(i64, str, 0)) |num|
                    .{ .integer = num }
                else |_| if (std.fmt.parseFloat(f64, str)) |num|
                    .{ .float = num }
                else |_|
                    .{ .string = str };
                if (node == .integer or node == .float) a.free(str);
                errdefer node.deinit(a);

                switch (top.*) {
                    .object => |*d| {
                        // next_key is not null and is not present in hashmap
                        try d.data.putNoClobber(a, d.next_key.?, node);
                        d.next_key = null;
                    },
                    .list => |*d| {
                        try d.append(a, node);
                    },
                }
            } else if (token.kind == .obj_begin) {
                try stack.append(a, .{ .object = .{} });
            } else if (token.kind == .list_begin) {
                try stack.append(a, .{ .list = .{} });
            } else {
                return error.UnexpectedToken;
            }
        }
    }

    pub fn format(
        value: Ast,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = options;
        _ = fmt;
        switch (value) {
            .object => |d| {
                try writer.writeAll("{ ");
                for (d.keys(), d.values(), 0..) |key, v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print(".{s} = {}", .{ key, v });
                }
                try writer.writeAll(" }");
            },
            .list => |d| {
                try writer.writeAll("[ ");
                for (d, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{v});
                }
                try writer.writeAll(" ]");
            },
            .string => |d| {
                try writer.print("\"{s}\"", .{d});
            },
            inline .integer, .float => |d| {
                try writer.print("{d}", .{d});
            },
        }
    }
};

pub fn hexCharToInt(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c + 10 - 'a'),
        'A'...'F' => @intCast(c + 10 - 'A'),
        else => null,
    };
}

pub fn escapedToString(
    a: Allocator,
    text: []const u8,
) (Allocator.Error || error{InvalidEscapeSequence})![]const u8 {
    var str = try std.ArrayListUnmanaged(u8).initCapacity(a, text.len);
    defer str.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '\\' => if (i + 1 < text.len) {
            switch (text[i + 1]) {
                'x' => if (i + 3 < text.len) {
                    const b1 = hexCharToInt(text[i + 2]) orelse
                        return error.InvalidEscapeSequence;
                    const b2 = hexCharToInt(text[i + 3]) orelse
                        return error.InvalidEscapeSequence;
                    str.appendAssumeCapacity(@as(u8, b1) << 4 | b2);
                    i += 2;
                } else return error.InvalidEscapeSequence,
                'n' => str.appendAssumeCapacity('\n'),
                'r' => str.appendAssumeCapacity('\r'),
                't' => str.appendAssumeCapacity('\t'),
                else => |c| str.appendAssumeCapacity(c),
            }
            i += 1;
        } else return error.InvalidEscapeSequence,
        else => |c| str.appendAssumeCapacity(c),
    };
    return try str.toOwnedSlice(a);
}

pub const AstParseError = error{
    UnexpectedEof,
    ExpectedEquals,
    UnexpectedToken,
    InvalidEscapeSequence,
    DuplicateKey,
};

test "ast" {
    var tokenizer = Tokenizer{ .text = test_text };
    var ast = try Ast.parse(testing.allocator, &tokenizer);
    defer ast.deinit(testing.allocator);

    //std.debug.print("{any}\n", .{ast});
}
