const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;

pub const EOS: u21 = std.math.maxInt(u21);
pub const UTF8_ERROR: u21 = 0xfffd;

pub const CharUTF8 = struct {
    bytes: ?[4]u8,
    codepoint: u21,
    len: u8,

    const Self = @This();

    pub fn init(codepoint: u21, len: u8) Self {
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

pub fn readUTF8Codepoint(reader: anytype, bytes_count: *u8) u21 {
    var buffer: [4]u8 = undefined;
    bytes_count.* = 0;

    buffer[0] = reader.readByte() catch
        return EOS;

    var count: u8 = unicode.utf8ByteSequenceLength(buffer[0]) catch
        return UTF8_ERROR;

    if (count == 1) {
        // ascii character
        bytes_count.* = 1;
        return buffer[0];
    } else {
        const red = reader.readAll(buffer[1..count]) catch {
            return UTF8_ERROR;
        };

        if (red + 1 != count) {
            // unfinished codepoint sequence.
            return UTF8_ERROR;
        }

        var codepoint: u21 = unicode.utf8Decode(buffer[0..count]) catch {
            return UTF8_ERROR;
        };

        bytes_count.* = count;
        return codepoint;
    }
}
