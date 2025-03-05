const std = @import("std");
const common = @import("common.zig");
const utf8 = @import("utf8.zig");
const opt = @import("build_options");

const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;
const log = std.log;
const debug = std.debug;

const Stack = std.ArrayList;

// NOTE: for all strings and keys tokens the value won't contain
// the delimiters (`'`, `"`...etc), for numbers such as integers and floats
// it only validates that they don't contain any non permissable characters,
// the parser should make sure the values are valid for the type.
pub const TokenTag = enum(i8) {
    Error = -1,
    EndOfStream = 0, // End of Stream.
    Key,
    Dot,
    // The lexer won't inlucde the newline byte or the '#' in the token value.
    Comment,
    Integer,
    Float,
    // The lexer validates that the value is either `true` or `false`.
    Boolean,
    DateTime,
    BasicString,
    // The lexer validates that the string has no newline characters.
    LiteralString,
    MultiLineBasicString,
    MultiLineLiteralString,
    ArrayStart,
    ArrayEnd,
    TableStart,
    TableEnd,
    ArrayTableStart,
    ArrayTableEnd,
    InlineTableStart,
    InlineTableEnd,
};

/// Type used to report lexer findings.
/// the value when not null points to meaningfull data (keys,values,...etc),
/// that is owned by the lexer and will be cleared withe each call to Lexer.nextToken(),
/// and therefore should be copied before use.
pub const Token = struct {
    tag: TokenTag,
    value: ?[]const u8,
    start: common.Position,
};

