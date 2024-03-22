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
        // the stream has less than 3 bytes.
        // for now go back and let the lexer throw the errors
        in.seekTo(0) catch unreachable;
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
        // the stream has less than 2 bytes.
        // for now go back and let the lexer throw the errors
        in.seekTo(0) catch unreachable;
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
    key_path: common.DynArray(types.Key), // used to keep track of key parts e.g. "a.b.c",
    allocator: mem.Allocator,
    arena: heap.ArenaAllocator,
    implicit_map: StringHashmap(void),
    inline_map: StringHashmap(void),
    root_table: types.TomlTable,
    state_stack: ParserStateStack,
    array_stack: TomlArrayStack, // keeps track of nested arrays.
    state: ParserState,

    const DEBUG_KEY = "DEBUG";

    const Self = @This();

    const Error = error{
        LexerError,
        DuplicateKey,
        InlineTableUpdate,
        InvalidInteger,
        InvalidFloat,
        InvalidString,
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
        var implicit_map = StringHashmap(void).init(allocator);
        try implicit_map.ensureTotalCapacity(16);
        errdefer implicit_map.deinit();
        var inline_map = StringHashmap(void).init(allocator);
        try inline_map.ensureTotalCapacity(16);
        errdefer inline_map.deinit();
        var root = types.TomlTable.init(allocator);
        try root.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
        errdefer root.deinit();
        var key_path = try common.DynArray(types.Key).initCapacity(
            allocator,
            opt.DEFAULT_ARRAY_SIZE,
        );
        errdefer key_path.deinit();
        var arena = heap.ArenaAllocator.init(allocator);
        return .{
            .toml_src = toml_input,
            .lexer = lexer,
            .key_path = key_path,
            .array_stack = TomlArrayStack{},
            .implicit_map = implicit_map,
            .inline_map = inline_map,
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
        self.implicit_map.deinit();
        self.inline_map.deinit();
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
                        .{ token.start.line, token.start.column, token.value.? },
                    );
                    return Error.LexerError;
                },
                .TableStart, .ArrayTableStart => {
                    self.popState();
                },
                .TableEnd => {
                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
                    var value = types.TomlValue{ .Table = new_table };
                    const value_ptr = try self.putValue(&value);
                    try self.pushState(.Table, &value_ptr.Table);
                },
                .ArrayTableEnd => {
                    const dest_table = try self.walkKeyPath(&self.root_table, false);
                    var tbl_array = if (dest_table.getPtr(self.state.key)) |value| blk: {
                        switch (value.*) {
                            .TablesArray => |old_array| {
                                _ = dest_table.remove(self.state.key);
                                const success = self.arena
                                    .allocator()
                                    .resize(old_array, old_array.len + 1);

                                if (!success) {
                                    const new_array = try self.arena
                                        .allocator()
                                        .alloc(
                                        types.TomlTable,
                                        old_array.len + 1,
                                    );

                                    defer self.arena.allocator().free(old_array);
                                    for (0..old_array.len) |i| {
                                        new_array[i] = old_array[i];
                                    }
                                    break :blk new_array;
                                }
                                break :blk old_array;
                            },
                            else => {
                                log.err(
                                    "Parser: attempt to redefine '{s}' as an array of tables.",
                                    .{self.state.key},
                                );
                                return Error.DuplicateKey;
                            },
                        }
                    } else try self.arena
                        .allocator()
                        .alloc(types.TomlTable, 1);

                    errdefer self.arena
                        .allocator()
                        .free(tbl_array);

                    var new_table = types.TomlTable.init(self.arena.allocator());
                    try new_table.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
                    tbl_array[tbl_array.len - 1] = new_table;
                    var value = types.TomlValue{ .TablesArray = tbl_array };
                    _ = try self.putValue(&value);
                    try self.pushState(.Table, &tbl_array[tbl_array.len - 1]);
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
                    try self.inline_map.put(self.state.key, {});
                    try self.pushState(.Table, &value_ptr.Table);
                },
                .InlineTableEnd => {
                    self.popState();
                },
                .Comment => {},
                .Key => {
                    // We don't own the memory pointed to by token.value.
                    const key = try self.arena
                        .allocator()
                        .alloc(u8, token.value.?.len);

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

    fn parseValue(
        allocator: mem.Allocator,
        t: *const lex.Token,
        v: *types.TomlValue,
    ) (mem.Allocator.Error || Parser.Error)!void {
        switch (t.type) {
            .Integer => {
                if (!isValidNumber(t.value.?)) {
                    log.err("Parser: '{s}' isn't a valid number", .{t.value.?});
                    return Error.InvalidInteger;
                }
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
                    log.err(
                        "Parser: couldn't convert to float, input={s}, error={}\n",
                        .{ t.value.?, e },
                    );
                    return Error.InvalidFloat;
                };
                v.* = types.TomlValue{ .Float = float };
            },
            .BasicString => {
                // we don't own the slice in token.value so copy it.
                if (!common.isValidUTF8(t.value.?)) {
                    log.err(
                        "Parser: string '{s}' contains invalid UTF-8 sequence.",
                        .{t.value.?},
                    );
                    return Error.InvalidString;
                }
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = types.TomlValue{ .String = string };
            },
            .MultiLineBasicString => {
                const string = try trimEscapedNewlines(
                    allocator,
                    stripInitialNewline(t.value.?),
                );
                if (!common.isValidUTF8(string)) {
                    log.err(
                        "Parser: string '{s}' contains invalid UTF-8 sequence.",
                        .{t.value.?},
                    );
                    allocator.free(string);
                    return Error.InvalidString;
                }
                v.* = types.TomlValue{ .String = string };
            },
            .LiteralString => {
                // we don't own the slice in token.value so copy it.
                if (!common.isValidUTF8(t.value.?)) {
                    log.err(
                        "Parser: string '{s}' contains invalid UTF-8 sequence.",
                        .{t.value.?},
                    );
                    return Error.InvalidString;
                }
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = types.TomlValue{ .String = string };
            },
            .MultiLineLiteralString => {
                const slice = stripInitialNewline(t.value.?);
                if (!common.isValidUTF8(slice)) {
                    log.err(
                        "Parser: string '{s}' contains invalid UTF-8 sequence.",
                        .{t.value.?},
                    );
                    return Error.InvalidString;
                }
                // we don't own the slice in token.value so copy it.
                const string = try allocator.alloc(u8, slice.len);
                @memcpy(string, slice);
                v.* = types.TomlValue{ .String = string };
            },
            .DateTime => {
                var date_time: types.DateTime = undefined;
                try parseDateTime(t.value.?, &date_time);
                v.* = types.TomlValue{ .DateTime = date_time };
            },
            else => unreachable,
        }
    }

    fn parseDateTime(src: []const u8, output: *types.DateTime) Error!void {
        var input = src;
        var expect_date: bool = false;
        output.date = parseDate(input);
        if (output.date) |dt| {
            if (!common.isDateValid(dt.year, dt.month, dt.day)) {
                log.err(
                    "Parser: {d}-{d}-{d} is not a valid date",
                    .{ dt.year, dt.month, dt.day },
                );
                return Error.InvalidDate;
            }
            if (src.len > 10) {
                if (src[10] == 'T' and src.len > 11) {
                    input = src[11..src.len];
                    expect_date = true;
                } else {
                    log.err(
                        "Parser: \"{s}\" time should be separated from date with a valid separator",
                        .{input},
                    );
                    return Error.BadDateTimeFormat;
                }
            } else {
                output.time = null;
                return;
            }
        }

        output.time = parseTime(input);
        if (output.time) |t| {
            if (!common.isTimeValid(t.hour, t.minute, t.second)) {
                log.err(
                    "Parser: {d}:{d}:{d}.{d} is not a valid time",
                    .{ t.hour, t.minute, t.second, t.nano_second },
                );
                return Error.InvalidTime;
            }
        } else {
            if (output.date == null or expect_date) {
                return Error.BadDateTimeFormat;
            }
        }
    }

    /// Expected string format YYYY-MM-DD
    fn parseDate(src: []const u8) ?types.Date {
        if (src.len < 10) {
            return null;
        }
        if (src[4] != '-' or src[7] != '-') {
            return null;
        }
        const y = common.parseDigits(u16, src[0..4]) catch return null;
        const m = common.parseDigits(u8, src[5..7]) catch return null;
        const d = common.parseDigits(u8, src[8..10]) catch return null;
        return types.Date{
            .year = y,
            .month = m,
            .day = d,
        };
    }

    /// Expected string format HH:MM:SS.FFZ or HH:MM:SS.FF
    fn parseTime(src: []const u8) ?types.Time {
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

        var offs: ?types.TimeOffset = null;

        if (src.len > 8) {
            var slice = src[8..src.len];
            if (slice[0] == '.') {
                const stop = common.parseNanoSeconds(slice[1..slice.len], &ns);
                slice = slice[stop + 1 .. slice.len];
            }

            if (slice.len > 0) {
                switch (slice[0]) {
                    'Z' => offs = types.TimeOffset{ .z = true, .minutes = 0 },
                    '+', '-' => {
                        var sign: i16 = switch (slice[0]) {
                            '+' => -1,
                            '-' => 1,
                            else => return null,
                        };
                        if (slice.len < 6 or slice[3] != ':') {
                            return null;
                        }
                        var off_h: u8 = common.parseDigits(u8, slice[1..3]) catch
                            return null;
                        var off_m: u8 = common.parseDigits(u8, slice[4..6]) catch
                            return null;

                        offs = types.TimeOffset{
                            .z = false,
                            .minutes = ((@as(i16, off_h) * 60) + @as(i16, off_m)) * sign,
                        };
                    },
                    else => return null,
                }
            }
        }

        return types.Time{
            .hour = h,
            .minute = m,
            .second = s,
            .nano_second = ns,
            .offset = offs,
        };
    }

    /// Processes the key_path array, creating the appropriate table for each key and returns
    /// the final table into which the current_key should be inserted.
    fn walkKeyPath(
        self: *Self,
        start: *types.TomlTable,
        add_implicit: bool,
    ) (mem.Allocator.Error || Parser.Error)!*types.TomlTable {
        var temp = start;
        for (self.key_path.data()) |table_name| {
            if (temp.getPtr(table_name)) |value| {
                switch (value.*) {
                    .Table => |*t| {
                        if (self.inline_map.get(table_name)) |_| {
                            // toml tried to add a property to an already
                            // defined inline table.
                            log.err("Parser: inline table '{s}' can't be updated after declaration.", .{table_name});
                            return Error.InlineTableUpdate;
                        }
                        temp = t;
                    },
                    .TablesArray => |ta| {
                        debug.assert(ta.len > 0);
                        temp = &ta[ta.len - 1];
                    },
                    else => {
                        log.err("Parser: key {s} is neither a table nor an arrays of tables", .{table_name});
                        return Error.DuplicateKey;
                    },
                }
            } else {
                var new_table = types.TomlTable.init(self.arena.allocator());
                try new_table.ensureTotalCapacity(opt.DEFAULT_HASHMAP_SIZE);
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
        return temp;
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
                self.key_path.clearContent();
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
    fn trimEscapedNewlines(
        allocator: mem.Allocator,
        slice: []const u8,
    ) (mem.Allocator.Error || Parser.Error)![]const u8 {
        // debug.print("TRIM={s}\n", .{slice});
        var trimmed = try common.String8.initCapacity(allocator, slice.len);
        errdefer trimmed.deinit();

        var i: usize = 0;
        while (i < slice.len) {
            if (slice[i] != '\\') {
                trimmed.append(slice[i]) catch unreachable;
            } else if (i + 1 < slice.len and slice[i + 1] == '\\') {
                trimmed.append('\\') catch unreachable;
                i += 1;
            } else {
                var j = i + 1;
                while (j < slice.len) {
                    switch (slice[j]) {
                        ' ', '\t', '\n', '\r' => {
                            j += 1;
                            continue;
                        },
                        else => break,
                    }
                }
                if (j != i + 1) {
                    // a newline character is obligatory.
                    if (mem.indexOf(u8, slice[(i + 1)..j], &[_]u8{'\n'}) == null) {
                        return Error.InvalidStringEscape;
                    }
                    i = j;
                    continue;
                }
            }
            i += 1;
        }
        return try trimmed.toOwnedSlice();
    }

    fn isValidFloat(float: []const u8) bool {
        var valid = true;
        valid = valid and isUnderscoresSurrounded(float) and !hasLeadingZero(float);
        // period check.
        // 7. and 3.e+20 are not valid float in toml 1.0 spec
        if (mem.indexOf(u8, float, &[_]u8{'.'})) |index| {
            valid = valid and (float.len > index + 1 and common.isDigit(float[index + 1]));
            valid = valid and (index > 0 and common.isDigit(float[index - 1]));
        }

        return valid;
    }

    fn isUnderscoresSurrounded(num: []const u8) bool {
        if (num.len > 1) {
            if (num[0] == '_' or num[num.len - 1] == '_') {
                return false;
            }

            for (1..num.len - 1) |i| {
                if (num[i] == '_') {
                    if (!common.isHex(num[i - 1]) or !common.isHex(num[i + 1])) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    fn hasLeadingZero(num: []const u8) bool {
        var has_leading_zero = false;
        if (num.len > 2 and
            (num[0] == '+' or
            num[0] == '-') and
            num[1] == '0' and
            !(num[2] == '.' or num[2] == 'e'))
        {
            has_leading_zero = true;
        } else if (num.len > 1 and
            num[0] == '0' and
            !(num[1] == 'b' or
            num[1] == 'o' or
            num[1] == 'x' or
            num[1] == '.' or
            num[1] == 'e'))
        {
            has_leading_zero = true;
        }
        return has_leading_zero;
    }

    fn isValidNumber(num: []const u8) bool {
        var valid = true;
        valid = valid and isUnderscoresSurrounded(num) and
            !hasLeadingZero(num);
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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

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
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parseDebug();
}
