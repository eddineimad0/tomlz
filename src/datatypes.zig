//! This file contains type definitions for all Toml types

const std = @import("std");

const StringHashMap = std.StringHashMap;

pub const Key = []const u8;

pub const Date = struct {
    year: u16, // 4DIGIT
    month: u8, // 2DIGIT  ; 01-12
    day: u8, //2DIGIT  ; 01-28, 01-29, 01-30, 01-31 based on month/year
};

pub const TimeOffset = struct {
    z: bool,
    sign: i16,
    hour: u8,
    minute: u8,
};

pub const Time = struct {
    hour: u8, // [0,24)
    minute: u8, // [0,60)
    second: u8, // [0,60)
    nano_second: u32, // [0,1000000000)
    offset: ?TimeOffset,
};

pub const DateTime = struct {
    date: ?Date,
    time: ?Time,
};

pub const TomlType = enum {
    Boolean,
    Integer,
    Float,
    String,
    Array,
    Table,
    TablesArray,
    DateTime,
};

pub const TomlTable = StringHashMap(TomlValue);

pub const TomlValue = union(TomlType) {
    Boolean: bool,
    Integer: i64,
    Float: f64,
    String: []const u8,
    Array: []TomlValue,
    Table: TomlTable,
    TablesArray: []TomlTable,
    DateTime: DateTime,
};
