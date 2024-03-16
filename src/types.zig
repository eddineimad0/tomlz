//! This file contains type definitions for all Toml types

const std = @import("std");
const mem = std.mem;
const common = @import("common.zig");

const StringHashMap = std.StringHashMap;

pub const Key = []const u8;

pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const LocalTime = struct {
    hour: u8, // [0,24)
    minute: u8, // [0,60)
    second: u8, // [0,60)
    nana_second: u32, // [0,1000000000)
    precision: u32, // nano_seconds precision.
};

pub const LocalDateTime = struct {
    usingnamespace LocalDate;
    usingnamespace LocalTime;
    // date: LocalDate,
    // time: LocalTime,
};

pub const TomlType = enum { Integer, String, Float, Boolean, Array, Table, TablesArray, DateTime };

pub const TomlTable = StringHashMap(TomlValue);

pub const TomlValue = union(TomlType) {
    Boolean: bool,
    Integer: i64,
    Float: f64,
    String: []const u8,
    Array: []TomlValue,
    Table: TomlTable,
    TablesArray: []TomlTable,
    DateTime: LocalDateTime,
};
