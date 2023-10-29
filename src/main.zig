const std = @import("std");
const bltin = @import("builtin");
const err = @import("error.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");

pub const Parser = parser.Parser;
pub const TomlTable = types.Table;
pub const TomlArray = types.Array(types.Value);
pub const ParserError = err.ParserError;
