const std = @import("std");
const tomlz = @import("tomlz");

comptime {
    @export(fuzzTomlz, .{ .name = "fuzz_tomlz", .linkage = .Strong });
}

// export the zig function so that it can be called from C
export fn fuzzTomlz(buffer: [*]const u8, size: usize) callconv(.C) void {
    // Setup an allocator that will detect leaks/use-after-free/etc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will check for leaks and crash the program if it finds any
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var data: []const u8 = undefined;
    data.ptr = buffer;
    data.len = size;
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    var parser = tomlz.Parser.init(&stream_source, allocator);
    defer parser.deinit();
    // Try to parse the data
    var parsed_table = parser.parse() catch unreachable;
    _ = parsed_table;
}
