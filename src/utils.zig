const std = @import("std");
const ascii = std.ascii;

// Intended for fast parsing of a sequence of ascii digits in base 10.
// use only to parse date or timestamp.
pub fn parseDigits(comptime T: type, buff: []const u8) !T {
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
