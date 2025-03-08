const std = @import("std");
const lex = @import("lexer.zig");
const common = @import("common.zig");
const dt = @import("datatypes.zig");
const opt = @import("build_options");

const fmt = std.fmt;
const mem = std.mem;
const heap = std.heap;
const io = std.io;
const debug = std.debug;

const StringHashmap = std.StringHashMap;
const TomlValueArray = common.DynArray(dt.TomlValue);
const TomlArrayStack = std.SegmentedList(TomlValueArray, 8);
const KeyPathStack = std.SegmentedList(common.DynArray(dt.Key), 4);
const ParseError = @import("error.zig").ParseError;

pub const Parser = struct {
    const ParserContext = enum(u1) {
        Table,
        Array,
    };

    const ParserState = struct {
        context: ParserContext,
        target: *anyopaque, // where to put current key/value.
        key: dt.Key,
    };

    const ParserStateStack = std.SegmentedList(ParserState, 8);

    const DEBUG_KEY = "__TOMLZ_DEBUG";

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

    const Self = @This();

    implicit_map: StringHashmap(void),
    inline_map: StringHashmap(void),
    base_allocator: mem.Allocator,
    arena: heap.ArenaAllocator,
    state_stack: ParserStateStack,
    array_stack: TomlArrayStack, // keeps track of nested arrays.
    key_path_stack: KeyPathStack,
    state: ParserState,
    err: ParseError,
    root: dt.TomlTable,

    /// initialize a toml parser.
    /// call deinit() when done to release memory resources.
    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .implicit_map = StringHashmap(void).init(allocator),
            .inline_map = StringHashmap(void).init(allocator),
            .array_stack = TomlArrayStack{},
            .state_stack = ParserStateStack{},
            .key_path_stack = KeyPathStack{},
            .base_allocator = allocator,
            .arena = heap.ArenaAllocator.init(allocator),
            .root = dt.TomlTable.init(allocator),
            .state = undefined,
            .err = ParseError.init(allocator),
        };
    }

    /// Frees memory resources used by the parser.
    /// you shouldn't attempt to use the parser after calling this function
    pub fn deinit(self: *Self) void {
        self.implicit_map.deinit();
        self.inline_map.deinit();
        self.array_stack.deinit(self.base_allocator);
        self.state_stack.deinit(self.base_allocator);
        self.key_path_stack.deinit(self.base_allocator);
        self.arena.deinit();
        self.root.deinit();
        self.err.deinit();
    }

    /// Parses the 'toml_input', decodes it and returns a TomlTable.
    /// in case of an error call *errorMessage()* to get a detailed
    /// error message.
    /// TomlTable which is an alias to std.StringHashMap(TomlValue).
    /// TomlValue type represent the following tagged union:
    /// union(TomlType) {
    ///     Boolean: bool,
    ///     Integer: i64,
    ///     Float: f64,
    ///     String: []const u8,
    ///     Array: []TomlValue,
    ///     Table: TomlTable,
    ///     TablesArray: []TomlTable,
    ///     DateTime: DateTime,
    /// };
    /// aside from DateTime all other types are standard zig types.
    /// all data returned by the parser is owned by the parser and
    /// will be freed once deinit is called or subsequent calls to *parse()*,
    /// consider cloning anything you need to outlive the parser.
    pub fn parse(
        self: *Self,
        toml_input: *io.StreamSource,
    ) (mem.Allocator.Error || Parser.Error)!*const dt.TomlTable {
        _ = self.arena.reset(.{ .free_all = {} });
        self.root.clearRetainingCapacity();

        try self.root.ensureTotalCapacity(opt.INITIAL_HASHMAP_SIZE);
        try self.implicit_map.ensureTotalCapacity(16);
        try self.inline_map.ensureTotalCapacity(16);

        var key_path = try common.DynArray(dt.Key).initCapacity(
            self.base_allocator,
            opt.INITIAL_ARRAY_SIZE,
        );
        defer key_path.deinit();

        self.state = .{ .context = .Table, .target = &self.root, .key = DEBUG_KEY };

        common.skipUTF16BOM(toml_input);
        common.skipUTF8BOM(toml_input);
        var lexer = try lex.Lexer.init(self.base_allocator, toml_input);
        defer lexer.deinit();

        var token: lex.Token = undefined;
        while (true) {
            lexer.nextToken(&token);
            switch (token.tag) {
                .EndOfStream => break,
                .Error => {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] {s}",
                        .{ token.start.line, token.start.column, token.value.? },
                    );
                    return Error.LexerError;
                },
                .TableStart, .ArrayTableStart => {
                    self.popState(&key_path);
                },
                .TableEnd => {
                    const table = try self.createTable(&key_path);
                    try self.pushState(.Table, table, &key_path);
                },
                .ArrayTableEnd => {
                    const tbl = try self.createTablesArray(&key_path);
                    try self.pushState(.Table, tbl, &key_path);
                },
                .ArrayStart => {
                    try self.array_stack.append(
                        self.base_allocator,
                        try TomlValueArray.initCapacity(
                            self.arena.allocator(),
                            opt.INITIAL_ARRAY_SIZE,
                        ),
                    );
                    try self.pushState(
                        .Array,
                        self.array_stack.at(self.array_stack.len - 1),
                        &key_path,
                    );
                },
                .ArrayEnd => {
                    var array = self.array_stack.pop().?;
                    const slice = try array.toOwnedSlice();
                    array.deinit();
                    var value = dt.TomlValue{ .Array = slice };
                    self.popState(&key_path);
                    _ = try self.putValue(&value, &key_path);
                },
                .InlineTableStart => {
                    const table = try self.createTable(&key_path);
                    try self.inline_map.put(self.state.key, {});
                    try self.pushState(.Table, table, &key_path);
                },
                .InlineTableEnd => {
                    self.popState(&key_path);
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
                    try key_path.append(self.state.key);
                },
                else => {
                    var value: dt.TomlValue = undefined;
                    try self.parseValue(self.arena.allocator(), &token, &value);
                    _ = try self.putValue(&value, &key_path);
                },
            }
        }

        self.implicit_map.clearAndFree();
        self.inline_map.clearAndFree();
        self.array_stack.clearRetainingCapacity();
        self.state_stack.clearRetainingCapacity();

        return &self.root;
    }

    /// Returns a string slice containing a detailed message about
    /// the last error encountered by the parser.
    /// the slice memory is managed by the parser and might get overwritten
    /// on subsequent calls to 'parse()'.
    pub inline fn errorMessage(self: *const Self) []const u8 {
        return self.err.errorMessage();
    }

    fn pushState(
        self: *Self,
        new_context: ParserContext,
        new_put_target: *anyopaque,
        current_key_path: *common.DynArray(dt.Key),
    ) mem.Allocator.Error!void {
        try self.state_stack.append(self.base_allocator, self.state);
        self.state = .{
            .context = new_context,
            .target = new_put_target,
            .key = DEBUG_KEY,
        };
        if (current_key_path.size() > 0) {
            try self.key_path_stack.append(self.base_allocator, current_key_path.*);
            current_key_path.* = try common.DynArray(dt.Key).initCapacity(
                self.base_allocator,
                opt.INITIAL_ARRAY_SIZE,
            );
        }
    }

    fn popState(
        self: *Self,
        current_key_path: *common.DynArray(dt.Key),
    ) void {
        self.state = self.state_stack.pop() orelse .{
            .context = .Table,
            .target = &self.root,
            .key = DEBUG_KEY,
        };
        if (self.key_path_stack.len > 0) {
            current_key_path.deinit();
            current_key_path.* = self.key_path_stack.pop() orelse unreachable;
        }
    }

    fn parseValue(
        self: *Self,
        allocator: mem.Allocator,
        t: *const lex.Token,
        v: *dt.TomlValue,
    ) (mem.Allocator.Error || Parser.Error)!void {
        switch (t.tag) {
            .Integer => {
                if (!isValidNumber(t.value.?)) {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): '{s}' isn't a valid integer",
                        .{ t.start.line, t.start.column, t.value.? },
                    );
                    return Error.InvalidInteger;
                }
                const integer = fmt.parseInt(isize, t.value.?, 0) catch {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): couldn't parse string {s} to integer",
                        .{ t.start.line, t.start.column, t.value.? },
                    );
                    return Error.InvalidInteger;
                };
                v.* = dt.TomlValue{ .Integer = integer };
            },
            .Boolean => {
                debug.assert(t.value.?.len == 4 or t.value.?.len == 5);
                const boolean = if (t.value.?.len == 4) true else false;
                v.* = dt.TomlValue{ .Boolean = boolean };
            },
            .Float => {
                if (!isValidFloat(t.value.?)) {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): '{s}' isn't a valid float",
                        .{ t.start.line, t.start.column, t.value.? },
                    );
                    return Error.InvalidFloat;
                }
                const float = fmt.parseFloat(f64, t.value.?) catch {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): couldn't parse string {s} to float",
                        .{ t.start.line, t.start.column, t.value.? },
                    );
                    return Error.InvalidFloat;
                };
                v.* = dt.TomlValue{ .Float = float };
            },
            .BasicString => {
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = dt.TomlValue{ .String = string };
            },
            .MultiLineBasicString => {
                const string = try trimEscapedNewlines(
                    allocator,
                    stripInitialNewline(t.value.?),
                );
                v.* = dt.TomlValue{ .String = string };
            },
            .LiteralString => {
                const string = try allocator.alloc(u8, t.value.?.len);
                @memcpy(string, t.value.?);
                v.* = dt.TomlValue{ .String = string };
            },
            .MultiLineLiteralString => {
                const slice = stripInitialNewline(t.value.?);
                const string = try allocator.alloc(u8, slice.len);
                @memcpy(string, slice);
                v.* = dt.TomlValue{ .String = string };
            },
            .DateTime => {
                var date_time: dt.DateTime = undefined;
                try self.parseDateTime(t, &date_time);
                v.* = dt.TomlValue{ .DateTime = date_time };
            },
            else => unreachable,
        }
    }

    fn parseDateTime(
        self: *Self,
        token: *const lex.Token,
        output: *dt.DateTime,
    ) Error!void {
        const src = token.value.?;
        var input = src;
        var expect_time: bool = false;
        output.date = parseDate(input);
        if (output.date) |date| {
            if (!common.isDateValid(date.year, date.month, date.day)) {
                self.err.writeErrorMsg(
                    "[line:{d},col:{d}] (Parser): {d}-{d}-{d} is not a valid date",
                    .{ token.start.line, token.start.column, date.year, date.month, date.day },
                );
                return Error.InvalidDate;
            }
            if (src.len > 10) {
                if (src[10] == 'T' and src.len > 11) {
                    input = src[11..src.len];
                    expect_time = true;
                } else {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): \"{s}\" time should be separated from date",
                        .{ token.start.line, token.start.column, input },
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
                self.err.writeErrorMsg(
                    "[line:{d},col:{d}] (Parser): {d}:{d}:{d}.{d} is not a valid time",
                    .{ token.start.line, token.start.column, t.hour, t.minute, t.second, t.nano_second },
                );
                return Error.InvalidTime;
            }
            if (t.offset) |offs| {
                if (!common.isTimeValid(offs.hour, offs.minute, 0)) {
                    self.err.writeErrorMsg(
                        "[line:{d},col:{d}] (Parser): {d}:{d} is not a valid offset",
                        .{ token.start.line, token.start.column, offs.hour, offs.minute },
                    );
                    return Error.InvalidTime;
                }
            }
        } else {
            if (output.date == null or expect_time) {
                self.err.writeErrorMsg(
                    "[line:{d},col:{d}] (Parser): {s} is not a valid date-time",
                    .{ token.start.line, token.start.column, src },
                );
                return Error.BadDateTimeFormat;
            }
        }
    }

    /// Expected string format YYYY-MM-DD
    fn parseDate(src: []const u8) ?dt.Date {
        if (src.len < 10) {
            return null;
        }
        if (src[4] != '-' or src[7] != '-') {
            return null;
        }
        const y = common.parseDigits(u16, src[0..4]) catch return null;
        const m = common.parseDigits(u8, src[5..7]) catch return null;
        const d = common.parseDigits(u8, src[8..10]) catch return null;
        return dt.Date{
            .year = y,
            .month = m,
            .day = d,
        };
    }

    /// Expected string format HH:MM:SS.FFZ or HH:MM:SS.FF
    fn parseTime(src: []const u8) ?dt.Time {
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

        var offs: ?dt.TimeOffset = null;

        if (src.len > 8) {
            var slice = src[8..src.len];
            if (slice[0] == '.') {
                const stop = common.parseNanoSeconds(slice[1..slice.len], &ns);
                slice = slice[stop + 1 .. slice.len];
            }

            if (slice.len > 0) {
                switch (slice[0]) {
                    'Z' => offs = dt.TimeOffset{ .z = true, .sign = 0, .hour = 0, .minute = 0 },
                    '+', '-' => {
                        const sign: i16 = switch (slice[0]) {
                            '+' => -1,
                            '-' => 1,
                            else => return null,
                        };
                        if (slice.len < 6 or slice[3] != ':') {
                            return null;
                        }
                        const off_h: u8 = common.parseDigits(u8, slice[1..3]) catch
                            return null;
                        const off_m: u8 = common.parseDigits(u8, slice[4..6]) catch
                            return null;

                        offs = dt.TimeOffset{
                            .z = false,
                            .sign = sign,
                            .hour = off_h,
                            .minute = off_m,
                        };
                    },
                    else => return null,
                }
            }
        }

        return dt.Time{
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
        start: *dt.TomlTable,
        key_path: []const dt.Key,
    ) (mem.Allocator.Error || Parser.Error)!*dt.TomlTable {
        var temp = start;
        for (key_path) |table_name| {
            if (temp.getPtr(table_name)) |value| {
                switch (value.*) {
                    .Table => |*t| {
                        if (self.inline_map.contains(table_name)) {
                            // toml tried to add a property to an already
                            // defined inline table.
                            self.err.writeErrorMsg(
                                "(Parser): inline table '{s}' can't be updated after declaration.",
                                .{table_name},
                            );
                            return Error.InlineTableUpdate;
                        }
                        temp = t;
                    },
                    else => {
                        self.err.writeErrorMsg("(Parser): key {s} is not a table", .{table_name});
                        return Error.DuplicateKey;
                    },
                }
            } else {
                var new_table = dt.TomlTable.init(self.arena.allocator());
                try new_table.ensureTotalCapacity(opt.INITIAL_HASHMAP_SIZE);
                try temp.put(
                    table_name,
                    dt.TomlValue{ .Table = new_table },
                );
                temp = &temp.getPtr(table_name).?.Table;
            }
        }
        return temp;
    }

    fn walkHeaderPath(
        self: *Self,
        start: *dt.TomlTable,
        header_path: []const dt.Key,
    ) (mem.Allocator.Error || Parser.Error)!*dt.TomlTable {
        var temp = start;
        for (header_path) |table_name| {
            if (temp.getPtr(table_name)) |value| {
                switch (value.*) {
                    .Table => |*t| {
                        if (self.inline_map.get(table_name)) |_| {
                            self.err.writeErrorMsg(
                                "(Parser): inline table '{s}' can't be updated after declaration.",
                                .{table_name},
                            );
                            return Error.InlineTableUpdate;
                        }
                        temp = t;
                    },
                    .TablesArray => |ta| {
                        debug.assert(ta.len > 0);
                        temp = &ta[ta.len - 1];
                    },
                    else => {
                        self.err.writeErrorMsg(
                            "(Parser): key {s} is neither a table nor an arrays of tables",
                            .{table_name},
                        );
                        return Error.DuplicateKey;
                    },
                }
            } else {
                var new_table = dt.TomlTable.init(self.arena.allocator());
                try new_table.ensureTotalCapacity(opt.INITIAL_HASHMAP_SIZE);
                try temp.put(
                    table_name,
                    dt.TomlValue{ .Table = new_table },
                );
                try self.implicit_map.put(table_name, {});
                temp = &temp.getPtr(table_name).?.Table;
            }
        }
        return temp;
    }

    /// Insert the value into the current toml context (Table or Array) and return a pointer to that value.
    fn putValue(
        self: *Self,
        value: *dt.TomlValue,
        key_path: *common.DynArray(dt.Key),
    ) (mem.Allocator.Error || Parser.Error)!*dt.TomlValue {
        switch (self.state.context) {
            .Table => {
                const tbl: *dt.TomlTable = @alignCast(@ptrCast(self.state.target));
                const key = self.state.key;
                // we need to handle dotted keys "a.b.c";
                const dest_table = try self.walkKeyPath(tbl, key_path.data());
                key_path.clearContent();
                if (dest_table.contains(key)) {
                    self.err.writeErrorMsg("(Parser): redefinition of key '{s}'", .{key});
                    return Error.DuplicateKey;
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

    fn createTable(
        self: *Self,
        header_path: *common.DynArray(dt.Key),
    ) (mem.Allocator.Error || Parser.Error)!*dt.TomlTable {
        var new_table = dt.TomlTable.init(self.arena.allocator());
        try new_table.ensureTotalCapacity(opt.INITIAL_HASHMAP_SIZE);
        var tv = dt.TomlValue{ .Table = new_table };
        switch (self.state.context) {
            .Table => {
                const key = self.state.key;
                var outter: *dt.TomlTable = @alignCast(@ptrCast(self.state.target));
                // we need to handle dotted keys "a.b.c";
                outter = try self.walkHeaderPath(outter, header_path.data());
                header_path.clearContent();
                if (outter.getPtr(key)) |value| {
                    switch (value.*) {
                        .Table => |*table| {
                            // possibly a duplicate key
                            if (self.implicit_map.contains(key)) {
                                // make it explicit
                                _ = self.implicit_map.remove(key);
                                tv.Table.deinit();
                                return table;
                            } else {
                                self.err.writeErrorMsg(
                                    "(Parser): redefinition of table '{s}'",
                                    .{key},
                                );
                                return Error.DuplicateKey;
                            }
                        },
                        else => {
                            self.err.writeErrorMsg(
                                "(Parser): redefinition of key '{s}'",
                                .{key},
                            );
                            return Error.DuplicateKey;
                        },
                    }
                } else {
                    try outter.put(key, tv);
                    return &outter.getPtr(key).?.Table;
                }
            },
            .Array => {
                var a: *TomlValueArray = @alignCast(@ptrCast(self.state.target));
                try a.append(tv);
                return &a.getLastOrNull().?.Table;
            },
        }
    }

    fn createTablesArray(
        self: *Self,
        header_path: *common.DynArray(dt.Key),
    ) (mem.Allocator.Error || Parser.Error)!*dt.TomlTable {
        debug.assert(self.state.context == ParserContext.Table);
        const outter = try self.walkHeaderPath(&self.root, header_path.data());
        header_path.clearContent();
        var tbl_array = if (outter.getPtr(self.state.key)) |value| blk: {
            switch (value.*) {
                .TablesArray => |old_array| {
                    // update
                    _ = outter.remove(self.state.key);
                    const success = self.arena
                        .allocator()
                        .resize(old_array, old_array.len + 1);

                    if (!success) {
                        const new_array = try self.arena
                            .allocator()
                            .alloc(
                            dt.TomlTable,
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
                    self.err.writeErrorMsg(
                        "(Parser): attempt to redefine '{s}' as an array of tables.",
                        .{self.state.key},
                    );
                    return Error.DuplicateKey;
                },
            }
        } else try self.arena
            .allocator()
            .alloc(dt.TomlTable, 1);

        errdefer self.arena
            .allocator()
            .free(tbl_array);

        var new_table = dt.TomlTable.init(self.arena.allocator());
        try new_table.ensureTotalCapacity(opt.INITIAL_HASHMAP_SIZE);
        tbl_array[tbl_array.len - 1] = new_table;
        const value = dt.TomlValue{ .TablesArray = tbl_array };
        try outter.put(self.state.key, value);
        return &tbl_array[tbl_array.len - 1];
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
