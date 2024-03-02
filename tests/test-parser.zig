//! This file is intended to be used with the toml test suite.
const std = @import("std");
const tomlz = @import("tomlz");
const os = std.os;
const io = std.io;
const json = std.json;
const fmt = std.fmt;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() void {
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
        if (std.mem.eql(u8, e.key_ptr.*, &tomlz.Parser.BLANK_KEY)) {
            wr.print("\t\"\": ", .{}) catch return error.JsonStringifyError;
        } else {
            wr.print("\t\"{s}\": ", .{e.key_ptr.*}) catch return error.JsonStringifyError;
        }
        switch (e.value_ptr.*) {
            .Array => |*a| {
                jsonStringifyArray(a, wr) catch return error.JsonStringifyError;
            },
            .Table => |*table| {
                jsonStringifyTable(table, wr) catch return error.JsonStringifyError;
            },
            .TablesArray => |*a| {
                jsonStringifyArrayTable(a, wr) catch return error.JsonStringifyError;
            },
            else => jsonStringifyValue(e.value_ptr.*, wr) catch return error.JsonStringifyError,
        }
    }
    _ = wr.write("\n") catch return error.JsonStringifyError;
    _ = wr.write("}\n") catch return error.JsonStringifyError;
}

fn jsonStringifyArrayTable(a: *const tomlz.TomlTableArray, wr: *std.ArrayList(u8).Writer) !void {
    _ = try wr.write("[\n");
    for (0..a.size()) |i| {
        if (i > 0) {
            _ = try wr.write(",\n");
        }
        const table = a.ptrAt(i);
        try jsonStringifyTable(table, wr);
    }
    _ = try wr.write("\n");
    _ = try wr.write("]");
}

fn jsonStringifyArray(a: *const tomlz.TomlArray, wr: *std.ArrayList(u8).Writer) !void {
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

fn jsonStringifyValue(v: anytype, wr: *std.ArrayList(u8).Writer) !void {
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
        .DateTime => |*ts| {
            var value_type: [*:0]const u8 = "";
            var time_buffer: [256]u8 = undefined;
            var offset_buffer: [128]u8 = undefined;
            var offset: []u8 = undefined;
            var value_string: []u8 = undefined;
            if (ts.date != null and ts.time != null) {
                value_type = "datetime-local";
                if (ts.time.?.offset != null) {
                    if (ts.time.?.offset.?.z) {
                        offset = try fmt.bufPrint(&offset_buffer, "Z", .{});
                        value_type = "datetime";
                    } else {
                        offset = try fmt.bufPrint(
                            &offset_buffer,
                            "{d}",
                            .{ts.time.?.offset.?.minutes},
                        );
                    }
                } else {
                    offset = try fmt.bufPrint(&offset_buffer, "", .{});
                }
                value_string = try fmt.bufPrint(
                    &time_buffer,
                    "{d}-{d}-{d}T{d}:{d}:{d}{s}",
                    .{
                        ts.date.?.year,
                        ts.date.?.month,
                        ts.date.?.day,
                        ts.time.?.hour,
                        ts.time.?.minute,
                        ts.time.?.second,
                        offset,
                    },
                );
            } else if (ts.date != null) {
                value_type = "date-local";
                value_string = try fmt.bufPrint(
                    &time_buffer,
                    "{d}-{d}-{d}",
                    .{
                        ts.date.?.year,
                        ts.date.?.month,
                        ts.date.?.day,
                    },
                );
            } else if (ts.time != null) {
                value_type = "time-local";
                if (ts.time.?.offset != null) {
                    if (ts.time.?.offset.?.z) {
                        offset = try fmt.bufPrint(&offset_buffer, "Z", .{});
                    } else {
                        offset = try fmt.bufPrint(
                            &offset_buffer,
                            "{d}",
                            .{ts.time.?.offset.?.minutes},
                        );
                    }
                } else {
                    offset = try fmt.bufPrint(&offset_buffer, "", .{});
                }
                value_string = try fmt.bufPrint(
                    &time_buffer,
                    "{d}:{d}:{d}{s}",
                    .{
                        ts.time.?.hour,
                        ts.time.?.minute,
                        ts.time.?.second,
                        offset,
                    },
                );
            }
            try wr.print(
                "{{\n\t\"type\": \"{s}\",\n\t\"value\": \"{s}\"\n}}",
                .{ value_type, value_string },
            );
        },
        else => return error.UnknownTomlValue,
    }
}

test "reandom" {
    var c: u8 = ' ';
    if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
        // rewind and exit.
        std.debug.print("Space unallowed\n", .{});
    }
}
