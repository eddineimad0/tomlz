//! This file is intended to be used with the toml test suite.
const std = @import("std");
const tomlz = @import("tomlz");
const process = std.process;
const io = std.io;
const fmt = std.fmt;
var gpa: std.heap.DebugAllocator(.{}) = .init;

pub fn main() void {
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdin = io.getStdIn();
    defer stdin.close();
    var stdout = io.getStdOut();
    defer stdout.close();

    const input = stdin.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |e| {
        std.log.err("Allocation failure, ({})\n", .{e});
        stdout.writer().print("Allocation failure, ({})\n", .{e}) catch unreachable;
        process.exit(1);
    };
    defer allocator.free(input);

    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(input) };
    var parser = tomlz.Parser.init(allocator);
    defer parser.deinit();

    // Try to parse the data
    const table = parser.parse(&stream_source) catch |e| {
        std.log.err("Parser Error, {}", .{e});
        process.exit(1);
    }; // compile in debug so we can crash.
    const json_out = toJson(allocator, table) catch |e| {
        std.log.err("Json stringify failure, Error={}", .{e});
        process.exit(1);
    };
    defer allocator.free(json_out);
    _ = stdout.write(json_out) catch |e| {
        std.log.err("stdout write failure, Error={}", .{e});
    };

    process.exit(0);
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
        wr.print("\t\"", .{}) catch return error.JsonStringifyError;
        stringEscape(e.key_ptr.*, "", .{}, wr) catch return error.JsonStringifyError;
        wr.print("\": ", .{}) catch return error.JsonStringifyError;
        switch (e.value_ptr.*) {
            .Array => |a| {
                jsonStringifyArray(a, wr) catch return error.JsonStringifyError;
            },
            .Table => |*table| {
                jsonStringifyTable(table, wr) catch return error.JsonStringifyError;
            },
            .TablesArray => |a| {
                jsonStringifyArrayTable(a, wr) catch return error.JsonStringifyError;
            },
            else => jsonStringifyValue(e.value_ptr, wr) catch return error.JsonStringifyError,
        }
    }
    _ = wr.write("\n") catch return error.JsonStringifyError;
    _ = wr.write("}\n") catch return error.JsonStringifyError;
}

fn jsonStringifyArrayTable(a: []const tomlz.TomlTable, wr: *std.ArrayList(u8).Writer) !void {
    _ = try wr.write("[\n");
    for (a, 0..a.len) |*table, i| {
        if (i > 0) {
            _ = try wr.write(",\n");
        }
        try jsonStringifyTable(table, wr);
    }
    _ = try wr.write("\n");
    _ = try wr.write("]");
}

fn jsonStringifyArray(a: []const tomlz.TomlValue, wr: *std.ArrayList(u8).Writer) !void {
    _ = try wr.write("[\n");
    for (a, 0..a.len) |*value, i| {
        if (i > 0) {
            _ = try wr.write(",\n");
        }
        switch (value.*) {
            .Table => |*table| {
                jsonStringifyTable(table, wr) catch return error.JsonStringifyError;
            },
            .Array => |inner_arry| {
                try jsonStringifyArray(inner_arry, wr);
            },
            else => try jsonStringifyValue(value, wr),
        }
    }
    _ = try wr.write("\n");
    _ = try wr.write("]");
}

fn jsonStringifyValue(v: *const tomlz.TomlValue, wr: *std.ArrayList(u8).Writer) !void {
    switch (v.*) {
        .String => |slice| {
            try wr.print(
                "{{\n\t\"type\": \"string\",\n\t\"value\": \"",
                .{},
            );
            try stringEscape(slice, "", .{}, wr);
            try wr.print("\"\n}}", .{});
        },
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
                    value_type = "datetime";
                    if (ts.time.?.offset.?.z) {
                        offset = try fmt.bufPrint(&offset_buffer, "Z", .{});
                    } else {
                        //const sign: u8 = if (ts.time.?.offset.?.sign < 0) '+' else '-';
                        //const offs = if (sign == '-') -1 * ts.time.?.offset.?.minutes else ts.time.?.offset.?.minutes;
                        //const hours = @divFloor(offset.h, 60);
                        //const minutes = @mod(offs, 60);
                        offset = try fmt.bufPrint(
                            &offset_buffer,
                            "{d:0>2}:{d:0>2}",
                            .{ ts.time.?.offset.?.hour, ts.time.?.offset.?.minute },
                        );
                    }
                } else {
                    offset = try fmt.bufPrint(&offset_buffer, "", .{});
                }
                value_string = try fmt.bufPrint(
                    &time_buffer,
                    "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}",
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
                    "{d}-{d:0>2}-{d:0>2}",
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
                            .{ts.time.?.offset.?.minute},
                        );
                    }
                } else {
                    offset = try fmt.bufPrint(&offset_buffer, "", .{});
                }
                value_string = try fmt.bufPrint(
                    &time_buffer,
                    "{d:0>2}:{d:0>2}:{d:0>2}{s}",
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

pub fn stringEscape(
    bytes: []const u8,
    comptime f: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    for (bytes) |byte| switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\\' => try writer.writeAll("\\\\"),
        0x0C => try writer.writeAll("\\u000c"),
        0x08 => try writer.writeAll("\\u0008"),
        0x1f => try writer.writeAll("\\u001f"),
        0x00 => try writer.writeAll("\\u0000"),
        '"' => {
            if (f.len == 1 and f[0] == '\'') {
                try writer.writeByte('"');
            } else if (f.len == 0) {
                try writer.writeAll("\\\"");
            } else {
                @compileError("expected {} or {'}, found {" ++ f ++ "}");
            }
        },
        '\'' => {
            if (f.len == 1 and f[0] == '\'') {
                try writer.writeAll("\\'");
            } else if (f.len == 0) {
                try writer.writeByte('\'');
            } else {
                @compileError("expected {} or {'}, found {" ++ f ++ "}");
            }
        },
        ' ', '!', '#'...'&', '('...'[', ']'...'~' => try writer.writeByte(byte),
        // Use hex escapes for rest any unprintable characters.
        else => {
            try writer.writeAll(&[1]u8{byte});
        },
    };
}
