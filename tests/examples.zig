const std = @import("std");
const io = std.io;
const fs = std.fs;
const toml = @import("tomlz");
var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};

fn parseTomlFile(f: fs.File) void {
    var ifs = io.StreamSource{ .file = f };
    var p = toml.Parser.init(gpa_allocator.allocator(), &ifs) catch |e| {
        std.debug.print("error={}", .{e});
        return;
    };
    defer p.deinit();
    var t = p.parse() catch {
        return;
    };
    printTable(t);
}

fn printArray(a: []const toml.TomlValue) void {
    for (a) |*value| {
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
            .Array => |inner_arry| {
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
            .Array => |a| {
                std.debug.print("[ ", .{});
                printArray(a);
                std.debug.print("]\n", .{});
            },
            .Table => |*table| {
                std.debug.print("{{ ", .{});
                printTable(table);
                std.debug.print("\n}}", .{});
            },
            .TablesArray => |a| {
                std.debug.print("[ ", .{});
                for (a) |*i| {
                    std.debug.print("{{ ", .{});
                    printTable(i);
                    std.debug.print("}},", .{});
                }
                std.debug.print("]\n", .{});
            },
        }
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    defer std.debug.assert(gpa_allocator.deinit() == .ok);
    const allocator = gpa_allocator.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const target = args.next();

    var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    const cwd = try std.os.getcwd(&path);

    const target_path = if (target) |t| try fs.path.join(allocator, &.{ cwd, "examples", t }) else try fs.path.join(allocator, &.{ cwd, "examples" });

    defer allocator.free(target_path);

    var examples_dir = try fs.openIterableDirAbsolute(target_path, .{});
    defer examples_dir.close();

    var walker = try examples_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |*entry| {
        switch (entry.kind) {
            .file => {
                var example = try examples_dir.dir.openFile(entry.path, .{});
                defer example.close();
                std.debug.print("\n========= Testing file {s} ===========\n", .{entry.path});
                parseTomlFile(example);
            },
            else => continue,
        }
    }
}
