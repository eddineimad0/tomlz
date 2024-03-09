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
    String,
    MultilineString,
    Error,
    Key,
};

pub const Token = struct {
    type: TokenType,
    value: ?[]const u8,
    start: common.Position,
};

fn emitToken(t: *Token, token_type: TokenType, value: ?[]const u8, pos: *const common.Position) void {
    // @memcpy(&t.start, &pos);
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
    const GENERIC_ERR_MSG: []const u8 = "Lexer: Encounterd an error.";
    const OUT_OF_MEMORY_ERR_MSG: []const u8 = "Lexer: Ran out of memory.";
    const EMIT_FUNC: ?LexFuncPtr = null;

    inline fn pushStateOrStop(self: *Self, f: ?LexFuncPtr, t: *Token) void {
        self.state_func_stack.append(f) catch {
            // In case of an error clear the state stack and update the token to an error token.
            emitToken(t, .Error, OUT_OF_MEMORY_ERR_MSG, &self.lex_start);
            self.state_func_stack.clearRetainingCapacity();
        };
    }

    inline fn popState(self: *Self) ?LexFuncPtr {
        return self.state_func_stack.pop();
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
                skip = (b == predicate);
            }

            if (!skip) {
                break;
            }
        }
        self.toLastByte();
    }

    fn lexRoot(self: *Self, t: *Token) void {
        const b = self.nextByte() catch {
            emitToken(t, .EOF, null, &self.position);
            self.pushStateOrStop(EMIT_FUNC, t);
            return;
        };

        if (common.isControl(b)) {
            const err_msg = self.formatError("Stream contains control character 0x{x:0>2}", .{b});
            emitToken(t, .Error, err_msg, &self.prev_position);
            self.state_func_stack.clearRetainingCapacity();
            return;
        } else if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            self.skipBytes(&[_]u8{ '\n', '\r', '\t', ' ' });
            self.lexRoot(t);
        }

        switch (b) {
            '#' => {
                self.updateStartPosition();
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
        switch (b) {
            '=', '.' => {
                const err_msg = self.formatError("Lexer: expected a key name found '{c}' ", .{b});
                emitToken(t, .Error, err_msg, &self.position);
                self.state_func_stack.clearRetainingCapacity();
            },
            '"', '\'' => {
                self.pushStateOrStop(lexQuottedKey, t);
            },
            else => {
                self.pushStateOrStop(lexBareKey, t);
            },
        }
    }

    fn lexKeyEnd(self: *Self, t: *Token) void {
        self.skipBytes(&[_]u8{' '});
        const b = self.nextByte() catch {
            const err_msg = self.formatError("Lexer: expected '=' before reaching end of stream", .{});
            emitToken(t, .Error, err_msg, &self.prev_position);
            self.pushStateOrStop(EMIT_FUNC, t);
            return;
        };

        switch (b) {
            '.' => {
                _ = self.popState();
            },
            '=' => {
                self.popNState(2);
            },
            else => {
                const err_msg = self.formatError("Lexer: expected '=' or '. found {c}", .{b});
                emitToken(t, .Error, err_msg, &self.prev_position);
                self.pushStateOrStop(EMIT_FUNC, t);
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
                emitToken(t, .Error, OUT_OF_MEMORY_ERR_MSG, &self.lex_start);
                self.state_func_stack.clearRetainingCapacity();
            };
        }
        emitToken(t, .Key, self.token_buffer.items, &self.lex_start);

        // Suppose we are at the key's end
        self.pushStateOrStop(lexKeyEnd, t);
        self.pushStateOrStop(EMIT_FUNC, t);
    }

    fn lexQuottedKey(self: *Self, t: *Token) void {
        _ = t;
        _ = self;
    }

    fn formatError(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
        self.token_buffer.clearRetainingCapacity();
        var tok_wr = self.token_buffer.writer();
        tok_wr.print(format, args) catch {
            return Self.GENERIC_ERR_MSG;
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
        while (true) {
            if (self.state_func_stack.items.len == 0) {
                // Lexer found an error.
                log.debug("Lexer: function stack is empty\n", .{});
                break;
            } else {
                const lexFunc = self.state_func_stack.getLast() orelse {
                    // lexFunc == EMIT_FUNC == null
                    _ = self.popState();
                    break;
                };
                lexFunc(self, t);
            }
        }
    }
};
