const std = @import("std");
const mem = std.mem;
const io = std.io;
const debug = std.debug;

const lex = @import("lexer.zig");
const cnst = @import("constants.zig");

fn skipUTF8BOM(in: *io.StreamSource) void {
    // INFO:
    // The UTF-8 BOM is a sequence of bytes at the start of a text stream
    // (0xEF, 0xBB, 0xBF) that allows the reader to more reliably guess
    // a file as being encoded in UTF-8.
    // [src:https://stackoverflow.com/questions/2223882/whats-the-difference-between-utf-8-and-utf-8-with-bom]

    const r = in.reader();
    const header = r.readIntLittle(u24) catch {
        return;
    };

    if (header != cnst.UTF8BOMLE) {
        in.seekTo(0) catch unreachable;
    }
}

fn skipUTF16BOM(in: *io.StreamSource) void {
    // INFO:
    // In UTF-16, a BOM (U+FEFF) may be placed as the first bytes
    // of a file or character stream to indicate the endianness (byte order)

    const r = in.reader();
    const header = r.readIntLittle(u16) catch {
        return;
    };

    if (header != cnst.UTF16BOMLE) {
        in.seekTo(0) catch unreachable;
    }
}

pub const Parser = struct {
    lexer: lex.Lexer,
    toml_src: *io.StreamSource,

    const Self = @This();

    /// initialize a toml parser, the toml_input pointer should remain valid
    /// until the parser is deinitialized.
    /// call deinit() when done to release memory resources.
    pub fn init(allocator: mem.Allocator, toml_input: *io.StreamSource) mem.Allocator.Error!Self {
        return .{
            .lexer = try lex.Lexer.init(allocator, toml_input),
            .toml_src = toml_input,
        };
    }

    /// Frees memory resources used by the parser.
    /// you shouldn't attempt to use the parser after calling this function
    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
    }

    pub fn parse(self: *Self) !void {
        skipUTF16BOM(self.toml_src);
        skipUTF8BOM(self.toml_src);

        var token: lex.Token = undefined;

        while (true) {
            self.lexer.nextToken(&token);
            switch (token.type) {
                .Error => {
                    debug.print("[{d},{d}]Tok:Error, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                    return error.LexerError;
                },
                .EOF => {
                    debug.print("[{d},{d}]Tok:EOF\n", .{ token.start.line, token.start.offset });
                    break;
                },
                .Key => {
                    debug.print("[{d},{d}]Tok:Key, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .BasicString => {
                    debug.print("[{d},{d}]Tok:BasicString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                else => {},
            }
        }
    }
};

test "temp" {
    const testing = std.testing;
    const src =
        \\ # This is a comment
        \\ my_string = "Hello world!"
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}
