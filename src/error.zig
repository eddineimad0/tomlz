const std = @import("std");
const utils = @import("utils.zig");
const opt = @import("build_options");

const mem = std.mem;
const fmt = std.fmt;

pub const ParseError = struct {
    error_message: ?[]const u8,
    heap_buffer: utils.String8,
    stack_buffer: [opt.ERROR_STACK_BUFFER_SIZE]u8,

    const Self = @This();
    const ERROR_OUT_MEM_FALLBACK = "Not enough memory to report the parser error";

    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .heap_buffer = utils.String8.init(allocator),
            .error_message = null,
            .stack_buffer = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.heap_buffer.deinit();
    }

    /// Attempts to print the given error message,
    /// In case there isn't enough memory to print the error
    /// a generic error message will be printed.
    pub fn writeErrorMsg(self: *Self, comptime format: []const u8, args: anytype) void {
        const required_size = fmt.count(format, args);
        if (opt.ERROR_STACK_BUFFER_SIZE >= required_size) {
            self.error_message = fmt.bufPrint(&self.stack_buffer, format, args) catch unreachable;
            return;
        } else {
            self.heap_buffer.ensureTotalCapacity(required_size) catch {
                self.error_message = ERROR_OUT_MEM_FALLBACK;
            };
            self.heap_buffer.writer().print(format, args) catch unreachable;
            self.error_message = self.heap_buffer.items;
        }
    }

    /// Returns a slice of the error message that was printed by printError.
    /// If there was no call to printError it returns an empty string.
    pub inline fn errorMessage(self: *const Self) []const u8 {
        return self.error_message orelse "";
    }
};
