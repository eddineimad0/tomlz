const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const io = std.io;
const debug = std.debug;
const log = std.log;

const lex = @import("lexer.zig");
const cnst = @import("constants.zig");
const common = @import("common.zig");
const types = @import("types.zig");

const StringHashmap = std.StringHashMap;

fn skipUTF8BOM(in: *io.StreamSource) void {
    // INFO:
    // The UTF-8 BOM is a sequence of bytes at the start of a text stream
    // (0xEF, 0xBB, 0xBF) that allows the reader to more reliably guess
    // a file as being encoded in UTF-8.
    // [src:https://stackoverflow.com/questions/2223882/whats-the-difference-between-utf-8-and-utf-8-with-bom]

    const r = in.reader();
    const header = r.readIntLittle(u24) catch {
        return;
    };

    if (header != cnst.UTF8BOMLE) {
        in.seekTo(0) catch unreachable;
    }
}

fn skipUTF16BOM(in: *io.StreamSource) void {
    // INFO:
    // In UTF-16, a BOM (U+FEFF) may be placed as the first bytes
    // of a file or character stream to indicate the endianness (byte order)

    const r = in.reader();
    const header = r.readIntLittle(u16) catch {
        return;
    };

    if (header != cnst.UTF16BOMLE) {
        in.seekTo(0) catch unreachable;
    }
}

