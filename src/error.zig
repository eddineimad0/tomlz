const std = @import("std");
const types = @import("types.zig");
const defs = @import("defs.zig");
const fmt = std.fmt;
const mem = std.mem;

pub const ParserError = error{
    OutOfMemory,
    BadSyntax,
    BadKey,
    BadValue,
    DupKey,
    MissingKey,
    MissingValue,
    MissingEqual,
    ForbiddenStringChar,
    BadStringEscSeq,
    UnterminatedString,
    NesttingError,
    UndefinedTableName,
    TableRedefinition,
};

pub const ErrorContext = struct {
    msg: types.String,
    backup_msg: [64]u8,
    bak_msg_len: u8,
    const Self = @This();

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .msg = types.String.init(allocator),
            .backup_msg = undefined,
            .bak_msg_len = 0,
        };
    }

    pub inline fn resize(self: *Self, new_capacity: usize) !void {
        try self.msg.ensureTotalCapacity(new_capacity);
    }

    pub inline fn deinit(self: *Self) void {
        self.msg.deinit();
    }

    /// Prints the formatted errot to the error buffer
    /// a line number and character are expected at the begining of the args.
    pub inline fn reportError(self: *Self, err: ParserError, comptime format: []const u8, args: anytype) ParserError {
        self.msg.writer().print(format, args) catch self.backupError(err);
        return err;
    }

    pub inline fn errorMsg(self: *const Self) []const u8 {
        return self.msg.items[0..self.msg.items.len];
    }

    fn backupError(self: *Self, err: ParserError) void {
        var slice: []u8 = undefined;
        switch (err) {
            ParserError.BadSyntax => {
                slice = fmt.bufPrint(&self.backup_msg, "Bad Syntax Detected", .{}) catch unreachable;
            },
            ParserError.BadKey => {
                slice = fmt.bufPrint(&self.backup_msg, "Bad Key Detected", .{}) catch unreachable;
            },
            ParserError.BadValue => {
                slice = fmt.bufPrint(&self.backup_msg, "Unknown value Detected", .{}) catch unreachable;
            },
            ParserError.DupKey => {
                slice = fmt.bufPrint(&self.backup_msg, "Duplicate Key Detected", .{}) catch unreachable;
            },
            ParserError.MissingKey => {
                slice = fmt.bufPrint(&self.backup_msg, "Assignment to an empty bare key Detected", .{}) catch unreachable;
            },
            ParserError.MissingEqual => {
                slice = fmt.bufPrint(&self.backup_msg, "Expected and equal sign", .{}) catch unreachable;
            },
            ParserError.MissingValue => {
                slice = fmt.bufPrint(&self.backup_msg, "Missing value for a key", .{}) catch unreachable;
            },
            ParserError.ForbiddenStringChar => {
                slice = fmt.bufPrint(&self.backup_msg, "Forbidden string character Detected", .{}) catch unreachable;
            },
            ParserError.BadStringEscSeq => {
                slice = fmt.bufPrint(&self.backup_msg, "Bad Syntax Detected", .{}) catch unreachable;
            },
            ParserError.UnterminatedString => {
                slice = fmt.bufPrint(&self.backup_msg, "Unterminated String Detected", .{}) catch unreachable;
            },
            ParserError.NesttingError => {
                slice = fmt.bufPrint(&self.backup_msg, "Surpassed maximum allowed nestting level", .{}) catch unreachable;
            },
            ParserError.UndefinedTableName => {
                slice = fmt.bufPrint(&self.backup_msg, "Found a table without a name", .{}) catch unreachable;
            },
            ParserError.TableRedefinition => {
                slice = fmt.bufPrint(&self.backup_msg, "A table was redefined Detected", .{}) catch unreachable;
            },
            ParserError.OutOfMemory => {
                slice = fmt.bufPrint(&self.backup_msg, "Ran out of memory", .{}) catch unreachable;
            },
        }
        self.bak_msg_len = @intCast(slice.len);
    }
};
