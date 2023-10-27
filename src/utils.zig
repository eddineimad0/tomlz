const std = @import("std");
const ascii = std.ascii;

/// Intended for fast parsing of a sequence of ascii digits in base 10.
/// Negative numbers aren't supported.
/// use only to parse toml date or timestamp.
pub fn parseDigits(comptime T: type, buff: []const u8) !T {
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
