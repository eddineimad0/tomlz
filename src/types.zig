const std = @import("std");
const date_time = @import("date_time.zig");
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;

// TOML values
// https://toml.io/en/v1.0.0#keyvalue-pair
pub const ValueType = enum {
    Integer,
    Float,
    Boolean,
    String,
    Array,
    TablesArray,
    Table,
    DateTime,
};

pub const Value = union(ValueType) {
    Integer: isize,
    Float: f64,
    Boolean: bool,
    String: []const u8,
    Array: Array(Value),
    TablesArray: Array(Table),
    Table: Table,
    DateTime: date_time.Timestamp,
};

pub fn freeValue(v: *Value, allocator: Allocator) void {
    switch (v.*) {
        .String => |slice| allocator.free(slice),
        .Array => |*a| {
            a.deinit();
        },
        .TablesArray => |*a| {
            a.deinit();
        },
        .Table => |*t| {
            t.deinit();
        },
        else => {},
    }
}

pub fn Array(comptime T: type) type {
    return struct {
        array: ArrayList(T),

        const Self = @This();

        pub inline fn init(allocator: Allocator) Self {
            return Self{
                .array = ArrayList(T).init(allocator),
            };
        }

        pub inline fn deinit(self: *Self) void {
            defer self.array.deinit();
            self.clear();
        }

        /// clears the array and frees any allocated resources.
        pub inline fn clear(self: *Self) void {
            if (T == Value) {
                const allocator = self.array.allocator;
                for (self.array.items) |*val| {
                    freeValue(val, allocator);
                }
            } else if (T == Table) {
                for (self.array.items) |*tab| {
                    tab.deinit();
                }
            } else {
                @compileError("Generic Toml Array: T can only be Value or Table");
            }
        }

        pub inline fn append(self: *Self, item: T) !void {
            try self.array.append(item);
        }

        pub inline fn size(self: *Self) usize {
            return self.array.items.len;
        }

        pub inline fn ptrAt(self: *Self, index: usize) *const T {
            return &self.array.items[index];
        }

        pub inline fn ptrAtMut(self: *Self, index: usize) *T {
            return &self.array.items[index];
        }
    };
}
pub const Table = struct {
    table: StringHashMap(Value),
    // tracks how the table was defined:
    // true: implicitly defined through dotted keys,
    // false: defined through [] in the root level,
    // this is necessary to respect table defination rules.
    implicit: bool,
    const Self = @This();
    const Iterator = StringHashMap(Value).Iterator;

    pub fn init(allocator: Allocator, implicit: bool) Self {
        return Self{
            .table = StringHashMap(Value).init(allocator),
            .implicit = implicit,
        };
    }

    pub fn deinit(self: *Self) void {
        defer self.table.deinit();
        self.clear();
    }

    /// clears the table and frees any allocated resources.
    pub fn clear(self: *Self) void {
        const allocator = self.table.allocator;
        var it = self.table.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            freeValue(e.value_ptr, allocator);
        }
    }

    pub inline fn put(self: *Self, key: []const u8, value: Value) Allocator.Error!void {
        try self.table.put(key, value);
    }

    pub inline fn get(self: *const Self, key: []const u8) ?*const Value {
        return self.table.getPtr(key);
    }

    pub inline fn get_mut(self: *Self, key: []const u8) ?*Value {
        return self.table.getPtr(key);
    }

    pub inline fn iterator(self: *const Self) Iterator {
        return self.table.iterator();
    }
};

pub const Key = ArrayList(u8);
pub const String = ArrayList(u8);
