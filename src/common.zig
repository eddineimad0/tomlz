//! Contains useful types and functions used by the library.

const std = @import("std");
const ascii = std.ascii;
const unicode = std.unicode;
const fmt = std.fmt;

pub const Allocator = std.mem.Allocator;
pub const String8 = std.ArrayList(u8);

/// Wrapper over std.ArrayList, makes it easy to expand the size.
/// the destructor argument is a function used when clearing the array.
pub fn DynArray(comptime T: type) type {
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
            try self.resize(self.impl.capacity *| 2);
        }

        pub fn append(self: *Self, item: T) Allocator.Error!void {
            if (self.isFull() and self.size() != 0) {
                try self.doubleCapacity();
            }
            self.impl.append(item) catch unreachable;
        }

        pub inline fn popOrNull(self: *Self) ?T {
            return self.impl.popOrNull();
        }

        pub fn appendSlice(self: *Self, slice: []const T) Allocator.Error!void {
            if (self.isFull() or (self.impl.items.len +| slice.len > self.impl.capacity)) {
                try self.doubleCapacity();
            }
            self.impl.appendSlice(slice) catch unreachable;
        }

        pub inline fn clearContent(self: *Self) void {
            self.impl.clearRetainingCapacity();
        }

        pub inline fn data(self: *const Self) []const T {
            return self.impl.items;
        }

        pub inline fn getLastOrNull(self: *Self) ?*T {
            if (self.impl.items.len == 0) return null;

            return &self.impl.items[self.impl.items.len - 1];
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

        pub inline fn size(self: *const Self) usize {
            return self.impl.items.len;
        }

        pub inline fn writer(self: *Self) Implementation.Writer {
            return self.impl.writer();
        }

        pub inline fn toOwnedSlice(self: *Self) Allocator.Error![]T {
            return try self.impl.toOwnedSlice();
        }

        pub fn resize(self: *Self, new_capacity: usize) Allocator.Error!void {
            try self.impl.ensureTotalCapacity(new_capacity);
        }
    };
}

/// Holds necessary informations about a position in the stream.
pub const Position = struct {
    line: usize, // The line number in the current stream.
    column: usize, // Byte offset into the line

    const Self = @This();

    pub fn toString(self: *const Self, allocator: Allocator) fmt.AllocPrintError![]u8 {
        return fmt.allocPrint(allocator, "line:{%d},offset:{%d}", .{ self.line, self.column });
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

/// parses a the unicode codepoint in bytes, encodes it and store
/// it back in bytes slice.
pub inline fn toUnicodeCodepoint(bytes: []u8) !usize {
    const codepoint = try fmt.parseInt(u21, bytes, 16);
    return try unicode.utf8Encode(codepoint, bytes);
}

/// Intended for fast parsing of a sequence of ascii digits in base 10.
/// Negative numbers aren't supported.
/// use only to parse toml date or timestamp.
pub fn parseDigits(comptime T: type, buff: []const u8) error{NotANumber}!T {
    switch (@typeInfo(T)) {
        .Int => |IntType| switch (IntType.signedness) {
            .unsigned => {},
            .signed => @compileError("parseDigits doesn't support signed integers"),
        },
        else => @compileError("parseDigits only support unsigned integers"),
    }
    var num: T = @as(T, 0);
    for (0..buff.len) |i| {
        if (!ascii.isDigit(buff[i])) {
            return error.NotANumber;
        }
        num *= 10;
        num += (buff[i] - '0');
    }
    return num;
}

pub inline fn isDateValid(year: u16, month: u8, day: u8) bool {
    if (month > 12 or day == 0 or month == 0) {
        return false;
    }

    // This assumes that the year is a 4 digits year.
    const year_by_100 = @rem(year, 100);
    var is_leap = (year >> 2 == 0 and (year_by_100 != 0 or year_by_100 >> 2 == 0));

    switch (month) {
        2 => {
            if (day > 29) {
                return false;
            } else if (!is_leap and day > 28) {
                return false;
            }
        },
        4, 6, 9, 11 => {
            if (day > 30) {
                return false;
            }
        },
        else => {
            if (day > 31) {
                return false;
            }
        },
    }
    return true;
}

pub inline fn isTimeValid(hour: u8, minute: u8, second: u8) bool {
    if (hour > 23 or minute > 59 or second > 59) {
        return false;
    }
    return true;
}

pub fn parseNanoSeconds(src: []const u8, ns: *u32) usize {
    ns.* = 0;
    var offset: u32 = 100000000;
    for (0..src.len) |i| {
        if (ascii.isDigit(src[i])) {
            ns.* += (src[i] - '0') * offset;
            offset /= 10;
        } else {
            return i;
        }
    }
    return src.len;
}

pub const isValidUTF8 = unicode.utf8ValidateSlice;