pub const Parser = struct {
    lexer: lex.Lexer,
    toml_src: *io.StreamSource,
    table_path: common.DynArray(types.Key, null),
    allocator: mem.Allocator,
    implicit_tables: StringHashmap(void),
    root_table: types.TomlTable,
    current_table: *types.TomlTable,
    current_key: types.Key,

    const Self = @This();

    const Error = error{
        LexerError,
        DuplicateKey,
        InvalidInteger,
        InvalidFloat,
        BadValue,
    };

    /// initialize a toml parser, the toml_input pointer should remain valid
    /// until the parser is deinitialized.
    /// call deinit() when done to release memory resources.
    pub fn init(allocator: mem.Allocator, toml_input: *io.StreamSource) mem.Allocator.Error!Self {
        var map = StringHashmap(bool).init(allocator);
        map.ensureTotalCapacity(16);
        return .{
            .lexer = try lex.Lexer.init(allocator, toml_input),
            .table_path = try common.DynArray(types.Key, null).initCapacity(allocator, 16),
            .toml_src = toml_input,
            .implicit_tables = map,
            .allocator = allocator,
            .root_table = try types.TomlTable.init(allocator),
            .current_key = "",
            .current_table = undefined,
        };
    }

    /// Frees memory resources used by the parser.
    /// you shouldn't attempt to use the parser after calling this function
    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
        // TODO: free content.
        self.table_path.deinit();
        self.implicit_tables.deinit();
    }

    pub fn parse(self: *Self) (mem.Allocator.Error | Parser.Error)!void {
        skipUTF16BOM(self.toml_src);
        skipUTF8BOM(self.toml_src);

        self.current_table = &self.root_table;

        var token: lex.Token = undefined;

        while (true) {
            self.lexer.nextToken(&token);
            switch (token.type) {
                .EOF => break,
                .Error => {
                    log.err("Error: [line:{d},col:{d}], {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                    return Error.LexerError;
                },
                .TableStart => {},
                .TableEnd => {},
                .Key => {
                    const key = try self.allocator.alloc(u8, token.value.?.len);
                    @memcpy(key, token.value.?);
                    self.current_table = key;
                },
                .Integer,
                .Boolean,
                .Float,
                .BasicString,
                .MultiLineBasicString,
                .MultiLineLiteralString,
                .DateTime,
                => {
                    var value: types.TomlValue = undefined;
                    try self.parseValue(self.allocator, &token, &value);
                    self.putValue(&value);
                },
                .Dot => {
                    try self.pushImplicitTable(self.current_key);
                },
                .Comment => {},
                else => {
                    log.err("Parser: Unexpected token found, `{}`\n", .{token.type});
                },
            }
        }
    }

    fn pushImplicitTable(self: *Self, key: common.Key) mem.Allocator.Error!void {
        try self.implicit_tables.put(
            key,
            void,
        );
        try self.table_path.append(key);
    }

    fn parseValue(allocator: mem.Allocator, t: *const lex.Token, v: *types.TomlValue) (mem.Allocator.Error | Parser.Error)!void {
        switch (t.type) {
            .Integer => {
                const integer = fmt.parseInt(isize, t.value.?, 0) catch |e| {
                    log.err("Parser: couldn't convert to integer, input={s}, error={}\n", .{ t.value.?, e });
                    return Error.InvalidInteger;
                };
                v.* = types.TomlValue{ .Integer = integer };
            },
            .Boolean => {
                const boolean = if (mem.eql(u8, t.value.?, "true")) true else false;
                v.* = types.TomlValue{ .Boolean = boolean };
            },
            .Float => {
                const float = fmt.parseFloat(f64, t.value.?) catch |e| {
                    log.err("Parser: couldn't convert to float, input={s}, error={}\n", .{ t.value.?, e });
                    return Error.InvalidFloat;
                };
                v.* = types.TomlValue{ .Float = float };
            },
            .BasicString => {},
            .MultiLineBasicString => {},
            .LiteralString => {
                // we don't own the slice in token.value so copy it.
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = types.TomlValue{ .String = string };
            },
            .MultiLineLiteralString => {
                const string = try allocator.alloc(u8, t.value.?.len);
                const slice = stripInitialNewline(t.value.?);
                @memcpy(string, slice);
                v.* = types.TomlValue{ .String = string };
            },
            else => {
                log.err("Parser: Unkown value type `{}`\n", .{t.type});
                return Error.BadValue;
            },
        }
    }

    fn putValue(self: *Self, value: *types.TomlValue) (mem.Allocator.Error | Parser.Error)!void {
        const key = self.current_key;
        const dest_table = self.current_table;
        if (self.current_table.getOrNull(key)) |*v| {
            // possibly a duplicate key
            if (self.implicit_tables.contains(key)) {
                // make it explicit
                _ = self.implicit_tables.remove(key);
                dest_table = &v.Table;
            } else {
                log.err("Parser: Redefinition of key={s}", .{key});
                return Error.DuplicateKey;
            }
        }
        try self.dest_table.put(key, value);
    }

    fn stripInitialNewline(slice: []const u8) []const u8 {
        var start_index: usize = 0;
        if (slice.len > 0 and slice[0] == '\n') {
            start_index = 1;
        } else if (slice.len > 1 and slice[0] == '\r' and slice[1] == '\n') {
            start_index = 2;
        }
        return slice[start_index..];
    }

    fn stripEscapedNewlines(allocator: mem.Allocator, slice: []const u8) mem.Allocator.Error![]const u8 {
        // TODO:
        var str = try common.String8.initCapacity(allocator, slice.len);
        var wr = str.writer();
        const index = mem.indexOf(u8, slice, &[_]u8{'\\'});
        if (index) |i| {
            _ = i;
        } else {
            // no escaped newlines
            // slice is guranteed to fit
            wr.write(slice) catch unreachable;
            return str.toOwnedSlice();
        }
    }

    fn parseDebug(self: *Self) !void {
        skipUTF16BOM(self.toml_src);
        skipUTF8BOM(self.toml_src);

        var token: lex.Token = undefined;

        while (true) {
            self.lexer.nextToken(&token);
            switch (token.type) {
                .Error => {
                    debug.print("[{d},{d}]Tok:Error, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                    return error.LexerError;
                },
                .EOF => {
                    debug.print("[{d},{d}]Tok:EOF\n", .{ token.start.line, token.start.offset });
                    break;
                },
                .Key => {
                    debug.print("[{d},{d}]Tok:Key, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Dot => {
                    debug.print("[{d},{d}]Tok:Dot,\n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .BasicString => {
                    debug.print("[{d},{d}]Tok:BasicString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .LiteralString => {
                    debug.print("[{d},{d}]Tok:LiteralString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .MultiLineBasicString => {
                    debug.print("[{d},{d}]Tok:MLBasicString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .MultiLineLiteralString => {
                    debug.print("[{d},{d}]Tok:MLLiteralString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Integer => {
                    debug.print("[{d},{d}]Tok:Integer, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Float => {
                    debug.print("[{d},{d}]Tok:Float, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Boolean => {
                    debug.print("[{d},{d}]Tok:Boolean, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .DateTime => {
                    debug.print("[{d},{d}]Tok:DateTime, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .InlineTableStart => {
                    debug.print("[{d},{d}]Tok:InlineTableStart, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .InlineTableEnd => {
                    debug.print("[{d},{d}]Tok:InlineTableEnd, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .ArrayStart => {
                    debug.print("[{d},{d}]Tok:ArrayStart, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .ArrayEnd => {
                    debug.print("[{d},{d}]Tok:ArrayEnd, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .TableStart => {
                    debug.print("[{d},{d}]Tok:TableStart, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .TableEnd => {
                    debug.print("[{d},{d}]Tok:TableEnd , \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .ArrayTableStart => {
                    debug.print("[{d},{d}]Tok:ArrayTableStart, \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
                .ArrayTableEnd => {
                    debug.print("[{d},{d}]Tok:ArrayTableEnd , \n", .{
                        token.start.line,
                        token.start.offset,
                    });
                },
            }
        }
    }
};

test "lex string" {
    const testing = std.testing;
    const src =
        \\# This is a comment
        \\my_string = 'Hello world!'
        \\my_string2 = "Hello w\x31rld!"
        \\my_string3 = "Hello w\u3100rld!"
        \\my_string4 = """Hello w\U41520000rld!"""
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex integer" {
    const testing = std.testing;
    const src =
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
        \\int7 = 53_49_221  # Indian number system grouping
        \\int8 = 1_2_3_4_5  # VALID but discouraged
        \\# hexadecimal with prefix `0x`
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\hex3 = 0xdead_beef
        \\# octal with prefix `0o`
        \\oct1 = 0o01234567
        \\oct2 = 0o755 # useful for Unix file permissions
        \\# binary with prefix `0b`
        \\bin1 = 0b11010110
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex float" {
    const testing = std.testing;
    const src =
        \\# fractional
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\# exponent
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\# both
        \\flt7 = 6.626e-34
        \\# infinity
        \\sf1 = inf  # positive infinity
        \\sf2 = +inf # positive infinity
        \\sf3 = -inf # negative infinity
        \\# not a number
        \\sf4 = nan  # actual sNaN/qNaN encoding is implementation-specific
        \\sf5 = +nan # same as `nan`
        \\sf6 = -nan # valid, actual encoding is implementation-specific
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex bool" {
    const testing = std.testing;
    const src =
        \\bool1 = true
        \\bool2 = false
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex datetime" {
    const testing = std.testing;
    const src =
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex array" {
    const testing = std.testing;
    const src =
        \\integers = [ 1, 2, 3 ]
        \\colors = [ "red", "yellow", "green" ]
        \\nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
        \\nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
        \\string_array = [ "all", 'strings', """are the same""", '''type''' ]
        \\
        \\# Mixed-type arrays are allowed
        \\numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
        \\contributors = [
        \\  "Foo Bar <foo@example.com>",
        \\  { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }
        \\]
        \\
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex inline table" {
    const testing = std.testing;
    const src =
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = { x = 1, y = 2 }
        \\animal = { type.name = "pug" }
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex table" {
    const testing = std.testing;
    const src =
        \\[table-1]
        \\key1 = "some string"
        \\key2 = 123
        \\
        \\[table-2]
        \\key1 = "another string"
        \\key2 = 456
        \\[dog."tater.man"]
        \\type.name = "pug"
        \\[a.b.c]            # this is best practice
        \\[ d.e.f ]          # same as [d.e.f]
        \\[ g .  h  . i ]    # same as [g.h.i]
        \\[ j . "ʞ" . 'l' ]  # same as [j."ʞ".'l']
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}

test "lex array of tables" {
    const testing = std.testing;
    const src =
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]  # subtable
        \\color = "red"
        \\shape = "round"
        \\
        \\[[fruits.varieties]]  # nested array of tables
        \\name = "red delicious"
        \\
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
        \\[[fruits.varieties]]
        \\name = "plantain"
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}