pub const Lexer = struct {
    input: *io.StreamSource,
    read_idx: usize, // current read index into the input.
    position: common.Position,
    // position from where we started lexing the current token.
    lex_start: common.Position,
    token_buffer: common.DynArray(u8),
    state_func_stack: Stack(?LexFuncPtr),
    err_msg: ?[]const u8,

    const Self = @This();
    const LexFuncPtr = *const fn (self: *Self, t: *Token) void;
    const ERR_MSG_GENERIC: []const u8 = "(Lexer): Encounterd an error.";
    const ERR_MSG_OUT_OF_MEMORY: []const u8 = "(Lexer): Ran out of memory.";
    const EMIT_FUNC: ?LexFuncPtr = null;
    const WHITESPACE = [2]u8{ ' ', '\t' };
    const NEWLINE = [2]u8{ '\n', '\r' };

    inline fn clearState(self: *Self) void {
        self.state_func_stack.clearRetainingCapacity();
    }

    inline fn pushStateOrThrow(self: *Self, f: ?LexFuncPtr) void {
        self.state_func_stack.append(f) catch {
            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
        };
    }

    inline fn nextState(self: *Self) ?LexFuncPtr {
        return self.state_func_stack.pop() orelse null;
    }

    /// Populates the token 't' and set the state function to **EMIT_FUNC**.
    fn emit(
        self: *Self,
        t: *Token,
        tag: TokenTag,
        value: ?[]const u8,
        pos: *const common.Position,
    ) void {
        t.* = .{ .tag = tag, .value = value, .start = pos.* };
        self.pushStateOrThrow(EMIT_FUNC);
    }

    /// Attempt to read the next unicode character in the stream
    /// and copies it to the `out` parameter.
    /// in case of an error it report the error an set the `err_msg`
    /// field on self.
    /// reaching end of stream/file isn't considered an error, the `out`
    /// parameter is instead set to a special codepoint '0xffffff';
    fn readChar(self: *Self, out: *utf8.CharUTF8) !void {
        const reader = self.input.reader();
        var len: u8 = undefined;
        var cp = utf8.readUTF8Codepoint(reader, &len);

        if (cp == utf8.UTF8_ERROR) {
            self.reportError("(Lexer): found invalid utf8 codepoint", .{});
            return error.InvalidCodepoint;
        }

        self.read_idx += len;

        if (cp == '\r') {
            // expect a newline character.
            cp = utf8.readUTF8Codepoint(reader, &len);
            if (cp != '\n') {
                self.reportError(
                    "(Lexer): carriage return should be followed by a newline character.",
                    .{},
                );
                return error.BadEOL;
            }

            self.read_idx += 1;
            self.position.line += 1;
            self.position.column = 0;
        } else if (common.isNewLine(cp)) {
            self.position.line += 1;
            self.position.column = 0;
        }

        out.* = utf8.CharUTF8.init(cp, len);
        self.position.column += 1;
    }

    /// Reads and return the next byte in the stream
    /// if it encounters and an end of steam an error is returned.
    /// this function makes sure carriage **\r** is followed by a line feed
    /// **\n** or it returns an error.
    fn nextByte(self: *Self) !u8 {
        const reader = self.input.reader();
        var b = try reader.readByte();

        if (b == '\r') {
            // expect a newline character.
            const c = reader.readByte() catch 0x00;
            if (c != '\n') {
                // rewind so we can keep returning error
                // on the next call.
                return error.BadEOL;
            }
            b = '\n';
            self.read_idx += 1;
        }

        self.read_idx += 1;
        if (b == '\n') {
            self.position.line += 1;
            self.position.column = 1;
        } else {
            self.position.column += 1;
        }
        return b;
    }

    fn nextSlice(self: *Self, out: []u8) !usize {
        const r = self.input.reader();
        const count = r.read(out) catch |err| {
            return err;
        };
        self.read_idx += count;
        for (0..count) |i| {
            if (out[i] == '\r' and out[i] != '\n') {
                return error.BadEOL;
            }

            if (out[i] == '\n') {
                self.position.line += 1;
                self.position.column = 1;
            } else {
                self.position.column += 1;
            }
        }
        return count;
    }

    /// Consume the next byte only if it is equal to the `predicate`
    /// otherwise it does nothing.
    /// success is reported through the return value.
    fn consumeByte(self: *Self, predicate: u8) bool {
        const b = self.nextByte() catch {
            return false;
        };

        if (b == predicate) {
            return true;
        } else {
            self.unReadNByte(1);
            return false;
        }
    }

    /// Reads ahead in the stream and ignore any byte in `bytes_to_skip`.
    fn skipBytes(self: *Self, bytes_to_skip: []const u8) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): Expected a newline after carriage return",
                        .{},
                    );
                }
                return;
            };

            var skip = false;
            for (bytes_to_skip) |predicate| {
                skip = skip or (b == predicate);
            }

            if (!skip) {
                break;
            }
        }
        self.unReadNByte(1);
    }

    fn unReadNByte(self: *Self, n: usize) void {
        if (self.read_idx >= n) {
            self.read_idx -= n;
            self.input.seekTo(self.read_idx) catch unreachable;
        }
    }

    fn lexRoot(self: *Self, t: *Token) void {
        _ = t;
        var c: utf8.CharUTF8 = undefined;
        self.readChar(&c) catch return;

        if (common.isControl(c.codepoint)) {
            self.reportError(
                "(Lexer): Stream contains control character '0x{x:0>2}'",
                .{c.codepoint},
            );
            return;
        } else if (common.isWhiteSpace(c.codepoint) or
            common.isNewLine(c.codepoint))
        {
            self.skipBytes(&(WHITESPACE ++ NEWLINE));
            self.pushStateOrThrow(lexRoot);
            return;
        }

        switch (c.codepoint) {
            utf8.EOS => {},
            '#' => {
                self.pushStateOrThrow(lexRoot);
                self.pushStateOrThrow(lexComment);
            },
            '[' => {
                self.pushStateOrThrow(lexTableHeaderStart);
            },
            else => {
                self.unReadNByte(c.len);
                self.pushStateOrThrow(lexKeyValueEnd);
                self.lexKey();
            },
        }
    }

    /// Lexes an entire comment up to the newline character.
    /// the token value is not populated by the comment text,
    /// but rather set to null.
    /// assumes the character '#' at the begining of the comment is already
    /// consumed.
    fn lexComment(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        var c: utf8.CharUTF8 = undefined;
        while (true) {
            self.readChar(&c) catch return;

            if (common.isControl(c.codepoint)) {
                self.reportError(
                    "(Lexer): control character '{u}' not allowed in comments",
                    .{c.codepoint},
                );
                return;
            }

            if (common.isNewLine(c.codepoint) or c.codepoint == utf8.EOS) {
                break;
            }

            if (opt.EMIT_COMMENT_TOKEN) {
                self.token_buffer.appendSlice(c.slice()) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                };
            }
        }

        if (opt.EMIT_COMMENT_TOKEN) {
            self.emit(t, .Comment, self.token_buffer.data(), &self.lex_start);
        }
    }

    fn lexTableHeaderStart(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        self.pushStateOrThrow(lexTableHeaderEnd);
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                self.reportError(
                    "(Lexer): Expected a newline after carriage return",
                    .{},
                );
            } else {
                self.reportError(
                    "(Lexer): expected closing bracket ']' before end of stream",
                    .{},
                );
            }
            return;
        };
        if (b == '[') {
            self.pushStateOrThrow(lexArrayTableEnd);
            self.lexTableName();
            // self.pushStateOrThrow(lexTableName);
            self.emit(t, .ArrayTableStart, null, &self.lex_start);
        } else {
            self.unReadNByte(1);
            self.pushStateOrThrow(lexTableEnd);
            self.lexTableName();
            // self.pushStateOrThrow(lexTableName);
            self.emit(t, .TableStart, null, &self.lex_start);
        }
    }

    /// Asserts newline character, comment or end of stream
    /// after header [table] or [[array]].
    fn lexTableHeaderEnd(self: *Self, t: *Token) void {
        _ = t;
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                self.reportError(
                    "(Lexer): Expected a newline after carriage return",
                    .{},
                );
            }
            return;
        };
        self.pushStateOrThrow(lexRoot);
        switch (b) {
            '#' => self.pushStateOrThrow(lexComment),
            '\n' => {},
            else => self.reportError(
                "(Lexer): expected newline after table header",
                .{},
            ),
        }
    }

    fn lexTableName(self: *Self) void {
        self.skipBytes(&WHITESPACE);
        var c: utf8.CharUTF8 = undefined;
        self.readChar(&c) catch return;
        self.pushStateOrThrow(lexTableNameEnd);

        switch (c.codepoint) {
            '.', ']' => {
                self.reportError(
                    "(Lexer): unexpected symbol found within table name",
                    .{},
                );
                return;
            },
            '"', '\'' => self.lexQuottedKey(@truncate(c.codepoint)),
            else => {
                self.unReadNByte(1);
                self.pushStateOrThrow(lexBareKey);
            },
        }
    }

    fn lexTableNameEnd(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);
        var c: utf8.CharUTF8 = undefined;
        self.readChar(&c) catch return;
        switch (c.codepoint) {
            '.' => {
                self.lexTableName();
                // self.pushStateOrThrow(lexTableName);
                self.emit(t, .Dot, null, &self.position);
                return;
            },
            ']' => {
                return;
            },
            else => {
                self.reportError(
                    "(Lexer): expected closing bracket ']' or comma '.' found `{u}`",
                    .{c.codepoint},
                );
                return;
            },
        }
    }

    fn lexTableEnd(self: *Self, t: *Token) void {
        self.emit(t, .TableEnd, null, &self.position);
    }

    fn lexArrayTableEnd(self: *Self, t: *Token) void {
        if (!self.consumeByte(']')) {
            self.reportError(
                "(Lexer): expected `]` at the of Array of tables declaration",
                .{},
            );
            return;
        }
        self.emit(t, .ArrayTableEnd, null, &self.position);
    }

    /// Handles lexing a key and calls the next appropriate function
    /// this function assumes that there is at least one byte in the stream
    fn lexKey(self: *Self) void {
        self.pushStateOrThrow(lexKeyEnd);
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch return;
        switch (b) {
            '=', '.' => self.reportError(
                "(Lexer): expected a key name found '{c}' ",
                .{b},
            ),
            '"', '\'' => self.lexQuottedKey(b),
            else => {
                self.unReadNByte(1);
                self.pushStateOrThrow(lexBareKey);
            },
        }
    }

    /// Checks for key end or a dotted key.
    fn lexKeyEnd(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);

        const b = self.nextByte() catch {
            self.reportError(
                "(Lexer): expected '=' after key name",
                .{},
            );
            return;
        };

        switch (b) {
            '.' => {
                self.lexKey();
                self.emit(t, .Dot, null, &self.position);
            },
            '=' => {
                self.pushStateOrThrow(lexValue);
            },
            else => self.reportError(
                "(Lexer): expected '=' or '.' found '{c}'",
                .{b},
            ),
        }
    }

    /// Lex a bare key.
    fn lexBareKey(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        var c: utf8.CharUTF8 = undefined;
        while (true) {
            self.readChar(&c) catch return;

            if (!common.isBareKeyChar(c.codepoint)) {
                self.unReadNByte(c.len);
                break;
            }

            self.token_buffer.appendSlice(c.slice()) catch {
                // In case of an error clear the state stack and update the token
                // to an error token.
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return;
            };
        }
        self.emit(t, .Key, self.token_buffer.data(), &self.lex_start);
    }

    fn lexQuottedKey(self: *Self, delim: u8) void {
        self.lex_start = self.position;
        switch (delim) {
            '"' => self.pushStateOrThrow(lexString(.Key).lexBasicString),
            '\'' => self.pushStateOrThrow(lexString(.Key).lexLiteralString),
            else => unreachable,
        }
    }

    fn lexValue(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch {
            self.reportError(
                "(Lexer): expected a value after '='",
                .{},
            );
            return;
        };

        if (common.isDigit(b)) {
            self.unReadNByte(1);
            self.pushStateOrThrow(lexNumber);
            return;
        }

        switch (b) {
            '[' => {
                self.pushStateOrThrow(lexArrayValue);
                self.emit(t, .ArrayStart, null, &self.position);
            },
            '{' => {
                self.pushStateOrThrow(lexInlineTabValue);
                self.emit(t, .InlineTableStart, null, &self.position);
            },
            '"' => {
                if (self.consumeByte('"')) {
                    if (self.consumeByte('"')) {
                        self.pushStateOrThrow(lexMultiLineBasicString);
                        return;
                    } else {
                        self.unReadNByte(1);
                    }
                }
                self.pushStateOrThrow(lexString(.BasicString).lexBasicString);
            },
            '\'' => {
                if (self.consumeByte('\'')) {
                    if (self.consumeByte('\'')) {
                        self.pushStateOrThrow(lexMultiLineLiteralString);
                        return;
                    } else {
                        self.unReadNByte(1);
                    }
                }
                self.pushStateOrThrow(lexString(.LiteralString).lexLiteralString);
            },
            'i', 'n' => {
                self.unReadNByte(1);
                self.pushStateOrThrow(lexFloat);
            },
            '-', '+' => {
                self.token_buffer.append(b) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                };
                self.pushStateOrThrow(lexDecimalInteger);
            },
            't', 'f' => {
                self.unReadNByte(1);
                self.pushStateOrThrow(lexBoolean);
            },
            else => self.reportError(
                "(Lexer): expected a value after '=' found '{c}'",
                .{b},
            ),
        }
    }

    /// consumes and validate the newline after the key/value pair.
    fn lexKeyValueEnd(self: *Self, t: *Token) void {
        _ = t;
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                self.reportError(
                    "(Lexer): Expected a newline after carriage return",
                    .{},
                );
            }
            return;
        };
        self.pushStateOrThrow(lexRoot);
        switch (b) {
            '#' => self.pushStateOrThrow(lexComment),
            '\n' => return,
            else => self.reportError(
                "(Lexer): expected newline after key/value pair found '{c}'",
                .{b},
            ),
        }
    }

    fn lexString(comptime emit_tag: TokenTag) type {
        return struct {
            /// lex the string content between it's delimiters '"'.
            fn lexBasicString(self: *Self, t: *Token) void {
                var c: utf8.CharUTF8 = undefined;
                while (true) {
                    self.readChar(&c) catch return;

                    if (common.isNewLine(c.codepoint)) {
                        self.reportError(
                            "(Lexer): basic string can't contain a newline character '0x{X:0>2}'",
                            .{c.codepoint},
                        );
                        return;
                    }

                    if (common.isControl(c.codepoint)) {
                        self.reportError(
                            "(Lexer): control character '{u}' not allowed in basic strings",
                            .{c.codepoint},
                        );
                        return;
                    }

                    switch (c.codepoint) {
                        utf8.EOS => {
                            self.reportError(
                                "(Lexer): expected a string delimiter '\"' before end of stream",
                                .{},
                            );
                            return;
                        },
                        '"' => break,
                        '\\' => self.lexStringEscape(false) catch return,
                        else => self.token_buffer.appendSlice(c.slice()) catch {
                            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                            return;
                        },
                    }
                }
                self.emit(t, emit_tag, self.token_buffer.data(), &self.lex_start);
            }

            /// lex the string content between it's delimiters `'`.
            fn lexLiteralString(self: *Self, t: *Token) void {
                var c: utf8.CharUTF8 = undefined;
                while (true) {
                    self.readChar(&c) catch return;

                    if (common.isControl(c.codepoint)) {
                        self.reportError(
                            "(Lexer): control character '{u}' not allowed in litteral strings",
                            .{c.codepoint},
                        );
                        return;
                    }
                    if (common.isNewLine(c.codepoint)) {
                        self.reportError(
                            "(Lexer): litteral string can't contain a newline character '0x{X:0>2}'",
                            .{c.codepoint},
                        );
                        return;
                    }
                    switch (c.codepoint) {
                        utf8.EOS => {
                            self.reportError(
                                "(Lexer): expected a string delimiter `'` before end of stream",
                                .{},
                            );
                            return;
                        },
                        '\'' => break,
                        else => self.token_buffer.appendSlice(c.slice()) catch {
                            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                            return;
                        },
                    }
                }
                self.emit(t, emit_tag, self.token_buffer.data(), &self.lex_start);
            }
        };
    }

    fn lexMultiLineBasicString(self: *Self, t: *Token) void {
        var c: utf8.CharUTF8 = undefined;
        while (true) {
            self.readChar(&c) catch return;

            if (common.isControl(c.codepoint)) {
                self.reportError(
                    "(Lexer): control character '{u}' not allowed in basic strings",
                    .{c.codepoint},
                );
                return;
            }
            switch (c.codepoint) {
                utf8.EOS => {
                    self.reportError(
                        "(Lexer): expected a string delimiter \"\"\" before end of stream",
                        .{},
                    );
                    return;
                },
                '"' => {
                    if (self.consumeByte('"')) {
                        if (self.consumeByte('"')) {
                            // there are some edge cases where a multi line string
                            // could be written as: """Hello World"""""
                            // allowing for 5 '"' at the end.
                            var counter: i8 = 2;
                            while (counter > 0) {
                                const b = self.nextByte() catch break;
                                if (b != '"') {
                                    self.unReadNByte(1);
                                    break;
                                }
                                self.token_buffer.append(b) catch {
                                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                                    return;
                                };
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.unReadNByte(1);
                        }
                    }
                    self.token_buffer.append('"') catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                },
                '\\' => self.lexMultiLineStringEscape() catch return,
                else => self.token_buffer.appendSlice(c.slice()) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                },
            }
        }
        self.emit(t, .MultiLineBasicString, self.token_buffer.data(), &self.lex_start);
    }

    fn lexMultiLineLiteralString(self: *Self, t: *Token) void {
        var c: utf8.CharUTF8 = undefined;
        while (true) {
            self.readChar(&c) catch return;

            if (common.isControl(c.codepoint)) {
                self.reportError(
                    "(Lexer): control character '{u}' not allowed in basic strings",
                    .{c.codepoint},
                );
                return;
            }
            switch (c.codepoint) {
                utf8.EOS => {
                    self.reportError(
                        "(Lexer): expected a string delimiter ''' before end of stream",
                        .{},
                    );
                    return;
                },
                '\'' => {
                    if (self.consumeByte('\'')) {
                        if (self.consumeByte('\'')) {
                            // there are some edge cases where a multi line string
                            // could be written as: '''Hello World'''''
                            // allowing for 5 `'` at the end.
                            var counter: i8 = 2;
                            while (counter > 0) {
                                const b = self.nextByte() catch break;
                                if (b != '\'') {
                                    self.unReadNByte(1);
                                    break;
                                }
                                self.token_buffer.append(b) catch {
                                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                                    return;
                                };
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.unReadNByte(1);
                        }
                    }
                    self.token_buffer.append('\'') catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                },
                else => self.token_buffer.appendSlice(c.slice()) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                },
            }
        }
        self.emit(t, .MultiLineLiteralString, self.token_buffer.data(), &self.lex_start);
    }

    /// Called when encountering a string escape sequence in a multi line string.
    /// assumes '\' is already consumed
    fn lexMultiLineStringEscape(self: *Self) !void {
        var b = self.nextByte() catch {
            self.reportError(
                "(Lexer): expected an escape sequence before end of stream",
                .{},
            );
            return error.BadStringEscape;
        };

        if (common.isWhiteSpace(b)) {
            // Whitespace is allowed after line ending backslash
            self.skipBytes(&WHITESPACE);
            b = self.nextByte() catch {
                self.reportError(
                    "(Lexer): expected an escape sequence before end of stream",
                    .{},
                );
                return error.BadStringEscape;
            };

            if (common.isNewLine(b)) {
                self.token_buffer.appendSlice(&[_]u8{ '\\', b }) catch |e| {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return e;
                };
                return;
            } else {
                self.reportError(
                    "(Lexer): expected a newline after line ending backslash",
                    .{},
                );
                return error.BadStringEscape;
            }
        } else if (common.isNewLine(b)) {
            self.token_buffer.appendSlice(&[_]u8{ '\\', b }) catch |e| {
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return e;
            };
            return;
        }
        self.unReadNByte(1);

        try self.lexStringEscape(true);
    }

    /// Called when encountering a string escape sequence
    /// assumes '\' is already consumed
    /// decodes the string escapes while lexing.
    fn lexStringEscape(self: *Self, is_multiline: bool) !void {
        const b = self.nextByte() catch {
            self.reportError(
                "(Lexer): expected an escape sequence before end of stream",
                .{},
            );
            return error.BadStringEscape;
        };

        var hex: [8]u8 = undefined;

        const bytes: []const u8 = switch (b) {
            'b' => &[1]u8{0x08},
            'r' => &[1]u8{'\r'},
            'n' => &[1]u8{'\n'},
            't' => &[1]u8{'\t'},
            'f' => &[1]u8{0x0C},
            '"' => &[1]u8{'"'},
            // for multi-line strings returning 2 backslashes helps the parser
            // when trimming white space.
            '\\' => if (is_multiline) &[2]u8{ '\\', '\\' } else &[1]u8{'\\'},
            'u' => u: {
                if (!self.lexUnicodeEscape(4, &hex)) {
                    // error already reported
                    return error.BadStringEscape;
                }
                const num_written: usize = common.toUnicodeCodepoint(hex[0..4]) catch {
                    self.reportError(
                        "(Lexer): '\\u{s}' is not a valid unicode escape",
                        .{hex[0..4]},
                    );
                    return error.BasicStringEscape;
                };
                break :u hex[0..num_written];
            },
            'U' => U: {
                if (!self.lexUnicodeEscape(8, &hex)) {
                    // error already reported
                    return error.BadStringEscape;
                }
                const num_written: usize = common.toUnicodeCodepoint(hex[0..8]) catch {
                    self.reportError(
                        "(Lexer): '\\U{s}' is not a valid unicode escape",
                        .{hex[0..8]},
                    );
                    return error.BasicStringEscape;
                };
                break :U hex[0..num_written];
            },
            else => {
                self.reportError(
                    "(Lexer): bad string escape sequence, '\\{c}' | \\0x{X:0>2}",
                    .{ b, b },
                );
                return error.BadStringEscape;
            },
        };

        self.token_buffer.appendSlice(bytes) catch {
            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
            return;
        };
    }

    fn lexUnicodeEscape(self: *Self, comptime width: u8, out: []u8) bool {
        for (0..width) |i| {
            const b = self.nextByte() catch {
                self.reportError(
                    "(Lexer): expected hexadecimal digit",
                    .{},
                );
                return false;
            };

            if (!common.isHex(b)) {
                self.reportError(
                    "(Lexer): expected hexadecimal digit found {c}",
                    .{b},
                );
                return false;
            }

            out[i] = b;
        }
        return true;
    }

    /// Used to determine how the number value should be processed.
    /// assumes there is at least a byte in the stream.
    fn lexNumber(self: *Self, t: *Token) void {
        //TODO: logic for lexing number (floats and integers)
        // could use a bit of refactoring.

        // guaranteed digit.
        var b = self.nextByte() catch unreachable;
        self.token_buffer.append(b) catch {
            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
            return;
        };

        if (b == '0') {
            // possibly a base speceific number.
            const base = self.nextByte() catch 0x00;
            switch (base) {
                'b' => {
                    self.token_buffer.append(base) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexBinaryInteger);
                    return;
                },
                'o' => {
                    self.token_buffer.append(base) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexOctalInteger);
                    return;
                },
                'x' => {
                    self.token_buffer.append(base) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexHexInteger);
                    return;
                },
                0x00 => {},
                else => self.unReadNByte(1),
            }
        }

        while (true) {
            b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                };
                continue;
            }

            switch (b) {
                '.', 'e', 'E' => {
                    self.token_buffer.append(b) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexFloat);
                    return;
                },
                '-', ':' => {
                    self.token_buffer.append(b) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexDateTime);
                    return;
                },
                else => {
                    self.unReadNByte(1);
                    break;
                },
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0b is already consumed
    fn lexBinaryInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (!common.isBinary(b) and b != '_') {
                self.unReadNByte(1);
                break;
            }

            self.token_buffer.append(b) catch {
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0o is already consumed
    fn lexOctalInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (!common.isOctal(b) and b != '_') {
                self.unReadNByte(1);
                break;
            }

            self.token_buffer.append(b) catch {
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDecimalInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                };
                continue;
            }

            switch (b) {
                '.', 'e', 'E', 'i', 'n' => {
                    // switch to lexing a float
                    self.unReadNByte(1);
                    self.pushStateOrThrow(lexFloat);
                    return;
                },
                '-', ':' => {
                    self.token_buffer.append(b) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    self.pushStateOrThrow(lexDateTime);
                    return;
                },
                else => {
                    self.unReadNByte(1);
                    break;
                },
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0x is already consumed
    fn lexHexInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (!common.isHex(b) and b != '_') {
                self.unReadNByte(1);
                break;
            }

            self.token_buffer.append(b) catch {
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    // lex float number
    fn lexFloat(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            if (common.isDigit(b)) {
                self.token_buffer.append(b) catch {
                    self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                    return;
                };
                continue;
            }

            switch (b) {
                '-', '+', '_', 'e', 'E', '.' => {
                    self.token_buffer.append(b) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    continue;
                },
                'i' => {
                    if (!self.consumeByte('n') or !self.consumeByte('f')) {
                        self.reportError("(Lexer): Invalid float", .{});
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'i', 'n', 'f' }) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    break;
                },
                'n' => {
                    if (!self.consumeByte('a') or !self.consumeByte('n')) {
                        self.reportError("(Lexer): Invalid float", .{});
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'n', 'a', 'n' }) catch {
                        self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                        return;
                    };
                    break;
                },
                else => {
                    self.unReadNByte(1);
                    break;
                },
            }
        }
        self.emit(t, .Float, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDateTime(self: *Self, t: *Token) void {
        while (true) {
            var b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): bad newline character.",
                        .{},
                    );
                    return;
                }
                break;
            };

            b = switch (b) {
                '0'...'9',
                ':',
                'T',
                'Z',
                '+',
                '-',
                '.',
                => b,
                'z' => 'Z',
                ' ', 't' => {
                    // in case of a space ' ' we need to read ahead
                    // and make sure this isn't the end.
                    const c = self.nextByte() catch |err| {
                        if (err == error.BadEOL) {
                            self.reportError(
                                "(Lexer): bad newline character.",
                                .{},
                            );
                            return;
                        }
                        break;
                    };
                    if (common.isDigit(c)) {
                        self.token_buffer.appendSlice(&.{ 'T', c }) catch {
                            self.reportError(
                                ERR_MSG_OUT_OF_MEMORY,
                                .{},
                            );
                            return;
                        };
                        continue;
                    } else {
                        // we are done.
                        self.unReadNByte(1);
                        break;
                    }
                },
                else => {
                    self.unReadNByte(1);
                    break;
                },
            };
            self.token_buffer.append(b) catch {
                self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
                return;
            };
        }

        self.emit(t, .DateTime, self.token_buffer.data(), &self.lex_start);
    }

    /// expects a boolean string
    /// assumes there is at least a byte in stream.
    fn lexBoolean(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        const initial = self.nextByte() catch unreachable;
        self.unReadNByte(1);
        var boolean: [5]u8 = undefined;
        var count: usize = 0;
        switch (initial) {
            't' => {
                count = self.nextSlice(boolean[0..4]) catch return;
                if (count != 4) {
                    self.reportError(
                        "(Lexer): unexpected end of stream",
                        .{},
                    );
                    return;
                }
                if (!mem.eql(u8, boolean[0..4], "true")) {
                    self.reportError(
                        "(Lexer): Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    return;
                }
            },
            'f' => {
                count = self.nextSlice(&boolean) catch return;
                if (count != 5) {
                    self.reportError(
                        "(Lexer): unexpected end of stream",
                        .{},
                    );
                    return;
                }
                if (!mem.eql(u8, &boolean, "false")) {
                    self.reportError(
                        "(Lexer): Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    return;
                }
            },
            else => unreachable,
        }

        self.token_buffer.appendSlice(boolean[0..count]) catch {
            self.reportError(ERR_MSG_OUT_OF_MEMORY, .{});
            return;
        };

        self.emit(t, .Boolean, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes the starting bracket '[' was already consumed.
    fn lexArrayValue(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): Expected a newline after carriage return",
                        .{},
                    );
                } else {
                    self.reportError(
                        "(Lexer): expected array closing delimiter ']' before end of stream",
                        .{},
                    );
                }
                return;
            };

            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&(WHITESPACE ++ NEWLINE));
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexArrayValue);
                    self.pushStateOrThrow(lexComment);
                    return;
                },
                ',' => {
                    self.reportError(
                        "(Lexer): Unexpected comma ',' inside array",
                        .{},
                    );
                    return;
                },
                ']' => break,
                else => {
                    self.unReadNByte(1);
                    self.pushStateOrThrow(lexArrayValueEnd);
                    self.pushStateOrThrow(lexValue);
                    return;
                },
            }
        }

        self.emit(t, .ArrayEnd, null, &self.lex_start);
    }

    fn lexArrayValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): Expected a newline after carriage return",
                        .{},
                    );
                } else {
                    self.reportError(
                        "(Lexer): expected array closing delimiter ']' before end of stream",
                        .{},
                    );
                }
                return;
            };

            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&(WHITESPACE ++ NEWLINE));
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexArrayValueEnd);
                    self.pushStateOrThrow(lexComment);
                    return;
                },
                ',' => {
                    self.pushStateOrThrow(lexArrayValue);
                    return;
                },
                ']' => break,
                else => {
                    self.reportError(
                        "(Lexer): expected comma ',' or array closing bracket ']' found {c}",
                        .{b},
                    );
                },
            }
        }
        self.emit(t, .ArrayEnd, null, &self.lex_start);
    }

    /// assumes '{' is already consumed.
    fn lexInlineTabValue(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): Expected a newline after carriage return",
                        .{},
                    );
                } else {
                    self.reportError(
                        "(Lexer): expected array closing delimiter '}}' before end of stream",
                        .{},
                    );
                }
                return;
            };

            if (common.isNewLine(b)) {
                self.reportError(
                    "(Lexer): Newline not allowed inside inline tables.",
                    .{},
                );
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&WHITESPACE);
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexInlineTabValue);
                    self.pushStateOrThrow(lexComment);
                    return;
                },
                ',' => {
                    self.reportError(
                        "(Lexer): Unexpected comma ',' inside inline table.",
                        .{},
                    );
                    return;
                },
                '}' => break,
                else => {
                    self.unReadNByte(1);
                    self.pushStateOrThrow(lexInlineTabValueEnd);
                    self.lexKey();
                    // self.pushStateOrThrow(lexKey);
                    return;
                },
            }
        }

        self.emit(t, .InlineTableEnd, null, &self.lex_start);
    }

    fn lexInlineTabValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    self.reportError(
                        "(Lexer): Expected a newline after carriage return",
                        .{},
                    );
                } else {
                    self.reportError(
                        "(Lexer): expected array closing delimiter '}}' before end of stream",
                        .{},
                    );
                }
                return;
            };

            if (common.isNewLine(b)) {
                self.reportError(
                    "(Lexer): Newline not allowed inside inline tables.",
                    .{},
                );
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&WHITESPACE);
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexInlineTabValueEnd);
                    self.pushStateOrThrow(lexComment);
                    return;
                },
                ',' => {
                    self.skipBytes(&WHITESPACE);
                    if (self.consumeByte('}')) {
                        self.reportError(
                            "(Lexer): a trailing comma ',' is not permitted after the last key/value pair in an inline table.",
                            .{},
                        );
                        return;
                    }
                    self.pushStateOrThrow(lexInlineTabValue);
                    return;
                },
                '}' => break,
                else => {
                    self.reportError(
                        "(Lexer): expected comma ',' or an inline table terminator '}}' found '{c}'",
                        .{b},
                    );
                    return;
                },
            }
        }
        self.emit(t, .InlineTableEnd, null, &self.lex_start);
    }

    /// catch all after reaching end of stream
    fn lexEndOfStreamLoop(self: *Self, t: *Token) void {
        self.pushStateOrThrow(lexEndOfStreamLoop);
        self.emit(t, .EndOfStream, null, &self.position);
    }

    fn reportError(self: *Self, comptime format: []const u8, args: anytype) void {
        self.formatError(format, args);
        self.clearState();
    }

    inline fn formatError(
        self: *Self,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.token_buffer.clearContent();
        self.token_buffer.print(format, args) catch {
            self.err_msg = Self.ERR_MSG_OUT_OF_MEMORY;
            return;
        };
        self.err_msg = self.token_buffer.data();
    }

    pub fn init(
        allocator: mem.Allocator,
        input: *io.StreamSource,
    ) mem.Allocator.Error!Self {
        var state_func_stack = try Stack(?LexFuncPtr).initCapacity(allocator, 8);
        errdefer state_func_stack.deinit();
        state_func_stack.append(lexEndOfStreamLoop) catch unreachable;
        state_func_stack.append(lexRoot) catch unreachable;
        return .{
            .input = input,
            .read_idx = 0,
            .position = .{ .line = 1, .column = 1 },
            .lex_start = .{ .line = 1, .column = 1 },
            .token_buffer = try common.DynArray(u8).initCapacity(
                allocator,
                opt.LEXER_BUFFER_SIZE,
            ),
            .state_func_stack = state_func_stack,
            .err_msg = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.token_buffer.deinit();
        self.state_func_stack.deinit();
    }

    /// Reads ahead in the stream and construct the first token it finds,
    /// the token value field if set, points to memory owned by the lexer
    /// that will be overwritten on every call, the caller should
    /// copiy the the data if needed.
    pub fn nextToken(self: *Self, t: *Token) void {
        self.token_buffer.clearContent();
        while (true) {
            if (opt.LOG_LEXER_STATE) {
                self.logState();
            }

            if (self.nextState()) |func| {
                func(self, t);
                continue;
            }

            break;
        }

        // report any error we ran into.
        if (self.err_msg) |msg| {
            self.emit(t, .Error, msg, &self.position);
        }
    }

    fn logState(self: *Self) void {
        std.debug.print("======== Lexer ==========\n", .{});
        std.debug.print("[+] Function Stack:\n", .{});
        std.debug.print("-------------------- :\n", .{});
        for (self.state_func_stack.items) |func| {
            std.debug.print("| {s} |\n", .{functionToString(func)});
            std.debug.print("-------------------- :\n", .{});
        }
        std.debug.print("[+] Stream offset: {d}\n", .{self.read_idx});
        std.debug.print("=========================\n", .{});
    }

    fn functionToString(f: ?LexFuncPtr) [*:0]const u8 {
        if (f == EMIT_FUNC) {
            return "EmitToken";
        }
        if (f == lexRoot) {
            return "lexRoot";
        }
        if (f == lexComment) {
            return "lexComment";
        }
        if (f == lexDateTime) {
            return "lexDateTime";
        }
        if (f == lexDecimalInteger) {
            return "lexDecimalInteger";
        }
        if (f == lexNumber) {
            return "lexNumber";
        }
        if (f == lexFloat) {
            return "lexFloat";
        }
        if (f == lexBareKey) {
            return "lexBareKey";
        }
        if (f == lexBoolean) {
            return "lexBoolean";
        }
        if (f == lexKeyEnd) {
            return "lexKeyEnd";
        }
        if (f == lexBinaryInteger) {
            return "lexBinaryInteger";
        }
        if (f == lexOctalInteger) {
            return "lexOctalInteger";
        }
        if (f == lexHexInteger) {
            return "lexHexInteger";
        }
        if (f == lexMultiLineBasicString) {
            return "lexMultiLineBasicString";
        }
        if (f == lexMultiLineLiteralString) {
            return "lexMultiLineLiteralString";
        }
        if (f == lexValue) {
            return "lexValue";
        }
        if (f == lexKeyValueEnd) {
            return "lexKeyValueEnd";
        }
        if (f == lexArrayValue) {
            return "lexArrayValue";
        }
        if (f == lexArrayValueEnd) {
            return "lexArrayValueEnd";
        }
        if (f == lexInlineTabValue) {
            return "lexInlineTabValue";
        }
        if (f == lexInlineTabValueEnd) {
            return "lexInlineTabValueEnd";
        }
        if (f == lexTableHeaderStart) {
            return "lexTableHeaderStart";
        }
        if (f == lexTableHeaderEnd) {
            return "lexTableHeaderEnd";
        }
        if (f == lexTableEnd) {
            return "lexTableEnd";
        }
        if (f == lexTableNameEnd) {
            return "lexTableNameEnd";
        }
        if (f == lexEndOfStreamLoop) {
            return "lexEndOfStreamLoop";
        }
        return "!!!Function Not found";
    }
};

