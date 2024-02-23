const std = @import("std");
const tomlz = @import("tomlz");

comptime {
    @export(fuzzTomlzMain, .{ .name = "fuzz_tomlz_main", .linkage = .Strong });
}

// export the zig function so that it can be called from C
export fn fuzzTomlzMain() callconv(.C) void {
    // Setup an allocator that will detect leaks/use-after-free/etc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will check for leaks and crash the program if it finds any
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = stdin.readToEndAlloc(allocator, std.math.maxInt(usize)) catch unreachable;
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };
    var parser = tomlz.Parser.init(&stream_source, allocator);
    defer parser.deinit();
    // Try to parse the data
    var parsed_table = parser.parse() catch unreachable;
    _ = parsed_table;
}
