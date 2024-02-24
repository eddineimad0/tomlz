//! This file is intended to be used with the toml test suite.
const std = @import("std");
const tomlz = @import("tomlz");
const os = std.os;
const io = std.io;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdin = io.getStdIn();

    const input = stdin.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |e| {
        std.log.err("Allocation failure, Error={}", .{e});
        os.exit(1);
    };
    defer allocator.free(input);

    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(input) };
    var parser = tomlz.Parser.init(&stream_source, allocator);
    defer parser.deinit();

    // Try to parse the data
    var parsed_table = parser.parse() catch |e| {
        std.log.err("Allocation failure, Error={}", .{e});
        os.exit(1);
    }; // compile in debug so we can crash.
    _ = parsed_table;

    // TODO: the test suite expects json output.
    os.exit(0);
}