test "lex basic" {
    const testing = std.testing;
    const src =
        \\title = "TOML Example"
    ;
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };
    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .BasicString,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
}

test "lex string" {
    const testing = std.testing;
    const src =
        \\# This is a comment
        \\my_string = 'Hello world!'
        \\my_string3 = "Hello w\u3100rld!"
    ;
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .LiteralString,
        .Key,
        .BasicString,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .Key,
        .Float,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .Boolean,
        .Key,
        .Boolean,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .DateTime,
        .Key,
        .DateTime,
        .Key,
        .DateTime,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
}

test "lex array" {
    const testing = std.testing;
    const src =
        \\numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
        \\nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
        \\string_array = [ "all", 'strings', """are the same""", '''type''' ]
        \\
        \\# Mixed-type arrays are allowed
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .ArrayStart,
        .Float,
        .Float,
        .Float,
        .Integer,
        .Integer,
        .Integer,
        .ArrayEnd,
        .Key,
        .ArrayStart,
        .ArrayStart,
        .Integer,
        .Integer,
        .ArrayEnd,
        .ArrayStart,
        .Integer,
        .Integer,
        .Integer,
        .ArrayEnd,
        .ArrayEnd,
        .Key,
        .ArrayStart,
        .BasicString,
        .LiteralString,
        .MultiLineBasicString,
        .MultiLineLiteralString,
        .ArrayEnd,
        .Key,
        .ArrayStart,
        .BasicString,
        .InlineTableStart,
        .Key,
        .BasicString,
        .Key,
        .BasicString,
        .Key,
        .BasicString,
        .InlineTableEnd,
        .ArrayEnd,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .Key,
        .InlineTableStart,
        .Key,
        .BasicString,
        .Key,
        .BasicString,
        .InlineTableEnd,
        .Key,
        .InlineTableStart,
        .Key,
        .Integer,
        .Key,
        .Integer,
        .InlineTableEnd,
        .Key,
        .InlineTableStart,
        .Key,
        .Dot,
        .Key,
        .BasicString,
        .InlineTableEnd,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
}

