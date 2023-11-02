const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const debug = std.debug;
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const err = @import("error.zig");
const defs = @import("defs.zig");
const Token = @import("token.zig").Token;
const ParserError = err.ParserError;
const ErrorContext = err.ErrorContext;
const Allocator = mem.Allocator;
const TomlTable = types.Table;
const TomlArray = types.Array;
const ArrayList = std.ArrayList;

pub const Parser = struct {
    allocator: Allocator,
    __lex: lexer.Lexer,
    err_ctx: ErrorContext,
    pair: struct {
        key: types.Key,
        val: types.Value,
    },
    table_path: ArrayList([]const u8),
    root_table: TomlTable,
    active_table: *TomlTable,
    const Self = @This();
    // TOML allows quotted empty key.
    // To avoid collision we will use a sequence of bytes
    // forbidden by toml specification.
    const BLANK_KEY = [5]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };

    /// Caller should deinit when done.
    /// # Parameters
    /// `src`: a pointer to the stream to read from.
    /// 'allocator': the allocator to be used by the parser.
    pub fn init(src: *io.StreamSource, allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .__lex = lexer.Lexer.init(src),
            .pair = .{
                .key = types.Key.init(allocator),
                .val = undefined,
            },
            .err_ctx = ErrorContext.init(allocator),
            .table_path = ArrayList([]const u8).init(allocator),
            .root_table = TomlTable.init(allocator, false),
            // set when we start parsing.
            .active_table = undefined,
        };
    }

    /// Frees all the allocated memory by the parser.
    /// using the parser after calling this function
    /// causes undefined behaviour
    pub fn deinit(self: *Self) void {
        // Deinit the pairs.
        self.pair.key.deinit();
        self.clearTablePath();
        self.table_path.deinit();
        self.err_ctx.deinit();
        self.root_table.deinit();
    }

    /// Append a new key to the table_path,
    /// # Parameters
    /// `key`: the key to store.
    fn appendToTablePath(self: *Self, key: []const u8) ParserError!void {
        if (self.table_path.items.len == defs.MAX_NESTTING_LEVEL) {
            return self.err_ctx.reportError(
                ParserError.NesttingError,
                defs.ERROR_NESSTING,
                .{ self.__lex.line, self.__lex.pos },
            );
        }
        self.table_path.append(key) catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };
    }

    /// Frees the slices inside the table_path.
    fn clearTablePath(self: *Self) void {
        // Free any remaining keys.
        // this loop would only run if the parser
        // encountred and error in the stream.
        for (self.table_path.items) |k| {
            // Avoid double free by checking the len
            // variable.
            if (k.len != 0) {
                self.allocator.free(k);
            }
        }
    }

    /// Updates the active_table by walking
    /// the table_path.
    fn walkTablePath(self: *Self) ParserError!void {
        for (self.table_path.items, 0..self.table_path.items.len) |*k, i| {
            errdefer {
                // free all remaining keys.
                for (i..self.table_path.items.len) |j| {
                    self.allocator.free(self.table_path.items[j]);
                }
                // Reset.
                self.table_path.clearRetainingCapacity();
            }
            if (self.checkKeyDup(k.*)) |v| {
                switch (v.*) {
                    .Table => |*table| {
                        if (table.implicit) {
                            table.implicit = false;
                            self.active_table = table;
                        } else {
                            return self.err_ctx.reportError(
                                ParserError.DupKey,
                                defs.ERROR_DUP_KEY,
                                .{ self.__lex.line - 1, self.__lex.pos, k.* },
                            );
                        }
                    },
                    .TablesArray => |*a| {
                        self.active_table = a.ptrAtMut(a.size() - 1);
                    },
                    else => {
                        return self.err_ctx.reportError(
                            ParserError.DupKey,
                            defs.ERROR_DUP_KEY,
                            .{ self.__lex.line - 1, self.__lex.pos, k.* },
                        );
                    },
                }
                // Free unused keys.
                self.allocator.free(k.*);
                // In case of an error we can avoid double free
                // by setting the len property, and checking it
                // when deinitializing.
                k.len = 0;
            } else {
                self.active_table = try self.insertSubTable(k.*, true);
            }
        }
        // Reset the arralist len so it can be reused
        self.table_path.clearRetainingCapacity();
    }

    /// Inserts a subtable in the current active_table
    /// and return a pointer to it.
    fn insertSubTable(self: *Self, key: []const u8, implicit: bool) ParserError!*TomlTable {
        var value = types.Value{ .Table = TomlTable.init(self.allocator, implicit) };
        errdefer value.Table.deinit();
        self.active_table.put(key, value) catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };
        return &self.active_table.get_mut(key).?.Table;
    }

    /// Checks if the current key is a duplicate in the active_table.
    inline fn checkKeyDup(self: *Self, key: []const u8) ?*types.Value {
        return self.active_table.get_mut(key);
    }

    /// Parse the stream and return a poniter to
    /// the resulting table.
    pub fn parse(self: *Self) ParserError!*const TomlTable {
        self.active_table = &self.root_table;
        self.table_path.ensureTotalCapacity(defs.MAX_NESTTING_LEVEL) catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };
        self.err_ctx.resize(defs.INITAL_ERROR_BUFFER_LEN) catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };

        // Read until end of stream.
        var token: Token = undefined;
        while (true) {
            self.__lex.nextToken(&token);
            switch (token.cntxt.type) {
                .EOS => break,
                .EOL => continue,
                .LBracket => {
                    try self.parseTableHeader(&token);
                },
                .IdentStart, .String => {
                    try self.parseKeyValue(&token);
                    self.__lex.nextToken(&token);
                    if (token.cntxt.type != .EOL) {
                        return self.err_ctx.reportError(
                            ParserError.BadSyntax,
                            defs.ERROR_BAD_SYNTAX,
                            .{
                                token.cntxt.line,
                                token.cntxt.pos,
                                "Expected new line after key/value pair.",
                            },
                        );
                    }
                },
                else => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            token.cntxt.line,
                            token.cntxt.pos,
                            "Unexpected token at the root level.",
                        },
                    );
                },
            }
        }
        return &self.root_table;
    }

    pub inline fn errorMsg(self: *const Self) []const u8 {
        return self.err_ctx.errorMsg();
    }

    fn parseKey(self: *Self, t: *Token) !void {
        try self.pair.key.ensureTotalCapacity(defs.INITAL_KEY_LEN);
        if (t.cntxt.type == .String) {
            switch (t.c) {
                '\'' => try self.__lex.nextStringSQ(&self.pair.key, &self.err_ctx, true),
                '"' => try self.__lex.nextStringDQ(&self.pair.key, &self.err_ctx, true),
                else => unreachable,
            }
            // If the key is empty ""
            if (self.pair.key.items.len == 0) {
                _ = try self.pair.key.writer().write(&Parser.BLANK_KEY);
            }
        } else {
            try self.pair.key.append(t.c);
            try self.__lex.nextBareKey(&self.pair.key);
        }
    }

    fn parseValue(self: *Self, t: *Token) ParserError!void {
        switch (t.cntxt.type) {
            .String => self.parseString(t.c) catch |erro| {
                switch (erro) {
                    Allocator.Error.OutOfMemory => {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    },
                    else => return erro,
                }
            },
            .IdentStart => try self.parsePrimitiveValue(t.c),
            .LBrace => { // inl_table
                var tab = TomlTable.init(self.allocator, false);
                errdefer tab.deinit();
                const currtab = self.active_table;
                self.active_table = &tab;
                try self.parseInlineTable(t);
                self.active_table = currtab;
                self.pair.val = types.Value{ .Table = tab };
            },
            .LBracket => { // array
                var arry = TomlArray(types.Value).init(self.allocator);
                errdefer arry.deinit();
                try self.parseArry(&arry, t);
                self.pair.val = types.Value{ .Array = arry };
            },
            else => {
                return self.err_ctx.reportError(
                    ParserError.BadValue,
                    defs.ERROR_BAD_VALUE,
                    .{ t.cntxt.line, t.cntxt.pos },
                );
            },
        }
    }

    /// Parse a bare key from the stream.
    fn parseKeyValue(self: *Self, t: *Token) ParserError!void {
        while (true) {
            self.parseKey(t) catch |erro| {
                switch (erro) {
                    Allocator.Error.OutOfMemory => {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    },
                    else => return erro,
                }
            };
            self.__lex.nextToken(t);
            // Decision
            switch (t.cntxt.type) {
                .Equal => break,
                .Dot => {
                    const key = self.pair.key.toOwnedSlice() catch {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    };
                    errdefer self.allocator.free(key);
                    try self.appendToTablePath(key);
                    self.__lex.nextToken(t);
                    if (t.cntxt.type != .IdentStart and t.cntxt.type != .String) {
                        return self.err_ctx.reportError(
                            ParserError.BadSyntax,
                            defs.ERROR_BAD_SYNTAX,
                            .{
                                t.cntxt.line,
                                t.cntxt.pos,
                                "Expected key name after `.`",
                            },
                        );
                    }
                    continue;
                },
                else => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Unexpected token.",
                        },
                    );
                },
            }
        }

        // Save the current table pointer.
        const curr_tab = self.active_table;
        // Reset when done.
        defer self.active_table = curr_tab;

        try self.walkTablePath();
        if (self.checkKeyDup(self.pair.key.items) != null) {
            return self.err_ctx.reportError(
                ParserError.DupKey,
                defs.ERROR_DUP_KEY,
                .{ self.__lex.line, self.__lex.pos, self.pair.key.items },
            );
        }

        const key = self.pair.key.toOwnedSlice() catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };

        errdefer self.allocator.free(key);

        self.__lex.nextToken(t);
        try self.parseValue(t);

        errdefer types.freeValue(&self.pair.val, self.allocator);
        self.active_table.put(key, self.pair.val) catch {
            return self.err_ctx.reportError(
                ParserError.OutOfMemory,
                defs.ERROR_OUT_OF_MEMORY,
                .{},
            );
        };
    }

    /// Parse the next value (used for bool,integer,float,timestamp).
    fn parsePrimitiveValue(self: *Self, start: u8) ParserError!void {
        self.__lex.nextValue(&self.pair.val, start) catch {
            return self.err_ctx.reportError(
                ParserError.BadValue,
                defs.ERROR_BAD_VALUE,
                .{ self.__lex.line, self.__lex.pos },
            );
        };
    }

    /// Parse the next string.
    fn parseString(self: *Self, delim: u8) !void {
        // Hopefully enough.
        var s = try types.String.initCapacity(self.allocator, defs.INITAL_STRING_LEN);
        errdefer s.deinit();

        if (delim == '\'') {
            try self.__lex.nextStringSQ(&s, &self.err_ctx, false);
        } else {
            try self.__lex.nextStringDQ(&s, &self.err_ctx, false);
        }

        const slice = try s.toOwnedSlice();
        self.pair.val = types.Value{
            .String = slice,
        };
    }

    /// Parse the next Table header.
    fn parseTableHeader(self: *Self, t: *Token) !void {
        self.active_table = &self.root_table;
        var is_arrytab = false;
        self.__lex.nextToken(t);
        while (t.cntxt.type != .RBracket) {
            switch (t.cntxt.type) {
                .IdentStart, .String => {
                    try self.parseKey(t);
                    self.__lex.nextToken(t);
                    // Decision.
                    if (t.cntxt.type == .Dot) {
                        const key = try self.pair.key.toOwnedSlice();
                        errdefer self.allocator.free(key);
                        try self.appendToTablePath(key);
                        self.__lex.nextToken(t);
                        if (t.cntxt.type != .IdentStart and t.cntxt.type != .String) {
                            return self.err_ctx.reportError(
                                ParserError.BadSyntax,
                                defs.ERROR_BAD_SYNTAX,
                                .{
                                    t.cntxt.line,
                                    t.cntxt.pos,
                                    "Expected key name after `.`",
                                },
                            );
                        }
                    }
                },
                .LBracket => {
                    if (!is_arrytab) {
                        is_arrytab = true;
                    } else {
                        return self.err_ctx.reportError(
                            ParserError.BadSyntax,
                            defs.ERROR_BAD_SYNTAX,
                            .{
                                t.cntxt.line,
                                t.cntxt.pos,
                                "Expected a key found '['",
                            },
                        );
                    }
                    self.__lex.nextToken(t);
                },
                else => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Unexpected token.",
                        },
                    );
                },
            }
        }

        if (is_arrytab) {
            self.__lex.nextToken(t);
            if (t.cntxt.type != .RBracket) {
                return self.err_ctx.reportError(
                    ParserError.BadSyntax,
                    defs.ERROR_BAD_SYNTAX,
                    .{
                        t.cntxt.line,
                        t.cntxt.pos,
                        "Expected `]`",
                    },
                );
            }
        }

        try self.walkTablePath();

        if (!is_arrytab) {
            if (self.checkKeyDup(self.pair.key.items)) |val| {
                switch (val.*) {
                    .Table => |*tab| {
                        if (!tab.implicit) {
                            return self.err_ctx.reportError(
                                ParserError.DupKey,
                                defs.ERROR_DUP_TABLE,
                                .{ self.__lex.line, self.__lex.pos, self.pair.key.items },
                            );
                        }
                        tab.implicit = false;
                        self.active_table = tab;
                        self.pair.key.clearRetainingCapacity();
                    },
                    else => {
                        return self.err_ctx.reportError(
                            ParserError.DupKey,
                            defs.ERROR_DUP_KEY,
                            .{ self.__lex.line, self.__lex.pos, self.pair.key.items },
                        );
                    },
                }
            } else {
                const key = try self.pair.key.toOwnedSlice();
                errdefer self.allocator.free(key);
                self.active_table = try self.insertSubTable(key, false);
            }
        } else {
            if (self.checkKeyDup(self.pair.key.items)) |val| {
                switch (val.*) {
                    .TablesArray => |*a| {
                        try a.append(TomlTable.init(self.allocator, false));
                        self.active_table = a.ptrAtMut(a.size() - 1);
                        self.pair.key.clearRetainingCapacity();
                    },
                    else => {
                        return self.err_ctx.reportError(
                            ParserError.DupKey,
                            defs.ERROR_DUP_KEY,
                            .{ self.__lex.line, self.__lex.pos, self.pair.key.items },
                        );
                    },
                }
            } else {
                const key = try self.pair.key.toOwnedSlice();
                errdefer self.allocator.free(key);
                var array = TomlArray(TomlTable).init(self.allocator);
                try array.append(TomlTable.init(self.allocator, false));
                try self.active_table.put(key, types.Value{ .TablesArray = array });
                self.active_table = array.ptrAtMut(array.size() - 1);
            }
        }
        self.__lex.nextToken(t);
        if (t.cntxt.type != .EOL) {
            return self.err_ctx.reportError(
                ParserError.BadSyntax,
                defs.ERROR_BAD_SYNTAX,
                .{
                    t.cntxt.line,
                    t.cntxt.pos,
                    "Expected a new line after table header.",
                },
            );
        }
    }

    fn parseInlineTable(self: *Self, t: *Token) ParserError!void {
        self.__lex.nextToken(t);
        while (true) {
            switch (t.cntxt.type) {
                .EOS => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Reached end of stream before closing the table '}'.",
                        },
                    );
                },
                .EOL => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Newline isn't allowed inside inline table.",
                        },
                    );
                },
                .RBrace => {
                    // DONE.
                    break;
                },
                .IdentStart, .String => {
                    try self.parseKeyValue(t);
                    self.__lex.nextToken(t);
                },
                .Comma => {
                    self.__lex.nextToken(t);
                    if (t.cntxt.type != .String and t.cntxt.type != .IdentStart) {
                        return self.err_ctx.reportError(
                            ParserError.BadSyntax,
                            defs.ERROR_BAD_SYNTAX,
                            .{ t.cntxt.line, t.cntxt.pos, "Expected a key name after `,`" },
                        );
                    }
                },
                else => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Unexpected token.",
                        },
                    );
                },
            }
        }
    }

    fn parseArry(self: *Self, arry: *TomlArray(types.Value), t: *Token) ParserError!void {
        while (true) {
            self.__lex.nextToken(t);
            switch (t.cntxt.type) {
                .EOS => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Reached end of stream before closing the array ']'.",
                        },
                    );
                },
                .EOL, .Comma => {
                    // self.__lex.nextToken(t);
                },
                .RBracket => {
                    // DONE.
                    break;
                },
                .IdentStart, .String => {
                    try self.parseValue(t);
                    arry.append(self.pair.val) catch {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    };
                    // self.__lex.nextToken(t);
                },
                .LBrace => {
                    var tab = TomlTable.init(self.allocator, false);
                    errdefer tab.deinit();
                    const currtab = self.active_table;
                    self.active_table = &tab;
                    try self.parseInlineTable(t);
                    self.active_table = currtab;
                    arry.append(types.Value{ .Table = tab }) catch {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    };
                },
                .LBracket => {
                    var inner_arry = TomlArray(types.Value).init(self.allocator);
                    errdefer inner_arry.deinit();
                    try self.parseArry(&inner_arry, t);
                    arry.append(types.Value{ .Array = inner_arry }) catch {
                        return self.err_ctx.reportError(
                            ParserError.OutOfMemory,
                            defs.ERROR_OUT_OF_MEMORY,
                            .{},
                        );
                    };
                },
                else => {
                    return self.err_ctx.reportError(
                        ParserError.BadSyntax,
                        defs.ERROR_BAD_SYNTAX,
                        .{
                            t.cntxt.line,
                            t.cntxt.pos,
                            "Unexpected token.",
                        },
                    );
                },
            }
        }
    }
};
