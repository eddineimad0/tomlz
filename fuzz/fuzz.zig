//! This file contains fuzzing code that will be called by afl++.
//! more info: https://www.ryanliptak.com/blog/fuzzing-zig-code/

const std = @import("std");
const tomlz = @import("tomlz");

pub fn main() !void {
    // Setup an allocator that will detect leaks/use-after-free/etc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will check for leaks and crash the program if it finds any
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };
    var parser = tomlz.Parser.init(&stream_source, allocator);
    defer parser.deinit();
    // Try to parse the data
    var parsed_table = try parser.parse();
    _ = parsed_table;
}

pub fn cMain() callconv(.C) c_int {
    main() catch unreachable;
    return 0;
}

comptime {
    @export(cMain, .{ .name = "main", .linkage = .Strong });
}
