const std = @import("std");
const bltin = @import("builtin");
const err = @import("error.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");

pub const Parser = parser.Parser;
pub const TomlTable = types.Table;
pub const ParserError = err.ParserError;

pub fn debugTable(t: *const TomlTable) void {
    const dbg = bltin.mode == .Debug;
    if (dbg) {
        var it = t.iterator();
        while (it.next()) |e| {
            std.debug.print("\n{s} => ", .{e.key_ptr.*});
            switch (e.value_ptr.*) {
                .String => |slice| std.debug.print("{s}", .{slice}),
                .Boolean => |b| std.debug.print("{},", .{b}),
                .Integer => |i| std.debug.print("{d},", .{i}),
                .Float => |fl| std.debug.print("{d},", .{fl}),
                .DateTime => |*ts| std.debug.print("{any},", .{ts.*}),
                // .Array => |_| {
                //     // handle arry
                // },
                .Table => |*table| {
                    std.debug.print("{{ ", .{});
                    debugTable(table);
                    std.debug.print("\n}}", .{});
                },
                else => continue,
            }
        }
    }
}
