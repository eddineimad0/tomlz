const std = @import("std");
const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
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
};

pub const Token = struct {
    type: TokenType,
    value: ?[]const u8,
    start: common.Position,
};

fn emitToken(t: *Token, token_type: TokenType, value: ?[]const u8, pos: *common.Position) void {
    @memcpy(&t.start, &pos);
    t.type = token_type;
    t.value = value;
}

const Lexer = struct {
    input: io.StreamSource,
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
    const GENERIC_ERROR: []const u8 = "Lexer: Encounterd an error.";
    const OUT_OF_MEMORY_ERR_MSG: []const u8 = "Lexer: Ran out of memory.";
    const EMIT_FUNC: ?LexFuncPtr = null;

    inline fn updateStateOrStop(self: *Self, f: ?LexFuncPtr, t: *Token) void {
        self.state_func_stack.append(f) catch {
            // In case of an error clear the state stack and update the token to an error token.
            emitToken(t, .Error, OUT_OF_MEMORY_ERR_MSG, self.lex_start);
            self.state_func_stack.clearRetainingCapacity();
        };
    }

    inline fn unwindState(self: *Self) ?LexFuncPtr {
        self.state_func_stack.pop();
    }

    inline fn updatePrevPosition(self: *Self) void {
        @memcpy(&self.prev_pos, &self.pos);
    }

    inline fn updateStartPosition(self: *Self) void {
        @memcpy(&self.lex_start, &self.pos);
    }

    inline fn rewindPosition(self: *Self) void {
        @memcpy(&self.pos, self.prev_pos);
    }

    /// Reads and return the next byte in the stream
    /// if it encounters and an end of steam the null byte is returned.
    fn nextByte(self: *Self) u8 {
        if (self.is_at_eof) {
            return EOF;
        }
        const r = self.input.reader();
        const b = r.readByte() catch {
            self.is_at_eof = true;
            return EOF;
        };
        self.index += 1;
        self.updatePrevPosition(self.position);
        if (b == '\n') {
            self.position.line += 1;
            self.position.offset = 0;
        } else {
            self.position.offset += 1;
        }
        return b;
    }

    /// Rewind the stream position to the by 1 bytes
    fn toLastByte(self: *Self) void {
        assert(self.index > 0);
        self.index -= 1;
        self.input.seekTo(self.index) catch unreachable;
        self.rewindPosition();
    }

    /// Returns the value of the next byte in the stream without modifying
    /// the current read index in the stream.
    fn peekByte(self: *Self) u8 {
        const b = self.nextByte();
        self.toLastByte();
        return b;
    }

    /// consume the next byte only if it is equal to the `predicate`
    /// otherwise it does nothing.
    fn consumeByte(self: *Self, predicate: u8) bool {
        if (self.nextByte() == predicate) {
            return true;
        } else {
            self.toLastByte();
            return false;
        }
    }

    /// Reads ahead in the stream and ignore any byte in `bytes_to_skip`.
    fn skipBytes(self: *Self, bytes_to_skip: []const u8) void {
        while (true) {
            const b = self.nextByte();
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

    fn lexRoot(self: *Self, t: *Token, prev: LexFuncPtr) void {
        _ = prev;
        const b = self.nextByte();
        if (common.isControl(b)) {
            const err_msg = self.formatError("Stream contains control character 0x{x:0>2}", .{b});
            emitToken(t, .Error, err_msg, self.prev_position);
            self.state_func_stack.clearRetainingCapacity();
            return;
        } else if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            self.skipBytes(&[_]u8{ '\n', '\r', '\t', ' ' });
            self.lexRoot(t);
        }
        switch (b) {
            EOF => {
                emitToken(t, .EOF, null);
                self.updateStateOrStop(EMIT_FUNC, t);
            },
            '#' => {
                self.updateStartPosition();
                self.updateStateOrStop(lexComment, t);
            },
            else => {
                self.toLastByte();
                self.updateStateOrStop(lexKey, t);
            },
        }
    }

    /// Lexes an entire comment up to the newline character.
    /// the token value is not populated by the comment text,
    /// but rather set to null.
    fn lexComment(self: *Self, t: *Token) void {
        _ = t;
        while (true) {
            const b = self.nextByte();
            if (common.isNewLine(b) or b == EOF) {
                break;
            }
        }
        // TODO: should we emit the token.
        // emitToken(t, .Comment, null, self.lex_start);
        const last_func = self.unwindState();
        assert(last_func == lexComment);
    }

    fn lexKey(self: *Self, t: *Token) void {
        _ = t;
        const b = self.peekByte();
        switch (b) {
            '=', EOF => {}, // error
            '.' => {}, // error
            '"', '\'' => self.consumeByte(b),
            else => {},
        }
    }

    /// lex on part of a bare key.
    fn lexBareKey(self: *Self) void {
        while (true) {
            const b = self.nextByte();
            if (!common.isBareKeyChar(b)) {
                self.toLastByte();
                break;
            }
            self.token_buffer.append(b);
        }
    }

    fn formatError(self: *Self, comptime format: []const u8, args: anytype) []const u8 {
        self.token_buffer.clearRetainingCapacity();
        var tok_wr = self.token_buffer.writer();
        tok_wr.print(format, args) catch {
            return Self.GENERIC_ERROR;
        };
        return self.token_buffer.items;
    }

    // fn lexQuottedKey(self: *Self, t: *Token) void {
    // }

    pub fn init(allocator: mem.Allocator, input: io.StreamSource) mem.Allocator.Error!Self {
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
            .state = .LexRoot,
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
                break;
            } else {
                const lexFunc = self.state_func_stack.getLast();
                if (lexFunc == EMIT_FUNC) {
                    _ = self.unwindState();
                    break;
                }
                lexFunc(self, t);
            }
        }
    }
};
