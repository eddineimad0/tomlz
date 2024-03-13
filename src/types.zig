//! This file contains type definitions for all Toml types

const std = @import("std");
const mem = std.mem;
const common = @import("common.zig");

const StringHashMap = std.StringHashMap;

pub const Key = []const u8;

pub const TomlType = enum {
    Integer,
    String,
    Float,
    Boolean,
    Array,
    Table,
    TablesArray,
};

pub const TomlTable = struct {
    impl: StringHashMap(TomlValue),
    const Self = @This();
    const Iterator = StringHashMap(TomlValue).Iterator;

    pub fn init(allocator: mem.Allocator) mem.Allocator!Self {
        var map = StringHashMap(TomlValue).init(allocator);
        map.ensureTotalCapacity(32);
        return Self{
            .impl = map,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.impl.deinit();
    }

    /// Clears the table and frees any allocated resources.
    pub fn clearContent(self: *Self) void {
        const allocator = self.impl.allocator;
        var it = self.impl.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
    }

    pub inline fn put(self: *Self, key: []const u8, value: TomlValue) mem.Allocator.Error!void {
        try self.impl.put(key, value);
    }

    pub inline fn getOrNull(self: *const Self, key: []const u8) ?*const TomlValue {
        return self.impl.getPtr(key);
    }

    pub inline fn getMutOrNull(self: *Self, key: []const u8) ?*TomlValue {
        return self.impl.getPtr(key);
    }

    pub inline fn iterator(self: *const Self) Iterator {
        return self.impl.iterator();
    }
};

pub const TomlValue = union(TomlType) {
    Integer: isize,
    String: common.String8,
    Float: f64,
    Boolean: bool,
    Array: common.DynArray(TomlValue, TomlValue.deinit),
    Table: TomlTable,
    TablesArray: common.DynArray(TomlTable, TomlTable.deinit),

    const Self = @This();
    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .String, .Array, .TablesArray, .Table => |*v| {
                v.deinit();
            },
            else => {},
        }
    }
};
