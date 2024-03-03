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
    CommentStart,
    String,
    MultilineString,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    pos: common.Position,
};

const Lexer = struct {
    input: io.StreamSource,
    index: usize, // current read index into the input.
    pos: common.Position,
    prev_pos: common.Position,

    const Self = @This();

    pub fn init(input: io.StreamSource) Self {
        return Self{
            .input = input,
            .index = 0,
            .prev_pos = .{ .line = 1, .offset = 0 },
            .pos = .{ .line = 1, .offset = 0 },
        };
    }

    // pub fn deinit(self:*Self)void{
    // }
    //
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
            return 0;
        };
        // TODO: handle control characters.
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
    fn consumeOrRewind(self: *Self, predicate: u8) bool {
        if (self.nextByte() == predicate) {
            return true;
        } else {
            self.toLastByte();
            return false;
        }
    }

    fn lexRoot(self: *Self) void {
        const b = self.nextByte();
        if (common.isWhiteSpace(b) or common.isNewLine(b)) {
            // Skip.
        }
        switch (b) {
            0 => {},
            '#' => self.lexComment(),
            else => {
                // probably a key
                self.toLastByte();
                self.lexKey();
            },
        }
    }

    fn lexComment(self: *Self) void {
        _ = self;
    }

    fn lexKey(self: *Self) void {
        _ = self;
    }
};
