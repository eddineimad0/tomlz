const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;

pub const CharUTF8 = struct {
    bytes: ?[4]u8,
    codepoint: u21,
    len: u8,

    const Self = @This();

    pub fn init(codepoint: u21, len: u8) !Self {
        return .{
            .bytes = null,
            .codepoint = codepoint,
            .len = len,
        };
    }

    pub inline fn eqlBytes(self: *const Self, other: []const u8) bool {
        return mem.eql(u8, self.slice(), other);
    }

    pub inline fn eqlCodepoint(self: *const Self, other: u21) bool {
        return self.codepoint == other;
    }

    pub inline fn slice(self: *Self) []const u8 {
        if (self.bytes) |array| {
            return array[0..self.len];
        } else {
            var encoded: [4]u8 = undefined;
            var len: u8 = unicode.utf8Encode(self.codepoint, &encoded) catch {
                return "";
            };
            std.debug.assert(len == self.len);
            self.bytes = encoded;
            return self.bytes.?[0..self.len];
        }
    }
};
