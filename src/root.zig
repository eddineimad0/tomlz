pub usingnamespace @import("datatypes.zig");

pub const Parser = @import("parser.zig").Parser;

test "all" {
    const testing = @import("std").testing;
    const lexer = @import("lexer.zig");

    testing.refAllDecls(lexer);
}
