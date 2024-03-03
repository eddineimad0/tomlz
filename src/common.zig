//! Contains useful types and functions used by the library.

const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;

pub const Allocator = std.mem.Allocator;
pub const String8 = std.ArrayList(u8);

pub const Position = struct {
    line: usize, // The line number in the current stream.
    offset: usize, // Byte offset into the line

    const Self = @This();

    pub fn toString(self: *const Self, allocator: Allocator) fmt.AllocPrintError![]u8 {
        return fmt.allocPrint(allocator, "line:{%d},offset:{%d}", .{ self.line, self.offset });
    }
};

pub inline fn isControl(byte: u8) bool {
    return switch (byte) {
        '\t', '\r', '\n' => false, // exceptions in toml.
        else => ascii.isControl(byte),
    };
}

pub const isHex = ascii.isHex;
pub const isDigit = ascii.isDigit;

pub inline fn isWhiteSpace(byte: u8) bool {
    return (byte == ' ' or byte == '\t');
}

pub inline fn isNewLine(byte: u8) bool {
    return (byte == '\n' or byte == '\r');
}
