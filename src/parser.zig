const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const heap = std.heap;
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
    table_context: common.DynArray(types.Key, null), // used to keep track of table nestting.
    key_path: common.DynArray(types.Key, null), // used to keep track of key parts e.g. "a.b.c",
    allocator: mem.Allocator,
    arena: heap.ArenaAllocator,
    implicit_map: StringHashmap(void),
    root_table: types.TomlTable,
    current_table: *types.TomlTable,
    current_key: types.Key,
    array: common.DynArray(types.TomlValue, null),
    in_array: bool,

    const Self = @This();

    const Error = error{
        LexerError,
        DuplicateKey,
        InvalidInteger,
        InvalidFloat,
        InvalidStringEscape,
        BadValue,
    };

    /// initialize a toml parser, the toml_input pointer should remain valid
    /// until the parser is deinitialized.
    /// call deinit() when done to release memory resources.
    pub fn init(allocator: mem.Allocator, toml_input: *io.StreamSource) mem.Allocator.Error!Self {
        var lexer = try lex.Lexer.init(allocator, toml_input);
        errdefer lexer.deinit();
        var map = StringHashmap(void).init(allocator);
        var root = types.TomlTable.init(allocator);
        try map.ensureTotalCapacity(16);
        errdefer map.deinit();
        try root.ensureTotalCapacity(32);
        errdefer root.deinit();
        var table_context = try common.DynArray(types.Key, null).initCapacity(allocator, 16);
        errdefer table_context.deinit();
        var key_path = try common.DynArray(types.Key, null).initCapacity(allocator, 16);
        errdefer key_path.deinit();
        var arena = heap.ArenaAllocator.init(allocator);
        return .{
            .lexer = lexer,
            .table_context = table_context,
            .key_path = key_path,
            .implicit_map = map,
            .arena = arena,
            .root_table = root,
            .toml_src = toml_input,
            .allocator = allocator,
            .current_key = "",
            .current_table = undefined,
            .array = try common.DynArray(types.TomlValue, null).initCapacity(allocator, 32),
            .in_array = false,
        };
    }

    /// Frees memory resources used by the parser.
    /// you shouldn't attempt to use the parser after calling this function
    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
        self.key_path.deinit();
        self.table_context.deinit();
        self.implicit_map.deinit();
        self.root_table.deinit();
        self.array.deinit();
        self.arena.deinit();
        self.current_table = undefined;
        self.current_key = undefined;
    }

    pub fn parse(self: *Self) (mem.Allocator.Error || Parser.Error)!*const types.TomlTable {
        skipUTF16BOM(self.toml_src);
        skipUTF8BOM(self.toml_src);

        self.current_table = &self.root_table;

        var token: lex.Token = undefined;

        while (true) {
            self.lexer.nextToken(&token);
            switch (token.type) {
                .EOS => break,
                .Error => {
                    log.err("[line:{d},col:{d}], {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                    return Error.LexerError;
                },
                .TableStart => {
                    _ = self.table_context.popOrNull();
                    self.current_table = self.walkTableContext();
                },
                .TableEnd => {
                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(32);
                    const value = types.TomlValue{ .Table = new_table };
                    try self.table_context.append(self.current_key);
                    const value_ptr = try self.putValue(&value);
                    self.current_table = &value_ptr.Table;
                },
                .ArrayStart => {
                    try self.array.resize(32);
                    self.in_array = true;
                    // const new_table = types.TomlValue{ .Table = try types.TomlTable.init(self.allocator) };
                    // self.putValue(&new_table);
                },
                .ArrayEnd => {
                    self.in_array = false;
                    const final_slice = try self.array.toOwnedSlice();
                    _ = try self.putValue(&types.TomlValue{ .Array = final_slice });
                    self.array.clearContent();
                },
                .InlineTableStart => {
                    if (self.implicit_map.contains(self.current_key)) {
                        log.err("Parser: predefined table '{s}' can't be redefined to inline table", .{self.current_key});
                        return Error.DuplicateKey;
                    }
                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(32);
                    const value = types.TomlValue{ .Table = new_table };
                    try self.table_context.append(self.current_key);
                    const value_ptr = try self.putValue(&value);
                    self.current_table = &value_ptr.Table;
                },
                .InlineTableEnd => {
                    _ = self.table_context.popOrNull();
                    self.current_table = self.walkTableContext();
                },
                .Key => {
                    // We don't own the memory pointed to by token.value.
                    const key = try self.arena.allocator().alloc(u8, token.value.?.len);
                    @memcpy(key, token.value.?);
                    self.current_key = key;
                },
                .Integer,
                .Boolean,
                .Float,
                .BasicString,
                .LiteralString,
                .MultiLineBasicString,
                .MultiLineLiteralString,
                .DateTime,
                => {
                    var value: types.TomlValue = undefined;
                    try parseValue(self.arena.allocator(), &token, &value);
                    if (self.in_array) {
                        try self.array.append(value);
                    } else {
                        _ = try self.putValue(&value);
                    }
                },
                .Dot => {
                    try self.pushImplicitTable(self.current_key);
                },
                .Comment => {},
                else => {
                    log.err("Parser: unexpected token found, `{}`\n", .{token.type});
                },
            }
        }
        return &self.root_table;
    }

    fn pushImplicitTable(self: *Self, key: types.Key) mem.Allocator.Error!void {
        // try self.implicit_map.put(
        //     key,
        //     {},
        // );
        try self.key_path.append(key);
    }

    fn parseValue(
        allocator: mem.Allocator,
        t: *const lex.Token,
        v: *types.TomlValue,
    ) (mem.Allocator.Error || Parser.Error)!void {
        switch (t.type) {
            .Integer => {
                const integer = fmt.parseInt(isize, t.value.?, 0) catch |e| {
                    log.err("Parser: couldn't convert to integer, input={s}, error={}\n", .{ t.value.?, e });
                    return Error.InvalidInteger;
                };
                v.* = types.TomlValue{ .Integer = integer };
            },
            .Boolean => {
                debug.assert(t.value.?.len == 4 or t.value.?.len == 5);
                const boolean = if (t.value.?.len == 4) true else false;
                v.* = types.TomlValue{ .Boolean = boolean };
            },
            .Float => {
                if (!isValidFloat(t.value.?)) {
                    log.err("Parser: invalid float {s}", .{t.value.?});
                    return Error.InvalidFloat;
                }
                const float = fmt.parseFloat(f64, t.value.?) catch |e| {
                    log.err("Parser: couldn't convert to float, input={s}, error={}\n", .{ t.value.?, e });
                    return Error.InvalidFloat;
                };
                v.* = types.TomlValue{ .Float = float };
            },
            .BasicString => {
                // we don't own the slice in token.value so copy it.
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = types.TomlValue{ .String = string };
            },
            .MultiLineBasicString => {
                const string = try trimEscapedNewlines(allocator, stripInitialNewline(t.value.?));
                v.* = types.TomlValue{ .String = string };
            },
            .LiteralString => {
                // we don't own the slice in token.value so copy it.
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = types.TomlValue{ .String = string };
            },
            .MultiLineLiteralString => {
                const slice = stripInitialNewline(t.value.?);
                // we don't own the slice in token.value so copy it.
                const string = try allocator.alloc(u8, slice.len);
                @memcpy(string, slice);
                v.* = types.TomlValue{ .String = string };
            },
            else => {
                log.err("Parser: unkown value type `{}`\n", .{t.type});
                return Error.BadValue;
            },
        }
    }

    /// Processes the key_path array, creating the appropriate table for each key and returns
    /// the final table into which the current_key should be inserted.
    fn walkKeyPath(self: *Self) (mem.Allocator.Error || Parser.Error)!*types.TomlTable {
        var temp = self.current_table;
        for (self.key_path.data()) |table_name| {
            if (temp.getPtr(table_name)) |value| {
                // if (self.implicit_map.contains(table_name)) {
                switch (value.*) {
                    .Table => |*t| temp = t,
                    .TablesArray => |ta| {
                        const size = ta.len;
                        if (size > 0) {
                            temp = &ta[size - 1];
                        } else {
                            // TODO: handle cases where the array is empty.
                        }
                    },
                    else => {
                        log.err("Parser: key {s} is neither a table nor an arrays of tables", .{table_name});
                        return Error.DuplicateKey;
                    },
                }
                // } else {
                //     log.err("Parser: redefinition of key {s}", .{table_name});
                //     return Error.DuplicateKey;
                // }
            } else {
                var new_table = types.TomlTable.init(self.arena.allocator());
                try new_table.ensureTotalCapacity(32);
                try temp.put(
                    table_name,
                    types.TomlValue{ .Table = new_table },
                );
                try self.implicit_map.put(table_name, {});
                temp = &temp.getPtr(table_name).?.Table;
            }
        }
        self.key_path.clearContent();
        return temp;
    }

    /// Returns a pointer to the current table by walkine table_context
    /// array from the root table.
    fn walkTableContext(self: *Self) *types.TomlTable {
        var final_table = &self.root_table;
        for (self.table_context.data()) |table_name| {
            final_table = &final_table.getPtr(table_name).?.Table;
        }
        return final_table;
    }

    fn putValue(self: *Self, value: *const types.TomlValue) (mem.Allocator.Error || Parser.Error)!*types.TomlValue {
        const key = self.current_key;
        var dest_table = try self.walkKeyPath();
        if (dest_table.getPtr(key)) |v| {
            _ = v;
            // possibly a duplicate key
            // if (self.implicit_map.contains(key)) {
            //     // make it explicit
            //     _ = self.implicit_map.remove(key);
            //     switch (value.*) {
            //         .Table => return v, // already done.
            //         else => {
            //             log.err("Parser: '{s}' is already a table, can't change the type", .{key});
            //             return Error.DuplicateKey;
            //         },
            //     }
            // } else {
            log.err("Parser: redefinition of key '{s}'", .{key});
            return Error.DuplicateKey;
            // }
        }
        try dest_table.put(key, value.*);
        return dest_table.getPtr(key).?;
    }

    /// Skips the initial newline character in mutlilines strings.
    fn stripInitialNewline(slice: []const u8) []const u8 {
        var start_index: usize = 0;
        if (slice.len > 0 and slice[0] == '\n') {
            start_index = 1;
        } else if (slice.len > 1 and slice[0] == '\r' and slice[1] == '\n') {
            start_index = 2;
        }
        return slice[start_index..];
    }

    /// Validates and removes white space and newlines after a backslash `\`
    fn trimEscapedNewlines(allocator: mem.Allocator, slice: []const u8) (mem.Allocator.Error || Parser.Error)![]const u8 {
        var trimmed = try common.String8.initCapacity(allocator, slice.len);
        errdefer trimmed.deinit();
        var wr = trimmed.writer();
        var iter = mem.splitSequence(u8, slice, &[_]u8{'\\'});

        _ = wr.write(iter.first()) catch unreachable;
        while (iter.next()) |seq| {
            if (seq.len > 2 and seq[1] == '\\') {
                // nothing to trim
                trimmed.append('\\') catch unreachable;
                _ = wr.write(seq) catch unreachable;
            }
            var i: usize = 0;
            for (seq) |byte| {
                switch (byte) {
                    ' ', '\t', '\n', '\r' => {
                        i += 1;
                        continue;
                    },
                    else => break,
                }
            }
            if (i != 0) {
                if (mem.indexOf(u8, seq[0..i], &[_]u8{'\n'}) == null) {
                    return Error.InvalidStringEscape;
                }
            }
            _ = wr.write(seq[i..]) catch unreachable;
        }
        return try trimmed.toOwnedSlice();
    }

    fn isValidFloat(slice: []const u8) bool {
        var valid = true;
        // period check.
        // 7. and 3.e+20 are not valid float in toml 1.0 spec
        if (mem.indexOf(u8, slice, &[_]u8{'.'})) |index| {
            valid = valid and (slice.len > index + 1 and common.isDigit(slice[index + 1]));
            valid = valid and (index > 0 and common.isDigit(slice[index - 1]));
        }

        return valid;
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
