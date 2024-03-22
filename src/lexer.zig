const std = @import("std");
const opt = @import("build_options");
const common = @import("common.zig");

const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const log = std.log;
const debug = std.debug;

const Stack = std.ArrayList;

const LOG_LEXER_STATE = opt.LOG_LEXER_STATE;

// NOTE: for all strings and keys tokens the value won't contain
// the delimiters (`'`, `"`...etc). for numbers such as integers and floats
// it only validates that they don't contain any non permissable characters,
// the parser should make sure the values are valid for the type.
pub const TokenType = enum {
    EOS, // End of Stream.
    Key,
    Dot,
    Comment, // The lexer won't inlucde the newline byte or the '#' in the comment value.
    Integer,
    Float,
    Boolean, // The lexer validates that the value is either `true` or `false`.
    DateTime,
    BasicString,
    LiteralString, // The lexer validates that the string has no newline byte.
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
    Error,
};

/// Type used to report lexer findings.
/// the value when not null points to meaningfull data (keys,values,...etc),
/// that is owned by the lexer and will be cleared withe each call to Lexer.nextToken(),
/// and therefore should be copied before use.
pub const Token = struct {
    type: TokenType,
    value: ?[]const u8,
    start: common.Position,
};

inline fn emitToken(
    t: *Token,
    token_type: TokenType,
    value: ?[]const u8,
    pos: *const common.Position,
) void {
    t.start = pos.*;
    t.type = token_type;
    t.value = value;
}