test "lex table" {
    const testing = std.testing;
    const src =
        \\[table-1]
        \\key1 = "some string"
        \\key2 = 123
        \\[dog."tater.man"]
        \\type.name = "pug"
        \\[ g .  h  . i ]    # same as [g.h.i]
        \\[ j . "ʞ" . 'l' ]  # same as [j."ʞ".'l']
    ;
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .TableStart,
        .Key,
        .TableEnd,
        .Key,
        .BasicString,
        .Key,
        .Integer,
        .TableStart,
        .Key,
        .Dot,
        .Key,
        .TableEnd,
        .Key,
        .Dot,
        .Key,
        .BasicString,
        .TableStart,
        .Key,
        .Dot,
        .Key,
        .Dot,
        .Key,
        .TableEnd,
        .TableStart,
        .Key,
        .Dot,
        .Key,
        .Dot,
        .Key,
        .TableEnd,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
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
    ;
    var ss = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

    var lexer = try Lexer.init(testing.allocator, &ss);
    defer lexer.deinit();
    var t: Token = undefined;
    const expected = [_]TokenTag{
        .ArrayTableStart,
        .Key,
        .ArrayTableEnd,
        .Key,
        .BasicString,
        .TableStart,
        .Key,
        .Dot,
        .Key,
        .TableEnd,
        .Key,
        .BasicString,
        .Key,
        .BasicString,
        .EndOfStream,
    };
    var count: usize = 0;
    while (true) : (count += 1) {
        lexer.nextToken(&t);
        testing.expect(t.tag != .Error) catch |e| {
            std.log.err("{s}", .{t.value.?});
            return e;
        };
        // debug.print("({s}):{?s}\n", .{ @tagName(t.tag), t.value });
        try testing.expect(t.tag == expected[count]);
        if (t.tag == .EndOfStream) {
            break;
        }
    }
}
