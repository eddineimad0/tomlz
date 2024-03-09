const std = @import("std");
const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const log = std.log;
const common = @import("common.zig");
const assert = std.debug.assert;
const Stack = std.ArrayList;

pub const TokenType = enum {
    EOF,
    Integer,
    Float,
    Bool,
    DateTime,
    ArrayStart,
    ArrayEnd,
    TableStart,
    TableEnd,
    ArrayTableStart,
    ArrayTableEnd,
    InlineTableStart,
    InlineTableEnd,
    Comment,
    BasicString,
    MultilineString,
    Error,
    Key,
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
    lex_start: common.Position, // position from where we started lexing the current token.
    token_buffer: common.String8,
    state_func_stack: Stack(?LexFuncPtr),
    is_at_eof: bool,

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
        // if (self.is_at_eof) {
        //     return error.EndOfStream;
        // }
        const r = self.input.reader();
        const b = r.readByte() catch |err| {
            self.is_at_eof = true;
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

    fn lexRoot(self: *Self, t: *Token) void {
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
                self.pushStateOrStop(lexKeyStart, t);
            },
        }
    }

    /// Lexes an entire comment up to the newline character.
    /// the token value is not populated by the comment text,
    /// but rather set to null.
    fn lexComment(self: *Self, t: *Token) void {
        // self.updateStartPosition();
        _ = t;
        while (true) {
            const b = self.nextByte() catch {
                break;
            };

            if (common.isNewLine(b)) {
                break;
            }
        }
        // TODO: should we emit the token.
        // emitToken(t, .Comment, null, self.lex_start);
        const last_func = self.popState();
        assert(last_func == lexComment);
    }

    fn lexTableStart(self: *Self, t: *Token) void {
        _ = t;
        _ = self;
    }

    /// Handles lexing a key and calls the next appropriate function
    /// this function assumes that there is at least one byte in the stream
    fn lexKeyStart(self: *Self, t: *Token) void {
        const b = self.peekByte() catch unreachable;
        self.pushStateOrStop(lexKeyEnd, t);
        switch (b) {
            '=', '.' => {
                const err_msg = self.formatError("Lexer: expected a key name found '{c}' ", .{b});
                self.emit(t, .Error, err_msg, &self.position);
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
            },
            '=' => {
                self.popNState(2);
                self.pushStateOrStop(lexValue, t);
            },
            else => {
                const err_msg = self.formatError("Lexer: expected '=' or '.' found '{c}'", .{b});
                self.emit(t, .Error, err_msg, &self.prev_position);
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
            };
        }
        const current = self.popState();
        assert(current == lexBareKey);
        self.emit(t, .Key, self.token_buffer.items, &self.lex_start);
    }

    fn lexQuottedKey(self: *Self, t: *Token) void {
        _ = t;
        _ = self;
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
            // self.pushStateOrStop(, t: *Token)
        }
        switch (b) {
            '[' => {},
            '{' => {},
            '"' => self.pushStateOrStop(lexBasicString, t),
            '\'' => {},
            '-', '+' => {},
            else => {},
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
        self.emit(t, .BasicString, self.token_buffer.items, &self.lex_start);
    }

    /// Called when encountering a string escape sequence
    /// assumes '\' is already consumed
    fn lexStringEscape(self: *Self, t: *Token) !void {
        var wr = self.token_buffer.writer();
        const b = self.nextByte() catch {
            const err_msg = self.formatError(
                "Lexer: expected an escape sequence before end of stream",
                .{},
            );
            self.emit(t, .Error, err_msg, &self.lex_start);
            return error.BadStringEscape;
        };

        var hex: [8]u8 = undefined;

        const bytes: []const u8 = switch (b) {
            'b' => &[2]u8{ '\\', 'b' },
            'r' => &[2]u8{ '\\', 'r' },
            'n' => &[2]u8{ '\\', 'n' },
            't' => &[2]u8{ '\\', 't' },
            'f' => &[2]u8{ '\\', 'f' },
            '"' => &[2]u8{ '\\', '"' },
            '\\' => &[2]u8{ '"', '"' },
            'x' => blk: {
                if (!self.lexHexEscape(t, @ptrCast(&hex))) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..2];
            },
            'u' => blk: {
                if (!self.lexUnicodeEscape(t, 4, @as(*[4]u8, @ptrCast(&hex)))) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..4];
            },
            'U' => blk: {
                if (!self.lexUnicodeEscape(t, 8, &hex)) {
                    // error already reported
                    return error.BadStringEscape;
                }
                break :blk hex[0..8];
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

        _ = wr.write(bytes) catch |e| {
            self.emit(t, .Error, ERR_MSG_OUT_OF_MEMORY, &self.lex_start);
            return e;
        };
    }

    fn lexHexEscape(self: *Self, t: *Token, out: *[2]u8) bool {
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

    fn lexUnicodeEscape(self: *Self, t: *Token, comptime width: u8, out: *[width]u8) bool {
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

    /// Used as a fallback when the lexer encounters an error.
    fn lexOnError(self: *Self, t: *Token) void {
        const err_msg = self.formatError("Lexer: Input Stream contains errors", .{});
        self.emit(t, .Error, err_msg, &self.position);
    }

    fn formatError(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
        self.token_buffer.clearRetainingCapacity();
        var tok_wr = self.token_buffer.writer();
        tok_wr.print(format, args) catch {
            return Self.ERR_MSG_GENERIC;
        };
        return self.token_buffer.items;
    }

    // fn lexQuottedKey(self: *Self, t: *Token) void {
    // }

    pub fn init(allocator: mem.Allocator, input: *io.StreamSource) mem.Allocator.Error!Self {
        var state_func_stack = try Stack(?LexFuncPtr).initCapacity(allocator, 8);
        errdefer state_func_stack.deinit();
        state_func_stack.append(lexRoot) catch unreachable; // we just allocated;
        return .{
            .input = input,
            .index = 0,
            .prev_position = .{ .line = 1, .offset = 0 },
            .position = .{ .line = 1, .offset = 0 },
            .lex_start = .{ .line = 1, .offset = 0 },
            // TODO: move this constant to config module.
            .is_at_eof = false,
            .token_buffer = try common.String8.initCapacity(allocator, 1024),
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
        self.token_buffer.clearRetainingCapacity();
        while (true) {
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
