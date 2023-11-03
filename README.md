A TOML parser written in zig that targets v1.0.

## Usage
```zig
const std = @import("std");
const io = std.io;
const toml = @import("tomlz");
pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_allocator.deinit() == .ok);
    const allocator = gpa_allocator.allocator();
    const toml_input = // a toml file or a buffer or whatever toml input
    // the toml parser accepts a io.StreamSource as an input source.
    // Note: in case of a buffer `var ifs = io.StreamSource{ .const_buffer = toml_input };`
    var ifs = io.StreamSource{ .file = toml_input };
    // the toml parser takes an allocator and uses it internally for all allocations.
    var p = toml.Parser.init(&ifs, gpa_allocator.allocator());
    // when done deinit the parser to free all allocated resources.
    defer p.deinit();
    // use parse to start parsing the input source.
    // on success a `*const TomlTable struct(just a thin wrapper over a std.HashMap)` is returned.
    // on error the `ParserError` is returned and you can call `errorMsg` function to get a slice containing detailed reason for the error. 
    // Note: don't attempt to call parse again in case of an error as the result
    // are undefined.
    var t = p.parse() catch {
        std.debug.print("\n[ERROR]\n", .{});
        std.debug.print("\n{s}\n", .{p.errorMsg()});
        return;
    };

    // the returned table doesn't allow mutating the `TomlTable`
    // but it can be iterated over.
    var it = t.iterator();
    while (it.next()) |pair| {
        // the key is []u8.
        std.debug.print("\n{s} => ", .{pair.key_ptr.*});
        // the value is a tagged union(`TomlValue`)
        // check `TomlValueType` enum for the tags being used.
        switch (pair.value_ptr.*) {
            .String => |slice| std.debug.print("{s}", .{slice}),
            .Boolean => |b| std.debug.print("{},", .{b}),
            .Integer => |i| std.debug.print("{d},", .{i}),
            .Float => |fl| std.debug.print("{d},", .{fl}),
            .DateTime => |*ts| std.debug.print("{any},", .{ts.*}),
            // table is `*const TomlArray` struct(another thin wrapper over std.ArrayList(TomlValue)) 
            .Array => |*a| {
                std.debug.print("[ ", .{});
                ... // do whatever
                std.debug.print("]\n", .{});
            },
            // table is *const TomlTable 
            .Table => |*table| {
                std.debug.print("{{ ", .{});
                ... // do whatever
                std.debug.print("\n}}", .{});
            },
            // also a `*const TomlArray` struct but the values are all tables
            .TablesArray => |*a| {
                std.debug.print("[ ", .{});
                for (0..a.size()) |i| {
                    std.debug.print("{{ ", .{});
                    const inner_table = a.ptrAt(i);
                    ... // do whatever
                    std.debug.print("}},", .{});
                }
                std.debug.print("]\n", .{});
            },
        }
    }
}
```
