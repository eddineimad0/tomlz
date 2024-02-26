//! This file is intended to be used with the toml test suite.
const std = @import("std");
const tomlz = @import("tomlz");
const os = std.os;
const io = std.io;
const json = std.json;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdin = io.getStdIn();
    var stdout = io.getStdOut();

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
    const json_out = toJson(allocator, parsed_table) catch |e| {
        std.log.err("Json stringify failure, Error={}", .{e});
        os.exit(1);
    };
    defer allocator.free(json_out);

    _ = stdout.write(json_out) catch |e| {
        std.log.err("stdout write failure, Error={}", .{e});
        os.exit(1);
    };

    // TODO: the test suite expects json output.
    os.exit(0);
}

fn toJson(allocator: std.mem.Allocator, t: *const tomlz.TomlTable) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    var wr = buffer.writer();
    try jsonStringifyTable(t, &wr);
    return try buffer.toOwnedSlice();
}

const StringifyError = error{
    JsonStringifyError,
};

fn jsonStringifyTable(t: *const tomlz.TomlTable, wr: *std.ArrayList(u8).Writer) StringifyError!void {
    _ = wr.write("{\n") catch return error.JsonStringifyError;
    var it = t.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) {
            _ = wr.write(",\n") catch return error.JsonStringifyError;
        } else {
            first = false;
        }
        wr.print("\t\"{s}\": ", .{e.key_ptr.*}) catch return error.JsonStringifyError;
        switch (e.value_ptr.*) {
            .Array => |*a| {
                jsonStringifyArray(a, wr) catch return error.JsonStringifyError;
            },
            .Table => |*table| {
                jsonStringifyTable(table, wr) catch return error.JsonStringifyError;
            },
            .TablesArray => |*a| {
                _ = a;
            },
            else => jsonStringifyValue(e.value_ptr.*, wr) catch return error.JsonStringifyError,
        }
    }
    _ = wr.write("\n") catch return error.JsonStringifyError;
    _ = wr.write("}\n") catch return error.JsonStringifyError;
}

pub fn jsonStringifyArray(a: *const tomlz.TomlArray, wr: *std.ArrayList(u8).Writer) !void {
    _ = try wr.write("[\n");
    for (0..a.size()) |i| {
        if (i > 0) {
            _ = try wr.write(",\n");
        }
        const value = a.ptrAt(i);
        switch (value.*) {
            .Table => |*table| {
                jsonStringifyTable(table, wr) catch return error.JsonStringifyError;
            },
            .Array => |*inner_arry| {
                try jsonStringifyArray(inner_arry, wr);
            },
            else => try jsonStringifyValue(value.*, wr),
        }
    }
    _ = try wr.write("\n");
    _ = try wr.write("]");
}

pub fn jsonStringifyValue(v: anytype, wr: *std.ArrayList(u8).Writer) !void {
    switch (v) {
        .String => |slice| try wr.print(
            "{{\n\t\"type\": \"string\",\n\t\"value\": \"{s}\"\n}}",
            .{slice},
        ),
        .Boolean => |b| try wr.print(
            "{{\n\t\"type\": \"bool\",\n\t\"value\": \"{}\"\n}}",
            .{b},
        ),
        .Integer => |i| try wr.print(
            "{{\n\t\"type\": \"integer\",\n\t\"value\": \"{d}\"\n}}",
            .{i},
        ),
        .Float => |f| try wr.print(
            "{{\n\t\"type\": \"float\",\n\t\"value\": \"{d}\"\n}}",
            .{f},
        ),
        .DateTime => |*ts| _ = ts,
        else => return error.UnknownTomlValue,
    }
}
