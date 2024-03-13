const std = @import("std");
const opt = @import("build_options");
const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const log = std.log;
const common = @import("common.zig");
const assert = std.debug.assert;
const Stack = std.ArrayList;

const LOG_LEXER_STATE = opt.LOG_LEXER_STATE;

// NOTE: for all strings and keys tokens the value won't contain the delimiters (`'`, `"`...etc).
// for numbers such as integers and floats it only validates that they don't contain any
// non permissable characters, the parser should make sure the values are valid for the type.
pub const TokenType = enum {
    EOF,
    Key,
    Dot,
    Comment, // The lexer won't inlucde the newline byte in the comment value.
    Integer,
    Float,
    Boolean, // The lexer validates that the value is either true or false.
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

pub const Token = struct {
    type: TokenType,
    value: ?[]const u8,
    start: common.Position,
};

inline fn emitToken(t: *Token, token_type: TokenType, value: ?[]const u8, pos: *const common.Position) void {
    t.start = pos.*;
    t.type = token_type;
    t.value = value;
}

pub const Lexer = struct {
    input: *io.StreamSource,
    index: usize, // current read index into the input.
    position: common.Position,
    prev_position: common.Position,
    // BUG: the value doesn't chage or update.
    lex_start: common.Position, // position from where we started lexing the current token.
    token_buffer: common.DynArray(u8, null),
    state_func_stack: Stack(?LexFuncPtr),

    const Self = @This();
    const LexFuncPtr = *const fn (self: *Self, t: *Token) void;
    const EOF: u8 = 0;
    const ERR_MSG_GENERIC: []const u8 = "Lexer: Encounterd an error.";
    const ERR_MSG_OUT_OF_MEMORY: []const u8 = "Lexer: Ran out of memory.";
    const EMIT_FUNC: ?LexFuncPtr = null;

    inline fn pushStateOrStop(self: *Self, f: ?LexFuncPtr, t: *Token) void {
        self.state_func_stack.append(f) catch {
            emitToken(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
        };
    }

    inline fn popState(self: *Self) ?LexFuncPtr {
        return self.state_func_stack.pop();
    }

    inline fn clearState(self: *Self) void {
        self.state_func_stack.clearRetainingCapacity();
    }

    inline fn popNState(self: *Self, n: u8) void {
        assert(self.state_func_stack.items.len >= n);
        self.state_func_stack.items.len -= n;
    }

    inline fn updatePrevPosition(self: *Self) void {
        self.prev_position = self.position;
    }

    inline fn updateStartPosition(self: *Self) void {
        self.lex_start = self.position;
    }

    inline fn rewindPosition(self: *Self) void {
        self.position = self.prev_position;
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
            self.pushStateOrStop(lexOnError, t);
        }
        self.pushStateOrStop(EMIT_FUNC, t);
    }

    /// Reads and return the next byte in the stream
    /// if it encounters and an end of steam an error is returned.
    fn nextByte(self: *Self) !u8 {
        const r = self.input.reader();
        const b = r.readByte() catch |err| {
            return err;
        };
        self.index += 1;
        self.updatePrevPosition();
        if (b == '\n') {
            self.position.line += 1;
            self.position.offset = 0;
        } else {
            self.position.offset += 1;
        }
        return b;
    }

    fn nextSlice(self: *Self, out: []u8) !usize {
        const r = self.input.reader();
        const count = r.read(out) catch |err| {
            return err;
        };
        self.index += count;
        self.updatePrevPosition();
        for (0..count) |i| {
            if (out[i] == '\n') {
                self.position.line += 1;
                self.position.offset = 0;
            } else {
                self.position.offset += 1;
            }
        }
        return count;
    }

    /// Rewind the stream position by 1 bytes
    fn toLastByte(self: *Self) void {
        assert(self.index > 0);
        self.index -= 1;
        self.input.seekTo(self.index) catch unreachable;
        self.rewindPosition();
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

    fn lexTable(self: *Self, t: *Token) void {
        const b = self.nextByte() catch {
            self.emit(t, .EOF, null, &self.position);
            return;
        };

        if (common.isControl(b)) {
            const err_msg = self.formatError("Stream contains control character 0x{x:0>2}", .{b});
            self.emit(t, .Error, err_msg, &self.prev_position);
            return;
        } else if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            self.skipBytes(&[_]u8{ '\n', '\r', '\t', ' ' });
            self.lexRoot(t);
            return;
        }

        switch (b) {
            '#' => {
                self.pushStateOrStop(lexComment, t);
            },
            '[' => {
                self.pushStateOrStop(lexTableStart, t);
            },
            else => {
                self.toLastByte();
                self.pushStateOrStop(lexKey, t);
            },
        }
    }

    /// Lexes an entire comment up to the newline character.
    /// the token value is not populated by the comment text,
    /// but rather set to null.
    /// assumes the character '#' at the begining of the comment is already
    /// consumed.
    fn lexComment(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                break;
            };

            if (common.isControl(b)) {
                const err_msg = self.formatError("Lexer: control character '{}' not allowed in comments", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }

            if (common.isNewLine(b)) {
                break;
            }
        }
        const last_func = self.popState();
        assert(last_func == lexComment);
        if (opt.EMIT_COMMENT_TOKEN) {
            emitToken(t, .Comment, null, &self.lex_start);
        }
    }

    fn lexTableStart(self: *Self, t: *Token) void {
        const b = self.peekByte() catch {
            const err_msg = self.formatError("Lexer: expected closing bracket ']' before end of stream", .{});
            self.emit(t, .Error, err_msg, &self.lex_start);
            return;
        };
        _ = self.popState();
        if (b == '[') {
            _ = self.nextByte() catch unreachable;
            self.pushStateOrStop(lexArrayTableEnd, t);
            self.pushStateOrStop(lexTableName, t);
            self.emit(t, .ArrayTableStart, null, &self.lex_start);
        } else {
            self.pushStateOrStop(lexTableEnd, t);
            self.pushStateOrStop(lexTableName, t);
            self.emit(t, .TableStart, null, &self.lex_start);
        }
    }

    fn lexTableName(self: *Self, t: *Token) void {
        self.skipBytes(&[_]u8{ ' ', '\t' });
        const b = self.peekByte() catch {
            const err_msg = self.formatError("Lexer: expected closing bracket ']' before end of stream", .{});
            self.emit(t, .Error, err_msg, &self.lex_start);
            return;
        };
        switch (b) {
            '.', ']' => {
                const err_msg = self.formatError("Lexer: unexpected symbol found within table name", .{});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            },
            '"', '\'' => {
                self.pushStateOrStop(lexTableNameEnd, t);
                self.pushStateOrStop(lexQuottedKey, t);
            },
            else => {
                self.pushStateOrStop(lexTableNameEnd, t);
                self.pushStateOrStop(lexBareKey, t);
            },
        }
    }

    fn lexTableNameEnd(self: *Self, t: *Token) void {
        self.skipBytes(&[_]u8{ ' ', '\t' });
        const b = self.nextByte() catch {
            const err_msg = self.formatError("Lexer: expected closing bracket ']' before end of stream", .{});
            self.emit(t, .Error, err_msg, &self.lex_start);
            return;
        };
        switch (b) {
            '.' => {
                _ = self.popState();
                self.emit(t, .Dot, null, &self.lex_start);
                return;
            },
            ']' => {
                self.popNState(2);
                return;
            },
            else => {
                const err_msg = self.formatError("Lexer: expected closing bracket ']' or comma '.' found {c}", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            },
        }
    }

    fn lexTableEnd(self: *Self, t: *Token) void {
        _ = self.popState();
        self.emit(t, .TableEnd, null, &self.lex_start);
    }

    fn lexArrayTableEnd(self: *Self, t: *Token) void {
        if (!self.consumeByte(']')) {
            const err_msg = self.formatError("Lexer expected end of Array of tables ']'", .{});
            self.emit(t, .Error, err_msg, &self.lex_start);
            return;
        }
        _ = self.popState();
        self.emit(t, .ArrayTableEnd, null, &self.lex_start);
    }

    /// Handles lexing a key and calls the next appropriate function
    /// this function assumes that there is at least one byte in the stream
    fn lexKey(self: *Self, t: *Token) void {
        const b = self.peekByte() catch unreachable;
        self.pushStateOrStop(lexKeyEnd, t);
        switch (b) {
            '=', '.' => {
                const err_msg = self.formatError("Lexer: expected a key name found '{c}' ", .{b});
                self.emit(t, .Error, err_msg, &self.position);
                return;
            },
            '"', '\'' => {
                self.pushStateOrStop(lexQuottedKey, t);
            },
            else => {
                self.pushStateOrStop(lexBareKey, t);
            },
        }
    }

    /// Checks for key end or a dotted key.
    fn lexKeyEnd(self: *Self, t: *Token) void {
        self.skipBytes(&[_]u8{ ' ', '\t' });

        const b = self.nextByte() catch {
            const err_msg = self.formatError("Lexer: expected '=' before reaching end of stream", .{});
            self.emit(t, .Error, err_msg, &self.prev_position);
            return;
        };

        switch (b) {
            '.' => {
                _ = self.popState();
                self.emit(t, .Dot, null, &self.lex_start);
            },
            '=' => {
                self.popNState(2);
                self.pushStateOrStop(lexValue, t);
            },
            else => {
                const err_msg = self.formatError("Lexer: expected '=' or '.' found '{c}'", .{b});
                self.emit(t, .Error, err_msg, &self.prev_position);
                return;
            },
        }
    }

    /// lex a bare key.
    fn lexBareKey(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                break;
            };

            if (!common.isBareKeyChar(b)) {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                // In case of an error clear the state stack and update the token to an error token.
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return;
            };
        }
        const current = self.popState();
        assert(current == lexBareKey);
        self.emit(t, .Key, self.token_buffer.data(), &self.lex_start);
    }

    fn lexQuottedKey(self: *Self, t: *Token) void {
        const current = self.popState();
        assert(current == lexQuottedKey);
        const b = self.nextByte() catch unreachable;
        switch (b) {
            '"' => self.pushStateOrStop(lexBasicString, t),
            '\'' => self.pushStateOrStop(lexLiteralString, t),
            else => unreachable,
        }
    }

    fn lexValue(self: *Self, t: *Token) void {
        _ = self.popState();
        self.skipBytes(&[_]u8{ ' ', '\t' });
        const b = self.nextByte() catch {
            const err_msg = self.formatError("Lexer: expected a value before reaching end of stream", .{});
            self.emit(t, .Error, err_msg, &self.prev_position);
            return;
        };
        if (common.isDigit(b)) {
            self.toLastByte();
            self.pushStateOrStop(lexNumber, t);
            return;
        }
        switch (b) {
            '[' => {
                self.pushStateOrStop(lexArrayValue, t);
                self.emit(t, .ArrayStart, null, &self.lex_start);
            },
            '{' => {
                self.pushStateOrStop(lexInlineTabValue, t);
                self.emit(t, .InlineTableStart, null, &self.lex_start);
            },
            '"' => {
                if (self.consumeByte('"')) {
                    if (self.consumeByte('"')) {
                        self.pushStateOrStop(lexMultiLineBasicString, t);
                        return;
                    } else {
                        self.toLastByte();
                    }
                }
                self.pushStateOrStop(lexBasicString, t);
            },
            '\'' => {
                if (self.consumeByte('\'')) {
                    if (self.consumeByte('\'')) {
                        self.pushStateOrStop(lexMultiLineLiteralString, t);
                        return;
                    } else {
                        self.toLastByte();
                    }
                }
                self.pushStateOrStop(lexLiteralString, t);
            },
            'i', 'n' => {
                self.toLastByte();
                self.pushStateOrStop(lexFloat, t);
            },
            '-', '+' => {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                };
                self.pushStateOrStop(lexDecimalInteger, t);
            },
            't', 'f' => {
                self.toLastByte();
                self.pushStateOrStop(lexBoolean, t);
            },
            else => {
                const err_msg = self.formatError("Lexer: expected a value after '=' found '{c}'", .{b});
                self.emit(t, .Error, err_msg, &self.prev_position);
                return;
            },
        }
    }

    /// lex the string content between it's delimiters '"'.
    fn lexBasicString(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: reached end of stream before string delimiter \" ",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            };
            if (common.isNewLine(b)) {
                const err_msg = self.formatError(
                    "Lexer: basic string can't contain a newline character 0x{X:0>2}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }
            if (common.isControl(b)) {
                const err_msg = self.formatError("Lexer: control character '{}' not allowed in basic strings", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }

            switch (b) {
                '"' => break,
                '\\' => self.lexStringEscape(t) catch return,
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexBasicString);
        self.emit(t, .BasicString, self.token_buffer.data(), &self.lex_start);
    }

    fn lexMultiLineBasicString(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: reached end of stream before multi-line string delimiter \"\"\" ",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            };
            if (common.isControl(b)) {
                const err_msg = self.formatError("Lexer: control character '{}' not allowed in basic strings", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
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
                                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                                    return;
                                };
                                _ = self.nextByte() catch unreachable;
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.toLastByte();
                        }
                    }
                },
                '\\' => self.lexMultiLineStringEscape(t) catch return,
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexMultiLineBasicString);
        self.emit(t, .MultiLineBasicString, self.token_buffer.data(), &self.lex_start);
    }

    /// lex the string content between it's delimiters `'`.
    fn lexLiteralString(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: reached end of stream before string delimiter ' ",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            };
            if (common.isControl(b)) {
                const err_msg = self.formatError("Lexer: control character '{}' not allowed in litteral strings", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }
            if (common.isNewLine(b)) {
                const err_msg = self.formatError(
                    "Lexer: litteral string can't contain a newline character 0x{X:0>2}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }
            switch (b) {
                '\'' => break,
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexLiteralString);
        self.emit(t, .LiteralString, self.token_buffer.data(), &self.lex_start);
    }

    fn lexMultiLineLiteralString(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: reached end of stream before multi-line string delimiter ''' ",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            };
            if (common.isControl(b)) {
                const err_msg = self.formatError("Lexer: control character '{}' not allowed in litteral strings", .{b});
                self.emit(t, .Error, err_msg, &self.lex_start);
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
                                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                                    return;
                                };
                                _ = self.nextByte() catch unreachable;
                                counter -= 1;
                            }
                            break;
                        } else {
                            self.toLastByte();
                        }
                    }
                },
                else => self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexMultiLineLiteralString);
        self.emit(t, .MultiLineLiteralString, self.token_buffer.data(), &self.lex_start);
    }

    /// Called when encountering a string escape sequence in a multi line string.
    /// assumes '\' is already consumed
    fn lexMultiLineStringEscape(self: *Self, t: *Token) !void {
        const b = self.peekByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected an escape sequence before end of stream",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.lex_start);
            return error.BadStringEscape;
        };
        if (common.isNewLine(b)) {
            _ = self.nextByte() catch unreachable;
            self.token_buffer.append(b) catch |e| {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return e;
            };
            return;
        }

        try self.lexStringEscape(t);
    }

    /// Called when encountering a string escape sequence
    /// assumes '\' is already consumed
    fn lexStringEscape(self: *Self, t: *Token) !void {
        const b = self.nextByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected an escape sequence before end of stream",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.lex_start);
            return error.BadStringEscape;
        };

        var hex: [10]u8 = undefined;
        hex[0] = '\\';

        const bytes: []const u8 = switch (b) {
            'b' => &[2]u8{ '\\', 'b' },
            'r' => &[2]u8{ '\\', 'r' },
            'n' => &[2]u8{ '\\', 'n' },
            't' => &[2]u8{ '\\', 't' },
            'f' => &[2]u8{ '\\', 'f' },
            '"' => &[2]u8{ '\\', '"' },
            '\\' => &[2]u8{ '"', '"' },
            'x' => blk: {
                hex[1] = 'x';
                if (!self.lexHexEscape(t, hex[2..])) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..4];
            },
            'u' => blk: {
                hex[1] = 'u';
                if (!self.lexUnicodeEscape(t, 4, hex[2..])) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..6];
            },
            'U' => blk: {
                hex[1] = 'U';
                if (!self.lexUnicodeEscape(t, 8, hex[2..])) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..10];
            },
            else => {
                const err_msg = self.formatError(
                    "Lexer: bad string escape sequence, \\{c}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return error.BadStringEscape;
            },
        };

        self.token_buffer.appendSlice(bytes) catch |e| {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
            return e;
        };
    }

    fn lexHexEscape(self: *Self, t: *Token, out: []u8) bool {
        for (0..2) |i| {
            const b = self.nextByte() catch {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit before end of stream",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return false;
            };

            if (!common.isHex(b)) {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit found {c}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
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
                    "Lexer: expected hexadecimal digit before end of stream",
                    .{},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
                return false;
            };

            if (!common.isHex(b)) {
                const err_msg = self.formatError(
                    "Lexer: expected hexadecimal digit found {c}",
                    .{b},
                );
                self.emit(t, .Error, err_msg, &self.lex_start);
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
        assert(current == lexNumber);

        // guaranteed digit.
        var b = self.nextByte() catch unreachable;
        self.token_buffer.append(b) catch {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
            return;
        };

        if (b == '0') {
            // possibly a base speceific number.
            const base = self.peekByte() catch 0x00;
            switch (base) {
                'b' => {
                    _ = self.nextByte() catch unreachable;
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                    self.pushStateOrStop(lexBinaryInteger, t);
                    return;
                },
                'o' => {
                    _ = self.nextByte() catch unreachable;
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                    self.pushStateOrStop(lexOctalInteger, t);
                    return;
                },
                'x' => {
                    _ = self.nextByte() catch unreachable;
                    self.token_buffer.append(base) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                    self.pushStateOrStop(lexHexInteger, t);
                    return;
                },
                else => {},
            }
        }

        while (true) {
            b = self.peekByte() catch break;

            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                };
                _ = self.nextByte() catch unreachable;
                continue;
            }

            switch (b) {
                '.', 'e', 'E' => {
                    self.pushStateOrStop(lexFloat, t);
                    return;
                },
                '-', ':' => {
                    self.pushStateOrStop(lexDateTime, t);
                    return;
                },
                else => break,
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0b is already consumed
    fn lexBinaryInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isBinary(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return;
            };
        }
        const current = self.popState();
        assert(current == lexBinaryInteger);
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0o is already consumed
    fn lexOctalInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isOctal(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return;
            };
        }
        const current = self.popState();
        assert(current == lexOctalInteger);
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDecimalInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isDigit(b) or b == '_') {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                };
                continue;
            }

            // preparing to return
            self.toLastByte();
            const current = self.popState();
            assert(current == lexDecimalInteger);

            switch (b) {
                '.', 'e', 'E', 'i', 'n' => {
                    // switch to lexing a float
                    self.pushStateOrStop(lexFloat, t);
                    return;
                },
                '-', ':' => {
                    self.pushStateOrStop(lexDateTime, t);
                    return;
                },
                else => break,
            }
        }
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes 0x is already consumed
    fn lexHexInteger(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (!common.isHex(b) and b != '_') {
                self.toLastByte();
                break;
            }

            self.token_buffer.append(b) catch {
                self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                return;
            };
        }
        const current = self.popState();
        assert(current == lexHexInteger);
        self.emit(t, .Integer, self.token_buffer.data(), &self.lex_start);
    }

    // lex float number
    fn lexFloat(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isDigit(b)) {
                self.token_buffer.append(b) catch {
                    self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                    return;
                };
                continue;
            }

            switch (b) {
                '-', '+', '_', 'e', 'E', '.' => {
                    self.token_buffer.append(b) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                    continue;
                },
                'i' => {
                    if (!self.consumeByte('n') or !self.consumeByte('f')) {
                        const err_msg = self.formatError("Lexer: Invalid float", .{});
                        self.emit(t, .Error, err_msg, &self.lex_start);
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'i', 'n', 'f' }) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                    break;
                },
                'n' => {
                    if (!self.consumeByte('a') or !self.consumeByte('n')) {
                        const err_msg = self.formatError("Lexer: Invalid float", .{});
                        self.emit(t, .Error, err_msg, &self.lex_start);
                        return;
                    }
                    self.token_buffer.appendSlice(&[_]u8{ 'n', 'a', 'n' }) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
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
        const current = self.popState();
        assert(current == lexFloat);
        self.emit(t, .Float, self.token_buffer.data(), &self.lex_start);
    }

    /// expects a boolean string
    /// assumes there is at least a byte in stream.
    fn lexBoolean(self: *Self, t: *Token) void {
        var initial = self.peekByte() catch unreachable;
        var boolean: [5]u8 = undefined;
        var count: usize = 0;
        switch (initial) {
            't' => {
                count = self.nextSlice(boolean[0..4]) catch unreachable;
                if (count != 4) {
                    const err_msg = self.formatError(
                        "Lexer: unexpected end of stream",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                }
                if (!mem.eql(u8, boolean[0..4], "true")) {
                    const err_msg = self.formatError(
                        "Lexer: Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                }
            },
            'f' => {
                count = self.nextSlice(&boolean) catch unreachable;
                if (count != 5) {
                    const err_msg = self.formatError(
                        "Lexer: unexpected end of stream",
                        .{},
                    );
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                }
                if (!mem.eql(u8, &boolean, "false")) {
                    const err_msg = self.formatError(
                        "Lexer: Expected boolean value found '{s}'",
                        .{boolean},
                    );
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                }
            },
            else => unreachable,
        }

        self.token_buffer.appendSlice(boolean[0..count]) catch {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
            return;
        };
        const current = self.popState();
        assert(current == lexBoolean);
        self.emit(t, .Boolean, self.token_buffer.data(), &self.lex_start);
    }

    fn lexDateTime(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;

            switch (b) {
                '0'...'9',
                ':',
                'T',
                't',
                ' ',
                '.',
                'Z',
                'z',
                '+',
                '-',
                => {
                    self.token_buffer.append(b) catch {
                        self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
                        return;
                    };
                },
                else => break,
            }
        }

        const current = self.popState();
        assert(current == lexDateTime);
        self.emit(t, .DateTime, self.token_buffer.data(), &self.lex_start);
    }

    /// assumes the starting bracket '[' was already consumed.
    fn lexArrayValue(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&[_]u8{ ' ', '\n', '\r', '\t' });
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrStop(lexComment, t);
                    return;
                },
                ',' => {
                    const err_msg = self.formatError("Lexer: Unexpected comma ',' inside array", .{});
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                },
                ']' => break,
                else => {
                    self.toLastByte();
                    self.pushStateOrStop(lexArrayValueEnd, t);
                    self.pushStateOrStop(lexValue, t);
                    return;
                },
            }
        }

        const current = self.popState();
        assert(current == lexArrayValue);

        self.emit(t, .ArrayEnd, null, &self.lex_start);
    }

    fn lexArrayValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.peekByte() catch break;
            if (common.isNewLine(b) or common.isWhiteSpace(b)) {
                self.skipBytes(&[_]u8{ ' ', '\n', '\r', '\t' });
                continue;
            }

            switch (b) {
                '#' => {
                    _ = self.nextByte() catch unreachable;
                    self.pushStateOrStop(lexComment, t);
                    return;
                },
                ',' => {
                    _ = self.nextByte() catch unreachable;
                    break;
                },
                ']' => break,
                else => {
                    const err_msg = self.formatError("Lexer: expected comma ',' or array closing bracket ']' found {c}", .{b});
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexArrayValueEnd);
    }

    /// assumes '{' is already consumed.
    fn lexInlineTabValue(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte() catch break;
            if (common.isNewLine(b)) {
                const err_msg = self.formatError("Lexer: Newline not allowed inside inline tables.", .{});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&[_]u8{ ' ', '\t' });
                continue;
            }

            switch (b) {
                '#' => {
                    self.pushStateOrStop(lexComment, t);
                    return;
                },
                ',' => {
                    const err_msg = self.formatError("Lexer: Unexpected comma ',' inside array", .{});
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                },
                '}' => break,
                else => {
                    self.toLastByte();
                    self.pushStateOrStop(lexInlineTabValueEnd, t);
                    self.pushStateOrStop(lexKey, t);
                    return;
                },
            }
        }

        const current = self.popState();
        assert(current == lexInlineTabValue);

        self.emit(t, .InlineTableEnd, null, &self.lex_start);
    }

    fn lexInlineTabValueEnd(self: *Self, t: *Token) void {
        while (true) {
            const b = self.peekByte() catch break;
            if (common.isNewLine(b)) {
                const err_msg = self.formatError("Lexer: Newline not allowed inside inline tables.", .{});
                self.emit(t, .Error, err_msg, &self.lex_start);
                return;
            }

            if (common.isWhiteSpace(b)) {
                self.skipBytes(&[_]u8{ ' ', '\t' });
                continue;
            }

            switch (b) {
                '#' => {
                    _ = self.nextByte() catch unreachable;
                    self.pushStateOrStop(lexComment, t);
                    return;
                },
                ',' => {
                    _ = self.nextByte() catch unreachable;
                    self.skipBytes(&[_]u8{ ' ', '\t' });
                    if (self.consumeByte('}')) {
                        const err_msg = self.formatError(
                            "Lexer: a trailing comma ',' is not permitted after the last key/value pair in an inline table.",
                            .{},
                        );
                        self.emit(t, .Error, err_msg, &self.lex_start);
                        return;
                    }
                    break;
                },
                '}' => break,
                else => {
                    const err_msg = self.formatError("Lexer: expected comma ',' or an inline table terminator '}}' found {c}", .{b});
                    self.emit(t, .Error, err_msg, &self.lex_start);
                    return;
                },
            }
        }
        const current = self.popState();
        assert(current == lexInlineTabValueEnd);
    }

    /// Used as a fallback when the lexer encounters an error.
    fn lexOnError(self: *Self, t: *Token) void {
        const err_msg = self.formatError("Lexer: Input Stream contains errors", .{});
        self.emit(t, .Error, err_msg, &self.position);
    }

    fn formatError(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
        self.token_buffer.clearContent();
        self.token_buffer.print(format, args) catch {
            return Self.ERR_MSG_GENERIC;
        };
        return self.token_buffer.data();
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
        if (f == lexTable) {
            return "lexTable";
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
        if (f == lexLiteralString) {
            return "lexLiteralString";
        }
        if (f == lexBasicString) {
            return "lexBasicString";
        }
        if (f == lexBareKey) {
            return "lexBareKey";
        }
        if (f == lexBoolean) {
            return "lexBoolean";
        }
        if (f == lexKey) {
            return "lexKeyStart";
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
        if (f == lexTableStart) {
            return "lexTableStart";
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

    // fn lexQuottedKey(self: *Self, t: *Token) void {
    // }

    pub fn init(allocator: mem.Allocator, input: *io.StreamSource) mem.Allocator.Error!Self {
        var state_func_stack = try Stack(?LexFuncPtr).initCapacity(allocator, 8);
        errdefer state_func_stack.deinit();
        state_func_stack.append(lexTable) catch unreachable; // we just allocated;
        return .{
            .input = input,
            .index = 0,
            .prev_position = .{ .line = 1, .offset = 0 },
            .position = .{ .line = 1, .offset = 0 },
            .lex_start = .{ .line = 1, .offset = 0 },
            .token_buffer = try common.DynArray(u8, null).initCapacity(
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

    pub fn nextToken(self: *Self, t: *Token) void {
        // the token buffer will be overwritten on every call
        // the caller should copy required data on emit.
        self.token_buffer.clearContent();
        while (true) {
            if (LOG_LEXER_STATE) {
                self.logState();
            }
            assert(self.state_func_stack.items.len > 0);
            const lexFunc = self.state_func_stack.getLast() orelse {
                // lexFunc == EMIT_FUNC == null
                _ = self.popState();
                break;
            };
            lexFunc(self, t);
        }
    }
};
