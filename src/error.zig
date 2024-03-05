const std = @import("std");
const common = @import("common.zig");

pub const ParseError = struct {
    msg: common.String8,
    position: common.Position,
};