pub const Lexer = struct {
    input: *io.StreamSource,
    index: usize, // current read index into the input.
    position: common.Position,
    lex_start: common.Position, // position from where we started lexing the current token.
    token_buffer: common.DynArray(u8),
    state_func_stack: Stack(?LexFuncPtr),

    const Self = @This();
    const LexFuncPtr = *const fn (self: *Self, t: *Token) void;
    const ERR_MSG_GENERIC: []const u8 = "Lexer: Encounterd an error.";
    const ERR_MSG_OUT_OF_MEMORY: []const u8 = "Lexer: Ran out of memory.";
    const EMIT_FUNC: ?LexFuncPtr = null;
    const WHITESPACE = [2]u8{ ' ', '\t' };
    const NEWLINE = [2]u8{ '\n', '\r' };

    inline fn clearState(self: *Self) void {
        self.state_func_stack.clearRetainingCapacity();
    }

    inline fn pushStateOrThrow(self: *Self, f: ?LexFuncPtr, t: *Token) void {
        self.state_func_stack.append(f) catch {
            emitToken(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
            self.clearState();
        };
    }

    inline fn popState(self: *Self) ?LexFuncPtr {
        return self.state_func_stack.pop();
    }

    inline fn popNState(self: *Self, n: u8) void {
        debug.assert(self.state_func_stack.items.len >= n);
        self.state_func_stack.items.len -= n;
    }

    /// Populates the token 't' and set the state function to **EMIT_FUNC**.
    fn emit(
        self: *Self,
        t: *Token,
        token_type: TokenType,
        value: ?[]const u8,
        pos: *const common.Position,
    ) void {
        emitToken(t, token_type, value, pos);
        if (token_type == .Error) {
            // In case of an error clear the state stack and
            // push the error fallback.
            self.clearState();
            self.pushStateOrThrow(lexOnError, t);
        }
        self.pushStateOrThrow(EMIT_FUNC, t);
    }

    /// Reads and return the next byte in the stream
    /// if it encounters and an end of steam an error is returned.
    /// this function makes sure carriage **\r** is followed by a line feed
    /// **\n** or it returns an error.
    fn nextByte(self: *Self) !u8 {
        const r = self.input.reader();
        var b = r.readByte() catch |err| {
            return err;
        };
        if (b == '\r') {
            // expect a newline character.
            const c = r.readByte() catch 0x00;
            if (c != '\n') {
                // rewind so we can keep returning error
                // on the next call.
                self.toLastByte();
                return error.BadEOL;
            }
            b = '\n';
            self.index += 1;
        }

        self.index += 1;
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
        self.index += count;
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

    /// Rewind the stream position by 1 bytes
    fn toLastByte(self: *Self) void {
        debug.assert(self.index > 0);
        self.index -= 1;
        self.input.seekTo(self.index) catch unreachable;
        if (self.position.column > 1) {
            self.position.column -= 1;
        } else {
            self.position.line -= 1;
        }
    }

    /// Returns the value of the next byte in the stream without modifying
    /// the current read index in the stream.
    /// same as nextByte returns an error if it reaches end of stream.
    fn peekByte(self: *Self) !u8 {
        const b = try self.nextByte();
        self.toLastByte();
        return b;
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
            self.toLastByte();
            return false;
        }
    }

    /// assumes readning the next count of bytes won't cause any errors.
    fn ignoreBytes(self: *Self, count: usize) void {
        for (0..count) |_| {
            _ = self.nextByte() catch unreachable;
        }
    }

    /// Reads ahead in the stream and ignore any byte in `bytes_to_skip`.
    fn skipBytes(self: *Self, bytes_to_skip: []const u8) void {
        while (true) {
            const b = self.nextByte() catch {
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
        self.toLastByte();
    }

    fn lexRoot(self: *Self, t: *Token) void {
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                const err_msg = self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
            } else {
                self.emit(t, .EOS, null, &self.position);
            }
            return;
        };

        if (common.isControl(b)) {
            const err_msg = self.formatError("Stream contains control character 0x{x:0>2}", .{b});
            self.emit(t, .Error, err_msg, &self.position);
            return;
        } else if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            self.skipBytes(&(WHITESPACE ++ NEWLINE));
            self.lexRoot(t);
            return;
        }

        switch (b) {
            '#' => {
                self.pushStateOrThrow(lexComment, t);
            },
            '[' => {
                self.pushStateOrThrow(lexTableHeaderStart, t);
            },
            else => {
                self.toLastByte();
                self.pushStateOrThrow(lexKeyValueEnd, t);
                self.pushStateOrThrow(lexKey, t);
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
        while (true) {
            const b = self.nextByte() catch |err| {
                if (err == error.BadEOL) {
                    const err_msg = self.formatError(
                        "Lexer: Expected a newline after carriage return",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                }
                break;
            };

            if (common.isControl(b)) {
                const err_msg = self.formatError(
                    "Lexer: control character '{}' not allowed in comments",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            }

            if (common.isNewLine(b)) {
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
        }
        if (!common.isValidUTF8(self.token_buffer.data())) {
            const err_msg = self.formatError("Lexer: Comment contains invalid UTF8 codepoint.", .{});
            self.emit(t, .Error, err_msg, &self.lex_start);
            return;
        }
        const last_func = self.popState();
        debug.assert(last_func == lexComment);
        if (opt.EMIT_COMMENT_TOKEN) {
            emitToken(t, .Comment, self.token_buffer.data(), &self.lex_start);
        } else {
            // clear the comment data.
            self.token_buffer.clearContent();
        }
    }

    fn lexTableHeaderStart(self: *Self, t: *Token) void {
        _ = self.popState();
        self.pushStateOrThrow(lexTableHeaderEnd, t);
        const b = self.peekByte() catch |err| {
            const err_msg = if (err == error.BadEOL)
                self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                )
            else
                self.formatError(
                    "Lexer: expected closing bracket ']' before end of stream",
                    .{},
                );
            self.emit(t, .Error, err_msg, &self.position);
            return;
        };
        if (b == '[') {
            self.ignoreBytes(1);
            self.pushStateOrThrow(lexArrayTableEnd, t);
            self.pushStateOrThrow(lexTableName, t);
            self.emit(t, .ArrayTableStart, null, &self.lex_start);
        } else {
            self.pushStateOrThrow(lexTableEnd, t);
            self.pushStateOrThrow(lexTableName, t);
            self.emit(t, .TableStart, null, &self.lex_start);
        }
    }

    /// Assert newline character or comment after header [table] or [[array]].
    fn lexTableHeaderEnd(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexTableHeaderEnd);
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                const err_msg =
                    self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
            }
            return;
        };
        switch (b) {
            '#' => self.pushStateOrThrow(lexComment, t),
            '\n' => {},
            else => {
                const err_msg = self.formatError(
                    "Lexer: expected newline after table header",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
        }
    }

    fn lexTableName(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);
        const b = self.peekByte() catch |err| {
            const err_msg = if (err == error.BadEOL)
                self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                )
            else
                self.formatError(
                    "Lexer: expected closing bracket ']' before end of stream",
                    .{},
                );
            self.emit(t, .Error, err_msg, &self.position);
            return;
        };
        self.pushStateOrThrow(lexTableNameEnd, t);
        switch (b) {
            '.', ']' => {
                const err_msg = self.formatError(
                    "Lexer: unexpected symbol found within table name",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
            '"', '\'' => {
                self.pushStateOrThrow(lexQuottedKey, t);
            },
            else => {
                self.pushStateOrThrow(lexBareKey, t);
            },
        }
    }

    fn lexTableNameEnd(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch |err| {
            const err_msg = if (err == error.BadEOL)
                self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                )
            else
                self.formatError(
                    "Lexer: expected closing bracket ']' before end of stream",
                    .{},
                );

            self.emit(t, .Error, err_msg, &self.position);
            return;
        };
        switch (b) {
            '.' => {
                _ = self.popState();
                self.emit(t, .Dot, null, &self.position);
                return;
            },
            ']' => {
                self.popNState(2);
                return;
            },
            else => {
                const err_msg = self.formatError(
                    "Lexer: expected closing bracket ']' or comma '.' found `{c}`",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
        }
    }

    fn lexTableEnd(self: *Self, t: *Token) void {
        _ = self.popState();
        self.emit(t, .TableEnd, null, &self.position);
    }

    fn lexArrayTableEnd(self: *Self, t: *Token) void {
        _ = self.popState();
        if (!self.consumeByte(']')) {
            const err_msg = self.formatError(
                "Lexer: expected `]` at the of Array of tables declaration",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.position);
            return;
        }
        self.emit(t, .ArrayTableEnd, null, &self.position);
    }

    /// Handles lexing a key and calls the next appropriate function
    /// this function assumes that there is at least one byte in the stream
    fn lexKey(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);
        // TODO: not sure about this unreachable.
        const b = self.peekByte() catch unreachable;
        self.pushStateOrThrow(lexKeyEnd, t);
        switch (b) {
            '=', '.' => {
                const err_msg = self.formatError(
                    "Lexer: expected a key name found '{c}' ",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
            '"', '\'' => {
                self.pushStateOrThrow(lexQuottedKey, t);
            },
            else => {
                self.pushStateOrThrow(lexBareKey, t);
            },
        }
    }

    /// Checks for key end or a dotted key.
    fn lexKeyEnd(self: *Self, t: *Token) void {
        self.skipBytes(&WHITESPACE);

        const b = self.nextByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected '=' after key name",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.position);
            return;
        };

        switch (b) {
            '.' => {
                _ = self.popState();
                self.emit(t, .Dot, null, &self.position);
            },
            '=' => {
                self.popNState(2);
                self.pushStateOrThrow(lexValue, t);
            },
            else => {
                const err_msg = self.formatError("Lexer: expected '=' or '.' found '{c}'", .{b});
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
        }
    }

    /// Lex a bare key.
    fn lexBareKey(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        while (true) {
            const b = self.peekByte() catch {
                break;
            };

            if (!common.isBareKeyChar(b)) {
                break;
            }

            self.token_buffer.append(b) catch {
                // In case of an error clear the state stack and update the token
                // to an error token.
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
            self.ignoreBytes(1);
        }
        const current = self.popState();
        debug.assert(current == lexBareKey);
        self.emit(t, .Key, self.token_buffer.data(), &self.lex_start);
    }

    fn lexQuottedKey(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexQuottedKey);
        const b = self.nextByte() catch unreachable;
        switch (b) {
            '"' => self.pushStateOrThrow(lexString(.Key).lexBasicString, t),
            '\'' => self.pushStateOrThrow(lexString(.Key).lexLiteralString, t),
            else => unreachable,
        }
        self.lex_start = self.position;
    }

    fn lexValue(self: *Self, t: *Token) void {
        _ = self.popState();
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected a value after '='",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.position);
            return;
        };
        if (common.isDigit(b)) {
            self.toLastByte();
            self.pushStateOrThrow(lexNumber, t);
            return;
        }
        switch (b) {
            '[' => {
                self.pushStateOrThrow(lexArrayValue, t);
                self.emit(t, .ArrayStart, null, &self.position);
            },
            '{' => {
                self.pushStateOrThrow(lexInlineTabValue, t);
                self.emit(t, .InlineTableStart, null, &self.position);
            },
            '"' => {
                if (self.consumeByte('"')) {
                    if (self.consumeByte('"')) {
                        self.pushStateOrThrow(lexMultiLineBasicString, t);
                        return;
                    } else {
                        self.toLastByte();
                    }
                }
                self.pushStateOrThrow(lexString(.BasicString).lexBasicString, t);
            },
            '\'' => {
                if (self.consumeByte('\'')) {
                    if (self.consumeByte('\'')) {
                        self.pushStateOrThrow(lexMultiLineLiteralString, t);
                        return;
                    } else {
                        self.toLastByte();
                    }
                }
                self.pushStateOrThrow(lexString(.LiteralString).lexLiteralString, t);
            },
            'i', 'n' => {
                self.toLastByte();
                self.lex_start = self.position;
                self.pushStateOrThrow(lexFloat, t);
            },
            '-', '+' => {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                };
                self.lex_start = self.position;
                self.pushStateOrThrow(lexDecimalInteger, t);
            },
            't', 'f' => {
                self.toLastByte();
                self.pushStateOrThrow(lexBoolean, t);
            },
            else => {
                const err_msg = self.formatError(
                    "Lexer: expected a value after '=' found '{c}'",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
        }
    }

    /// consumes and validate the newline after the key/value pair.
    fn lexKeyValueEnd(self: *Self, t: *Token) void {
        _ = self.popState();
        self.skipBytes(&WHITESPACE);
        const b = self.nextByte() catch |err| {
            if (err == error.BadEOL) {
                const err_msg =
                    self.formatError(
                    "Lexer: Expected a newline after carriage return",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
            }
            return;
        };
        switch (b) {
            '#' => self.pushStateOrThrow(lexComment, t),
            '\n' => return,
            else => {
                const err_msg = self.formatError(
                    "Lexer: expected newline after key/value pair found '{c}'",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
        }
    }

    fn lexString(comptime token_type: TokenType) type {
        return struct {
            /// lex the string content between it's delimiters '"'.
            fn lexBasicString(self: *Self, t: *Token) void {
                while (true) {
                    const b = self.nextByte() catch |err| {
                        const err_msg = if (err == error.BadEOL)
                            self.formatError(
                                "Lexer: Expected a newline after carriage return",
                                .{},
                            )
                        else
                            self.formatError(
                                "Lexer: reached end of stream before string delimiter \" ",
                                .{},
                            );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    };

                    if (common.isNewLine(b)) {
                        const err_msg = self.formatError(
                            "Lexer: basic string can't contain a newline character 0x{X:0>2}",
                            .{b},
                        );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    if (common.isControl(b)) {
                        const err_msg = self.formatError(
                            "Lexer: control character '{}' not allowed in basic strings",
                            .{b},
                        );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }

                    switch (b) {
                        '"' => break,
                        '\\' => self.lexStringEscape(t, false) catch return,
                        else => self.token_buffer.append(b) catch {
                            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                            return;
                        },
                    }
                }
                const current = self.popState();
                debug.assert(current == lexBasicString);
                self.emit(t, token_type, self.token_buffer.data(), &self.lex_start);
            }

            /// lex the string content between it's delimiters `'`.
            fn lexLiteralString(self: *Self, t: *Token) void {
                while (true) {
                    const b = self.nextByte() catch |err| {
                        const err_msg = if (err == error.BadEOL)
                            self.formatError(
                                "Lexer: Expected a newline after carriage return",
                                .{},
                            )
                        else
                            self.formatError(
                                "Lexer: reached end of stream before string delimiter ' ",
                                .{},
                            );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    };

                    if (common.isControl(b)) {
                        const err_msg = self.formatError(
                            "Lexer: control character '{}' not allowed in litteral strings",
                            .{b},
                        );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    if (common.isNewLine(b)) {
                        const err_msg = self.formatError(
                            "Lexer: litteral string can't contain a newline character 0x{X:0>2}",
                            .{b},
                        );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    switch (b) {
                        '\'' => break,
                        else => self.token_buffer.append(b) catch {
                            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                            return;
                        },
                    }
                }
                const current = self.popState();
                debug.assert(current == lexLiteralString);
                self.emit(t, token_type, self.token_buffer.data(), &self.lex_start);
            }
        };
    }

    fn lexMultiLineBasicString(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        while (true) {
            const b = self.nextByte() catch |err| {
                const err_msg = if (err == error.BadEOL)
                    self.formatError(
                        "Lexer: Expected a newline after carriage return",
                        .{},
                    )
                else
                    self.formatError(
                        "Lexer: reached end of stream before multi-line string delimiter \"\"\" ",
                        .{},
                    );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            };
            if (common.isControl(b)) {
                const err_msg = self.formatError(
                    "Lexer: control character '{}' not allowed in basic strings",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            }
            switch (b) {
                '"' => {
                    if (self.consumeByte('"')) {
                        if (self.consumeByte('"')) {
                            // there are some edge cases where a multi line string
                            // could be written as: """Hello World"""""
                            // allowing for 5 '"' at the end.
                            var counter: i8 = 2;
                            while (counter > 0) {
                                const c = self.peekByte() catch break;
                                if (c != '"') {
                                    break;
                                }
                                self.token_buffer.append(c) catch {
                                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                                    return;
                                };
                                self.ignoreBytes(1);
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.toLastByte();
                        }
                    }
                    self.token_buffer.append(b) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                },
                '\\' => self.lexMultiLineStringEscape(t) catch return,
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                },
            }
        }
        const current = self.popState();
        debug.assert(current == lexMultiLineBasicString);
        self.emit(t, .MultiLineBasicString, self.token_buffer.data(), &self.lex_start);
    }

    fn lexMultiLineLiteralString(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        while (true) {
            const b = self.nextByte() catch |err| {
                const err_msg = if (err == error.BadEOL)
                    self.formatError(
                        "Lexer: Expected a newline after carriage return",
                        .{},
                    )
                else
                    self.formatError(
                        "Lexer: reached end of stream before multi-line string delimiter ''' ",
                        .{},
                    );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            };
            if (common.isControl(b)) {
                const err_msg = self.formatError(
                    "Lexer: control character '{}' not allowed in litteral strings",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            }
            switch (b) {
                '\'' => {
                    if (self.consumeByte('\'')) {
                        if (self.consumeByte('\'')) {
                            // there are some edge cases where a multi line string
                            // could be written as: '''Hello World'''''
                            // allowing for 5 `'` at the end.
                            var counter: i8 = 2;
                            while (counter > 0) {
                                const c = self.peekByte() catch break;
                                if (c != '\'') {
                                    break;
                                }
                                self.token_buffer.append(c) catch {
                                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                                    return;
                                };
                                self.ignoreBytes(1);
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.toLastByte();
                        }
                    }
                    self.token_buffer.append(b) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                },
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                },
            }
        }
        const current = self.popState();
        debug.assert(current == lexMultiLineLiteralString);
        self.emit(t, .MultiLineLiteralString, self.token_buffer.data(), &self.lex_start);
    }

    /// Called when encountering a string escape sequence in a multi line string.
    /// assumes '\' is already consumed
    fn lexMultiLineStringEscape(self: *Self, t: *Token) !void {
        var b = self.peekByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected an escape sequence before end of stream",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.lex_start);
            return error.BadStringEscape;
        };
        const curr_index = self.index;
        _ = curr_index;
        if (common.isWhiteSpace(b)) {
            // Whitespace is allowed after line ending backslack
            self.skipBytes(&WHITESPACE);
            b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: expected an escape sequence before end of stream",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return error.BadStringEscape;
            };
            if (common.isNewLine(b)) {
                self.token_buffer.appendSlice(&[_]u8{ '\\', b }) catch |e| {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return e;
                };
                return;
            } else {
                const err_msg = self.formatError(
                    "Lexer: whitespace is only allowed after line ending backslash",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return error.BadStringEscape;
            }
        } else if (common.isNewLine(b)) {
            self.ignoreBytes(1);
            self.token_buffer.appendSlice(&[_]u8{ '\\', b }) catch |e| {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return e;
            };
            return;
        }

        try self.lexStringEscape(t, true);
    }

    /// Called when encountering a string escape sequence
    /// assumes '\' is already consumed
    /// decodes the string escapes while lexing.
    fn lexStringEscape(self: *Self, t: *Token, is_multiline: bool) !void {
        const b = self.nextByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected an escape sequence before end of stream",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.position);
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
                if (!self.lexUnicodeEscape(t, 4, &hex)) {
                    // error already reported
                    return error.BadStringEscape;
                }
                var num_written: usize = common.toUnicodeCodepoint(hex[0..4]) catch {
                    const err_msg = self.formatError(
                        "Lexer: '\\u{s}' is not a valid unicode escape",
                        .{hex[0..4]},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return error.BasicStringEscape;
                };
                break :u hex[0..num_written];
            },
            'U' => U: {
                if (!self.lexUnicodeEscape(t, 8, &hex)) {
                    // error already reported
                    return error.BadStringEscape;
                }
                var num_written: usize = common.toUnicodeCodepoint(hex[0..8]) catch {
                    const err_msg = self.formatError(
                        "Lexer: '\\U{s}' is not a valid unicode escape",
                        .{hex[0..8]},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return error.BasicStringEscape;
                };
                break :U hex[0..num_written];
            },
            else => {
                const err_msg = self.formatError(
                    "Lexer: bad string escape sequence, '\\{c}' | \\0x{X:0>2}",
                    .{ b, b },
                );
                self.emit(t, .Error, err_msg, &self.position);
                return error.BadStringEscape;
            },
        };

        self.token_buffer.appendSlice(bytes) catch |e| {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
            return e;
        };
    }

    fn lexHexEscape(self: *Self, t: *Token, out: []u8) bool {
        for (0..2) |i| {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return false;
            };

            if (!common.isHex(b)) {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit found {c}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return false;
            }
            out[i] = b;
        }
        return true;
    }

    fn lexUnicodeEscape(self: *Self, t: *Token, comptime width: u8, out: []u8) bool {
        for (0..width) |i| {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return false;
            };

            if (!common.isHex(b)) {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit found {c}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return false;
            }

            out[i] = b;
        }
        return true;
    }

    /// Used to determine how the number value should be processed.
    /// assumes there is at least a byte in the stream.
    fn lexNumber(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexNumber);

        self.lex_start = self.position;
        // guaranteed digit.
        var b = self.nextByte() catch unreachable;
        self.token_buffer.append(b) catch {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
            return;
        };

        if (b == '0') {
            // possibly a base speceific number.
            const base = self.peekByte() catch 0x00;
            switch (base) {
                'b' => {
                    self.ignoreBytes(1);
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    self.pushStateOrThrow(lexBinaryInteger, t);
                    return;
                },
                'o' => {
                    self.ignoreBytes(1);
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    self.pushStateOrThrow(lexOctalInteger, t);
                    return;
                },
                'x' => {
                    self.ignoreBytes(1);
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    self.pushStateOrThrow(lexHexInteger, t);
                    return;
                },
                else => {},
            }
        }

        while (true) {
            b = self.peekByte() catch break;

            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                };
                self.ignoreBytes(1);
                continue;
            }

            switch (b) {
                '.', 'e', 'E' => {
                    self.pushStateOrThrow(lexFloat, t);
                    return;
                },
                '-', ':' => {
                    self.pushStateOrThrow(lexDateTime, t);
                    return;
                },
                else => break,
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0b is already consumed
    fn lexBinaryInteger(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexBinaryInteger);

        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isBinary(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0o is already consumed
    fn lexOctalInteger(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexOctalInteger);
        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isOctal(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDecimalInteger(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexDecimalInteger);
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                };
                continue;
            }

            // preparing to return
            self.toLastByte();

            switch (b) {
                '.', 'e', 'E', 'i', 'n' => {
                    // switch to lexing a float
                    self.pushStateOrThrow(lexFloat, t);
                    return;
                },
                '-', ':' => {
                    self.pushStateOrThrow(lexDateTime, t);
                    return;
                },
                else => break,
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0x is already consumed
    fn lexHexInteger(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexHexInteger);
        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isHex(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    // lex float number
    fn lexFloat(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexFloat);
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isDigit(b)) {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                    return;
                };
                continue;
            }

            switch (b) {
                '-', '+', '_', 'e', 'E', '.' => {
                    self.token_buffer.append(b) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    continue;
                },
                'i' => {
                    if (!self.consumeByte('n') or !self.consumeByte('f')) {
                        const err_msg = self.formatError("Lexer: Invalid float", .{});
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'i', 'n', 'f' }) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    break;
                },
                'n' => {
                    if (!self.consumeByte('a') or !self.consumeByte('n')) {
                        const err_msg = self.formatError("Lexer: Invalid float", .{});
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'n', 'a', 'n' }) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                        return;
                    };
                    break;
                },
                else => {
                    self.toLastByte();
                    break;
                },
            }
        }
        self.emit(t, .Float, self.token_buffer.data(), &self.lex_start);
    }

    /// expects a boolean string
    /// assumes there is at least a byte in stream.
    fn lexBoolean(self: *Self, t: *Token) void {
        const current = self.popState();
        debug.assert(current == lexBoolean);
        self.lex_start = self.position;
        var initial = self.peekByte() catch unreachable;
        var boolean: [5]u8 = undefined;
        var count: usize = 0;
        switch (initial) {
            't' => {
                count = self.nextSlice(boolean[0..4]) catch return;
                if (count != 4) {
                    const err_msg = self.formatError(
                        "Lexer: unexpected end of stream",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                }
                if (!mem.eql(u8, boolean[0..4], "true")) {
                    const err_msg = self.formatError(
                        "Lexer: Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                }
            },
            'f' => {
                count = self.nextSlice(&boolean) catch return;
                if (count != 5) {
                    const err_msg = self.formatError(
                        "Lexer: unexpected end of stream",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                }
                if (!mem.eql(u8, &boolean, "false")) {
                    const err_msg = self.formatError(
                        "Lexer: Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                }
            },
            else => unreachable,
        }

        self.token_buffer.appendSlice(boolean[0..count]) catch {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
            return;
        };
        self.emit(t, .Boolean, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDateTime(self: *Self, t: *Token) void {
        while (true) {
            var b = self.peekByte() catch break;

            b = switch (b) {
                '0'...'9',
                ':',
                'T',
                'Z',
                '+',
                '-',
                '.',
                => b,
                ' ', 't' => {
                    // in case of a space ' ' we need to read ahead
                    // and make sure this isn't the end.
                    self.ignoreBytes(1);
                    var c = self.nextByte() catch break;
                    if (common.isDigit(c)) {
                        self.token_buffer.appendSlice(&.{ 'T', c }) catch {
                            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                            return;
                        };
                        continue;
                    } else {
                        // we are done.
                        self.toLastByte();
                        break;
                    }
                },
                'z' => 'Z',
                else => break,
            };
            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.position);
                return;
            };
            self.ignoreBytes(1);
        }

        const current = self.popState();
        debug.assert(current == lexDateTime);
        self.emit(t, .DateTime, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes the starting bracket '[' was already consumed.
    fn lexArrayValue(self: *Self, t: *Token) void {
        self.lex_start = self.position;
        while (true) {
            const b = self.nextByte() catch |err| {
                const err_msg = if (err == error.BadEOL)
                    self.formatError(
                        "Lexer: Expected a newline after carriage return",
                        .{},
                    )
                else
                    self.formatError(
                        "Lexer: expected array closing delimiter ']' before end of stream",
                        .{},
                    );

                self.emit(t, .Error, err_msg, &self.position);
                return;
            };
            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&(WHITESPACE ++ NEWLINE));
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexComment, t);
                    return;
                },
                ',' => {
                    const err_msg = self.formatError(
                        "Lexer: Unexpected comma ',' inside array",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                },
                ']' => break,
                else => {
                    self.toLastByte();
                    self.pushStateOrThrow(lexArrayValueEnd, t);
                    self.pushStateOrThrow(lexValue, t);
                    return;
                },
            }
        }

        const current = self.popState();
        debug.assert(current == lexArrayValue);

        self.emit(t, .ArrayEnd, null, &self.lex_start);
    }

    fn lexArrayValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.peekByte() catch |err| {
                const err_msg = if (err == error.BadEOL)
                    self.formatError(
                        "Lexer: Expected a newline after carriage return",
                        .{},
                    )
                else
                    self.formatError(
                        "Lexer: expected array closing delimiter ']' before end of stream",
                        .{},
                    );

                self.emit(t, .Error, err_msg, &self.position);
                return;
            };
            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&(WHITESPACE ++ NEWLINE));
                continue;
            }

            switch (b) {
                '#' => {
                    _ = self.nextByte() catch unreachable;
                    self.pushStateOrThrow(lexComment, t);
                    return;
                },
                ',' => {
                    _ = self.nextByte() catch unreachable;
                    break;
                },
                ']' => break,
                else => {
                    const err_msg = self.formatError(
                        "Lexer: expected comma ',' or array closing bracket ']' found {c}",
                        .{b},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                },
            }
        }
        const current = self.popState();
        debug.assert(current == lexArrayValueEnd);
    }

    /// assumes '{' is already consumed.
    fn lexInlineTabValue(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isNewLine(b)) {
                const err_msg = self.formatError(
                    "Lexer: Newline not allowed inside inline tables.",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&WHITESPACE);
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrThrow(lexComment, t);
                    return;
                },
                ',' => {
                    const err_msg = self.formatError(
                        "Lexer: Unexpected comma ',' inside array",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                },
                '}' => break,
                else => {
                    self.toLastByte();
                    self.pushStateOrThrow(lexInlineTabValueEnd, t);
                    self.pushStateOrThrow(lexKey, t);
                    return;
                },
            }
        }

        const current = self.popState();
        debug.assert(current == lexInlineTabValue);

        self.emit(t, .InlineTableEnd, null, &self.lex_start);
    }

    fn lexInlineTabValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.peekByte() catch break;
            if (common.isNewLine(b)) {
                const err_msg = self.formatError(
                    "Lexer: Newline not allowed inside inline tables.",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.position);
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&WHITESPACE);
                continue;
            }

            switch (b) {
                '#' => {
                    self.ignoreBytes(1);
                    self.pushStateOrThrow(lexComment, t);
                    return;
                },
                ',' => {
                    self.ignoreBytes(1);
                    self.skipBytes(&WHITESPACE);
                    if (self.consumeByte('}')) {
                        const err_msg = self.formatError(
                            "Lexer: a trailing comma ',' is not permitted after the last key/value pair in an inline table.",
                            .{},
                        );
                        self.emit(t, .Error, err_msg, &self.position);
                        return;
                    }
                    break;
                },
                '}' => break,
                else => {
                    const err_msg = self.formatError(
                        "Lexer: expected comma ',' or an inline table terminator '}}' found '{c}'",
                        .{b},
                    );
                    self.emit(t, .Error, err_msg, &self.position);
                    return;
                },
            }
        }
        const current = self.popState();
        debug.assert(current == lexInlineTabValueEnd);
    }

    /// Used as a fallback when the lexer encounters an error.
    fn lexOnError(self: *Self, t: *Token) void {
        const err_msg = self.formatError(
            "Lexer: Input Stream contains errors",
            .{},
        );
        self.emit(t, .Error, err_msg, &self.position);
    }

    fn formatError(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
        self.token_buffer.clearContent();
        self.token_buffer.print(format, args) catch {
            return Self.ERR_MSG_GENERIC;
        };
        return self.token_buffer.data();
    }

    pub fn init(allocator: mem.Allocator, input: *io.StreamSource) mem.Allocator.Error!Self {
        var state_func_stack = try Stack(?LexFuncPtr).initCapacity(allocator, 8);
        errdefer state_func_stack.deinit();
        state_func_stack.append(lexRoot) catch unreachable; // we just allocated;
        return .{
            .input = input,
            .index = 0,
            .position = .{ .line = 1, .column = 1 },
            .lex_start = .{ .line = 1, .column = 1 },
            .token_buffer = try common.DynArray(u8).initCapacity(
                allocator,
                opt.LEXER_BUFFER_SIZE,
            ),
            .state_func_stack = state_func_stack,
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
            if (LOG_LEXER_STATE) {
                self.logState();
            }
            debug.assert(self.state_func_stack.items.len > 0);
            const lexFunc = self.state_func_stack.getLast() orelse {
                // lexFunc == EMIT_FUNC == null
                _ = self.popState();
                break;
            };
            lexFunc(self, t);
        }
        self.lex_start = self.position;
    }

    fn logState(self: *Self) void {
        std.debug.print("======== Lexer ==========\n", .{});
        std.debug.print("[+] Function Stack:\n", .{});
        std.debug.print("-------------------- :\n", .{});
        for (self.state_func_stack.items) |func| {
            std.debug.print("| {s} |\n", .{functionToString(func)});
            std.debug.print("-------------------- :\n", .{});
        }
        std.debug.print("[+] Stream offset: {d}\n", .{self.index});
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
        if (f == lexQuottedKey) {
            return "lexQuottedKey";
        }
        if (f == lexBareKey) {
            return "lexBareKey";
        }
        if (f == lexBoolean) {
            return "lexBoolean";
        }
        if (f == lexKey) {
            return "lexKey";
        }
        if (f == lexKeyEnd) {
            return "lexKeyEnd";
        }
        if (f == lexOnError) {
            return "lexOnError";
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
        if (f == lexTableName) {
            return "lexTableName";
        }
        if (f == lexTableNameEnd) {
            return "lexTableNameEnd";
        }
        return "!!!Function Not found";
    }
};
