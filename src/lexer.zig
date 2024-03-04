const std = @import("std");
const io = std.io;
const mem = std.mem;
const common = @import("common.zig");
const assert = std.debug.assert;

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
    start_pos: common.Position,
    end_pos: common.Position,

    const Self = @This();

    pub inline fn setStartPosition(self: *Self, pos: *const common.Position) void {
        @memcpy(&self.start_pos, &pos);
    }

    pub inline fn setEndPosition(self: *Self, pos: *const common.Position) void {
        @memcpy(&self.end_pos, &pos);
    }
};

const LexerState = enum {
    LexRoot,
};

const Lexer = struct {
    input: io.StreamSource,
    index: usize, // current read index into the input.
    pos: common.Position,
    prev_pos: common.Position,
    cntxt: struct {
        state: LexerState,
        state_func: LexFuncPtr,
    },

    const Self = @This();
    const LexFuncPtr = *const fn (self: *Self, t: *Token) void;
    const EOF: u8 = 0;

    // pub fn deinit(self:*Self)void{
    // }

    inline fn updateState(self: *Self, s: LexerState, f: LexFuncPtr) void {
        self.cntxt.state = s;
        self.cntxt.state_func = f;
    }

    inline fn updatePrevPosition(self: *Self) void {
        @memcpy(&self.prev_pos, &self.pos);
    }

    inline fn rewindPosition(self: *Self) void {
        @memcpy(&self.pos, self.prev_pos);
    }

    /// Reads and return the next byte in the stream
    /// if it encounters and an end of steam the null byte is returned.
    fn nextByte(self: *Self) u8 {
        const r = self.input.reader();
        const b = r.readByte() catch {
            return EOF;
        };
        if (common.isControl(b)) {
            // TODO: error message.
            return 0;
        }
        self.index += 1;
        self.updatePrevByte(b);
        if (b == '\n') {
            self.pos.line += 1;
            self.pos.offset += 0;
        } else {
            self.pos.offset += 1;
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

    fn peekByte(self: *Self) u8 {
        const b = self.nextByte();
        self.toLastByte();
        return b;
    }

    /// consume the next byte only if it is equal to the `predicate`
    /// otherwise it does nothing.
    fn consume(self: *Self, predicate: u8) bool {
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

    fn lexRoot(self: *Self, t: *Token) void {
        const b = self.nextByte();
        if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            self.skipBytes(&[_]u8{ '\n', '\r', '\t', ' ' });
            self.lexRoot(t);
        }
        switch (b) {
            EOF => {
                t.setStartPosition(self.pos);
                t.setEndPosition(self.pos);
                t.type = .EOF;
                t.value = null;
            },
            '#' => {
                t.setStartPosition(&self.prev_pos);
                self.lexComment(t);
            },
            else => {
                // probably a key
                self.toLastByte();
                self.lexKey(t);
            },
        }
    }

    /// Lexes an entire comment up to the newline character.
    /// the token value is not populated by the comment text,
    /// but rather set to null.
    fn lexComment(self: *Self, t: *Token) void {
        while (true) {
            const b = self.nextByte();
            if (common.isNewLine(b) or b == EOF) {
                break;
            }
        }
        t.setEndPosition(&self.prev_pos);
        t.type = .Comment;
        t.value = null;
    }

    fn lexKey(self: *Self, t: *Token) void {
        _ = t;
        _ = self;
    }

    pub fn init(input: io.StreamSource) Self {
        return Self{
            .input = input,
            .index = 0,
            .prev_pos = .{ .line = 1, .offset = 0 },
            .pos = .{ .line = 1, .offset = 0 },
            .cntxt = .{ .state = .LexRoot, .state_func = lexRoot },
        };
    }
    pub fn nextToken(self: *Self, t: *Token) void {
        self.cntxt.state_func(self, t);
    }
};
