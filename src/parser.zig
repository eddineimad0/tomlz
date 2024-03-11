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
                .LitteralString => {
                    debug.print("[{d},{d}]Tok:LitteralString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .MultiLineBasicString => {
                    debug.print("[{d},{d}]Tok:MLBasicString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .MultiLineLitteralString => {
                    debug.print("[{d},{d}]Tok:MLLitteralString, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Integer => {
                    debug.print("[{d},{d}]Tok:Integer, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Float => {
                    debug.print("[{d},{d}]Tok:Float, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .Boolean => {
                    debug.print("[{d},{d}]Tok:Boolean, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                .DateTime => {
                    debug.print("[{d},{d}]Tok:DateTime, {s}\n", .{ token.start.line, token.start.offset, token.value.? });
                },
                else => {},
            }
        }
    }
};

test "lex string" {
    const testing = std.testing;
    const src =
        \\# This is a comment
        \\my_string = 'Hello world!'
        \\my_string2 = "Hello w\x31rld!"
        \\my_string3 = "Hello w\u3100rld!"
        \\my_string4 = """Hello w\U41520000rld!"""
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}

test "lex integer" {
    const testing = std.testing;
    const src =
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
        \\int7 = 53_49_221  # Indian number system grouping
        \\int8 = 1_2_3_4_5  # VALID but discouraged
        \\# hexadecimal with prefix `0x`
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\hex3 = 0xdead_beef
        \\# octal with prefix `0o`
        \\oct1 = 0o01234567
        \\oct2 = 0o755 # useful for Unix file permissions
        \\# binary with prefix `0b`
        \\bin1 = 0b11010110
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}

test "lex float" {
    const testing = std.testing;
    const src =
        \\# fractional
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\# exponent
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\# both
        \\flt7 = 6.626e-34
        \\# infinity
        \\sf1 = inf  # positive infinity
        \\sf2 = +inf # positive infinity
        \\sf3 = -inf # negative infinity
        \\# not a number
        \\sf4 = nan  # actual sNaN/qNaN encoding is implementation-specific
        \\sf5 = +nan # same as `nan`
        \\sf6 = -nan # valid, actual encoding is implementation-specific
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}

test "lex bool" {
    const testing = std.testing;
    const src =
        \\bool1 = true
        \\bool2 = false
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}

test "lex datetime" {
    const testing = std.testing;
    const src =
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
    ;
    var ss = io.StreamSource{ .const_buffer = io.FixedBufferStream([]const u8){ .buffer = src, .pos = 0 } };

    var p = try Parser.init(testing.allocator, &ss);
    defer p.deinit();

    try p.parse();
}
