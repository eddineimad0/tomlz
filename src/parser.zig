const std = @import("std");
const lex = @import("lexer.zig");
const cnst = @import("constants.zig");
const common = @import("common.zig");
const types = @import("types.zig");
const opt = @import("build_options");

const fmt = std.fmt;
const mem = std.mem;
const heap = std.heap;
const io = std.io;
const debug = std.debug;
const log = std.log;

const StringHashmap = std.StringHashMap;
const TomlValueArray = common.DynArray(types.TomlValue);
const TomlArrayStack = std.SegmentedList(TomlValueArray, 8);

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

const ParserContext = enum(u1) {
    Table,
    Array,
};
const ParserState = struct {
    context: ParserContext,
    target: *anyopaque, // where to put current key/value.
    key: types.Key,
};

const ParserStateStack = std.SegmentedList(ParserState, 8);

pub const Parser = struct {
    toml_src: *io.StreamSource,
    lexer: lex.Lexer,
    table_context: common.DynArray(types.Key), // used to keep track of table nestting.
    key_path: common.DynArray(types.Key), // used to keep track of key parts e.g. "a.b.c",
    array_stack: TomlArrayStack, // keeps track of nested arrays.
    allocator: mem.Allocator,
    arena: heap.ArenaAllocator,
    implicit_map: StringHashmap(void),
    root_table: types.TomlTable,
    state_stack: ParserStateStack,
    state: ParserState,
    // current_table: *types.TomlTable,
    // current_array: ?*TomlValueArray,
    //
    const DEBUG_KEY = "DEBUG";

    const Self = @This();

    const Error = error{
        LexerError,
        DuplicateKey,
        InvalidInteger,
        InvalidFloat,
        InvalidStringEscape,
        BadValue,
        InvalidDate,
        InvalidTime,
        BadDateTimeFormat,
    };

    /// initialize a toml parser, the toml_input pointer should remain valid
    /// until the parser is deinitialized.
    /// call deinit() when done to release memory resources.
    pub fn init(allocator: mem.Allocator, toml_input: *io.StreamSource) mem.Allocator.Error!Self {
        var lexer = try lex.Lexer.init(allocator, toml_input);
        errdefer lexer.deinit();
        var map = StringHashmap(void).init(allocator);
        try map.ensureTotalCapacity(16);
        errdefer map.deinit();
        var root = types.TomlTable.init(allocator);
        try root.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
        errdefer root.deinit();
        var table_context = try common.DynArray(types.Key).initCapacity(
            allocator,
            opt.DEFAULT_ARRAY_SIZE,
        );
        errdefer table_context.deinit();
        var key_path = try common.DynArray(types.Key).initCapacity(
            allocator,
            opt.DEFAULT_ARRAY_SIZE,
        );
        errdefer key_path.deinit();
        var arena = heap.ArenaAllocator.init(allocator);
        return .{
            .toml_src = toml_input,
            .lexer = lexer,
            .table_context = table_context,
            .key_path = key_path,
            .array_stack = TomlArrayStack{},
            .implicit_map = map,
            .allocator = allocator,
            .arena = arena,
            .root_table = root,
            .state_stack = ParserStateStack{},
            .state = undefined,
        };
    }

    /// Frees memory resources used by the parser.
    /// you shouldn't attempt to use the parser after calling this function
    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
        self.key_path.deinit();
        self.table_context.deinit();
        self.implicit_map.deinit();
        self.array_stack.deinit(self.allocator);
        self.state_stack.deinit(self.allocator);
        self.root_table.deinit();
        self.arena.deinit();
    }

    fn pushState(
        self: *Self,
        new_context: ParserContext,
        new_put_target: *anyopaque,
    ) mem.Allocator.Error!void {
        try self.state_stack.append(self.allocator, self.state);
        self.state = .{
            .context = new_context,
            .target = new_put_target,
            .key = DEBUG_KEY, // default value for debuging
        };
    }

    fn popState(self: *Self) void {
        self.state = self.state_stack.pop() orelse .{
            .context = .Table,
            .target = &self.root_table,
            .key = DEBUG_KEY,
        };
    }

    pub fn parse(self: *Self) (mem.Allocator.Error || Parser.Error)!*const types.TomlTable {
        skipUTF16BOM(self.toml_src);
        skipUTF8BOM(self.toml_src);

        var token: lex.Token = undefined;

        self.state = .{ .context = .Table, .target = &self.root_table, .key = DEBUG_KEY };

        while (true) {
            self.lexer.nextToken(&token);
            switch (token.type) {
                .EOS => break,
                .Error => {
                    // TODO: make error message reporting opt-in by the caller.
                    log.err(
                        "[line:{d},col:{d}], {s}\n",
                        .{ token.start.line, token.start.offset, token.value.? },
                    );
                    return Error.LexerError;
                },
                .TableStart => {
                    self.popState();
                },
                .TableEnd => {
                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
                    var value = types.TomlValue{ .Table = new_table };
                    const value_ptr = try self.putValue(&value);
                    try self.pushState(.Table, &value_ptr.Table);
                },
                .ArrayStart => {
                    try self.array_stack.append(
                        self.allocator,
                        try TomlValueArray.initCapacity(
                            self.arena.allocator(),
                            opt.DEFAULT_ARRAY_SIZE,
                        ),
                    );
                    try self.pushState(.Array, self.array_stack.at(self.array_stack.len - 1));
                },
                .ArrayEnd => {
                    var array = self.array_stack.pop().?;
                    const slice = try array.toOwnedSlice();
                    array.deinit();
                    var value = types.TomlValue{ .Array = slice };
                    self.popState();
                    _ = try self.putValue(&value);
                },
                .InlineTableStart => {
                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
                    var value = types.TomlValue{ .Table = new_table };
                    errdefer new_table.deinit();
                    const value_ptr = try self.putValue(&value);
                    try self.pushState(.Table, &value_ptr.Table);
                },
                .InlineTableEnd => {
                    self.popState();
                },
                .ArrayTableStart, .ArrayTableEnd => {},
                .Comment => {},
                .Key => {
                    // We don't own the memory pointed to by token.value.
                    const key = try self.arena.allocator().alloc(u8, token.value.?.len);
                    @memcpy(key, token.value.?);
                    self.state.key = key;
                },
                .Dot => {
                    // Sent when a dot between keys is encountered 'a.b'
                    try self.key_path.append(self.state.key);
                },
                else => {
                    var value: types.TomlValue = undefined;
                    try parseValue(self.arena.allocator(), &token, &value);
                    _ = try self.putValue(&value);
                },
            }
        }
        return &self.root_table;
    }

    // fn pushImplicitTable(self: *Self, key: types.Key) mem.Allocator.Error!void {
    //     // try self.implicit_map.put(
    //     //     key,
    //     //     {},
    //     // );
    //     try self.key_path.append(key);
    // }

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
            .DateTime => {
                var date_time: types.LocalDateTime = undefined;
                try parseLocalDateTime(t.value.?, &date_time);
                v.* = types.TomlValue{ .DateTime = date_time };
            },
            else => unreachable,
        }
    }

    fn parseLocalDateTime(src: []const u8, output: *types.LocalDateTime) Error!void {
        var input = src;
        output.date = parseLocalDate(input);
        if (output.date) |dt| {
            if (!common.isDateValid(dt.year, dt.month, dt.day)) {
                log.err("Parser: {d}-{d}-{d} is not a valid date", .{ dt.year, dt.month, dt.day });
                return Error.InvalidDate;
            }
            if (src.len > 11 and (src[10] == 'T')) {
                input = src[11..src.len];
            } else {
                output.time = null;
                return;
            }
        }

        output.time = parseLocalTime(input);
        if (output.time) |t| {
            if (!common.isTimeValid(t.hour, t.minute, t.second)) {
                log.err("Parser: {d}:{d}:{d}.{d} is not a valid time", .{ t.hour, t.minute, t.second, t.nano_second });
                return Error.InvalidTime;
            }
        } else {
            if (output.date == null) {
                return Error.BadDateTimeFormat;
            }
        }
    }

    /// Expected string format YYYY-MM-DD
    fn parseLocalDate(src: []const u8) ?types.LocalDate {
        if (src.len < 10) {
            return null;
        }
        if (src[4] != '-' or src[7] != '-') {
            return null;
        }
        const y = common.parseDigits(u16, src[0..4]) catch return null;
        const m = common.parseDigits(u8, src[5..7]) catch return null;
        const d = common.parseDigits(u8, src[8..10]) catch return null;
        return types.LocalDate{
            .year = y,
            .month = m,
            .day = d,
        };
    }

    /// Expected string format HH:MM:SS.FFZ or HH:MM:SS.FF
    fn parseLocalTime(src: []const u8) ?types.LocalTime {
        // TODO: incomplete.
        if (src.len < 8) {
            return null;
        }
        if (src[2] != ':' or src[5] != ':') {
            return null;
        }
        const h = common.parseDigits(u8, src[0..2]) catch return null;
        const m = common.parseDigits(u8, src[3..5]) catch return null;
        const s = common.parseDigits(u8, src[6..8]) catch return null;

        var ns: u32 = 0;

        if (src.len > 8) {
            var slice = src[8..src.len];
            if (slice[0] == '.') {
                const stop = common.parseNanoSeconds(slice[1..slice.len], &ns);
                slice = slice[stop + 1 .. slice.len];
            }

            // if (slice.len > 0) {
            //     switch (slice[0]) {
            //         'Z' => offs = TimeOffset{ .z = true, .minutes = 0 },
            //         '+', '-' => {
            //             var sign: i16 = switch (slice[0]) {
            //                 '+' => -1,
            //                 '-' => 1,
            //                 else => return null,
            //             };
            //             if (slice.len < 6 or slice[3] != ':') {
            //                 return null;
            //             }
            //             var off_h: u8 = parseDigits(u8, slice[1..3]) catch return null;
            //             var off_m: u8 = parseDigits(u8, slice[4..6]) catch return null;
            //
            //             offs = TimeOffset{
            //                 .z = false,
            //                 .minutes = ((@as(i16, off_h) * 60) + @as(i16, off_m)) * sign,
            //             };
            //         },
            //         else => return null,
            //     }
            // }
        }

        return types.LocalTime{
            .hour = h,
            .minute = m,
            .second = s,
            .nano_second = ns,
            .precision = 0,
        };
    }

    /// Processes the key_path array, creating the appropriate table for each key and returns
    /// the final table into which the current_key should be inserted.
    fn walkKeyPath(self: *Self, start: *types.TomlTable, add_implicit: bool) (mem.Allocator.Error || Parser.Error)!*types.TomlTable {
        var temp = start;
        for (self.key_path.data()) |table_name| {
            if (temp.getPtr(table_name)) |value| {
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
            } else {
                var new_table = types.TomlTable.init(self.arena.allocator());
                try new_table.ensureTotalCapacity(32);
                try temp.put(
                    table_name,
                    types.TomlValue{ .Table = new_table },
                );
                if (add_implicit) {
                    try self.implicit_map.put(table_name, {});
                }
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

    /// Insert the value into the current toml context (Table or Array) and return a pointer to that value.
    fn putValue(
        self: *Self,
        value: *types.TomlValue,
    ) (mem.Allocator.Error || Parser.Error)!*types.TomlValue {
        switch (self.state.context) {
            .Table => {
                var tbl: *types.TomlTable = @alignCast(@ptrCast(self.state.target));
                const key = self.state.key;
                // we need to handle dotted keys "a.b.c";
                const dest_table = try self.walkKeyPath(tbl, false);
                if (dest_table.getPtr(key)) |v| {
                    // possibly a duplicate key
                    if (self.implicit_map.contains(key)) {
                        // make it explicit
                        _ = self.implicit_map.remove(key);
                        switch (value.*) {
                            .Table => |*t| {
                                t.deinit();
                            },
                            else => {},
                        }
                        return v;
                    } else {
                        log.err("Parser: redefinition of key '{s}'", .{key});
                        return Error.DuplicateKey;
                    }
                }
                try dest_table.put(key, value.*);
                return dest_table.getPtr(key).?;
            },
            .Array => {
                var a: *TomlValueArray = @alignCast(@ptrCast(self.state.target));
                try a.append(value.*);
                return a.getLastOrNull().?;
            },
        }
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
