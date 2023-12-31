const std = @import("std");
const io = std.io;
const fs = std.fs;
const toml = @import("toml");
var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};

fn parseTomlFile(f: fs.File) void {
    var ifs = io.StreamSource{ .file = f };
    var p = toml.Parser.init(&ifs, gpa_allocator.allocator());
    defer p.deinit();
    var t = p.parse() catch {
        std.debug.print("\n[ERROR]\n", .{});
        std.debug.print("\n{s}\n", .{p.errorMsg()});
        return;
    };
    printTable(t);
}

fn printArray(a: *const toml.TomlArray) void {
    for (0..a.size()) |i| {
        const value = a.ptrAt(i);
        switch (value.*) {
            .String => |slice| {
                std.debug.print("{s},", .{slice});
            },
            .Boolean => |b| std.debug.print("{},", .{b}),
            .Integer => |int| std.debug.print("{d},", .{int}),
            .Float => |fl| std.debug.print("{d},", .{fl}),
            .DateTime => |*ts| std.debug.print("{any},", .{ts.*}),
            .Table => |*table| {
                std.debug.print("{{ ", .{});
                printTable(table);
                std.debug.print("\n}},", .{});
            },
            .Array => |*inner_arry| {
                std.debug.print("[ ", .{});
                printArray(inner_arry);
                std.debug.print("],", .{});
            },
            else => unreachable,
        }
    }
}

fn printTable(t: *const toml.TomlTable) void {
    var it = t.iterator();
    while (it.next()) |e| {
        std.debug.print("\n{s} => ", .{e.key_ptr.*});
        switch (e.value_ptr.*) {
            .String => |slice| io.getStdOut().writer().print("{s}", .{slice}) catch unreachable,
            .Boolean => |b| std.debug.print("{},", .{b}),
            .Integer => |i| std.debug.print("{d},", .{i}),
            .Float => |fl| std.debug.print("{d},", .{fl}),
            .DateTime => |*ts| std.debug.print("{any},", .{ts.*}),
            .Array => |*a| {
                std.debug.print("[ ", .{});
                printArray(a);
                std.debug.print("]\n", .{});
            },
            .Table => |*table| {
                std.debug.print("{{ ", .{});
                printTable(table);
                std.debug.print("\n}}", .{});
            },
            .TablesArray => |*a| {
                std.debug.print("[ ", .{});
                for (0..a.size()) |i| {
                    std.debug.print("{{ ", .{});
                    printTable(a.ptrAt(i));
                    std.debug.print("}},", .{});
                }
                std.debug.print("]\n", .{});
            },
        }
    }
}

pub fn main() !void {
    defer std.debug.assert(gpa_allocator.deinit() == .ok);
    const allocator = gpa_allocator.allocator();
    var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    const cwd = try std.os.getcwd(&path);

    const examples_path = try fs.path.join(allocator, &[2][]const u8{ cwd, "examples" });
    defer allocator.free(examples_path);

    var examples_dir = try fs.openIterableDirAbsolute(examples_path, .{});
    defer examples_dir.close();
    var walker = try examples_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |*entry| {
        switch (entry.kind) {
            .directory => {
                var sub_dir = try examples_dir.dir.openIterableDir(entry.path, .{});
                defer sub_dir.close();
                var file_walker = try sub_dir.walk(allocator);
                defer file_walker.deinit();
                while (try file_walker.next()) |*file_entry| {
                    if (file_entry.kind == .file) {
                        var example = try sub_dir.dir.openFile(file_entry.path, .{});
                        defer example.close();
                        std.debug.print("\n========= Testing file {s} ===========\n", .{file_entry.path});
                        parseTomlFile(example);
                    }
                }
            },
            else => continue,
        }
    }
}
