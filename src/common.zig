//! Contains useful types and functions used by the library.

const std = @import("std");
const ascii = std.ascii;
const unicode = std.unicode;
const fmt = std.fmt;

pub const Allocator = std.mem.Allocator;
pub const String8 = std.ArrayList(u8);

/// Wrapper over std.ArrayList, makes it easy to expand the size.
/// the destructor argument is a function used when clearing the array.
pub fn DynArray(comptime T: type, comptime destructor: ?*const fn (*T) void) type {
    return struct {
        const Implementation = std.ArrayList(T);
        impl: Implementation,

        const Self = @This();

        pub fn initCapacity(allocator: Allocator, initial_capacity: usize) Allocator.Error!Self {
            return .{
                .impl = try Implementation.initCapacity(allocator, initial_capacity),
            };
        }

        pub inline fn isFull(self: *Self) bool {
            return self.impl.items.len == self.impl.capacity;
        }

        fn doubleCapacity(self: *Self) Allocator.Error!void {
            try self.impl.ensureTotalCapacityPrecise(self.impl.capacity *| 2);
        }

        pub fn append(self: *Self, byte: T) Allocator.Error!void {
            if (self.isFull()) {
                try self.doubleCapacity();
            }
            self.impl.append(byte) catch unreachable;
        }

        pub fn appendSlice(self: *Self, slice: []const T) Allocator.Error!void {
            if (self.isFull() or (self.impl.items.len +| slice.len > self.impl.capacity)) {
                try self.doubleCapacity();
            }
            self.impl.appendSlice(slice) catch unreachable;
        }

        pub inline fn clearContent(self: *Self) void {
            if (destructor) |destroy| {
                for (self.impl.items) |*item| {
                    destroy(item);
                }
            }
            self.impl.clearRetainingCapacity();
        }

        pub inline fn data(self: *const Self) []const T {
            return self.impl.items;
        }

        pub inline fn print(self: *Self, comptime format: []const u8, args: anytype) !void {
            var wr = self.impl.writer();
            try wr.print(format, args);
        }

        pub fn deinit(self: *Self) void {
            self.clearContent();
            self.impl.deinit();
        }

        pub fn getOrNull(self: *Self, index: usize) ?*T {
            if (index >= self.impl.items.len) {
                return null;
            }
            return &self.impl.items[index];
        }

        pub fn size(self: *const Self) usize {
            return self.impl.items.len;
        }
    };
}

/// Holds necessary informations about a position in the stream.
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

pub inline fn isBinary(byte: u8) bool {
    return (byte == '0' or byte == '1');
}

pub inline fn isOctal(byte: u8) bool {
    return switch (byte) {
        '0'...'7' => true,
        else => false,
    };
}

pub inline fn isWhiteSpace(byte: u8) bool {
    return (byte == ' ' or byte == '\t');
}

pub inline fn isNewLine(byte: u8) bool {
    return (byte == '\n' or byte == '\r');
}

pub inline fn isBareKeyChar(c: u8) bool {
    return (ascii.isAlphanumeric(c) or c == '-' or c == '_');
}

pub inline fn toUnicodeCodepoint(bytes: []const u8) !u32 {
    const codepoint = try fmt.parseInt(u21, bytes, 16);
    if (!unicode.utf8ValidCodepoint(codepoint)) {
        return error.InvalidUnicodeCodepoint;
    }
    return @intCast(codepoint);
}
