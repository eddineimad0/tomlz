const std = @import("std");
const types = @import("types.zig");
const token = @import("token.zig");
const defs = @import("constants.zig");
const date_time = @import("date_time.zig");
const io = std.io;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const debug = std.debug;
const Token = token.Token;
const TokenType = token.TokenType;
const ParserError = @import("error.zig").ParserError;
const ErrorContext = @import("error.zig").ErrorContext;

pub const Lexer = struct {
    line: usize,
    pos: u64, // The position or character on the current line.
    src: *io.StreamSource,
    const Self = @This();

    pub fn init(src: *io.StreamSource) Self {
        var s = Self{
            .src = src,
            .line = 1,
            .pos = 0,
        };
        s.skipUTF8BOM();
        return s;
    }

    fn skipUTF8BOM(self: *Self) void {
        // INFO:
        // The UTF-8 BOM is a sequence of bytes at the start of a text stream
        // (0xEF, 0xBB, 0xBF) that allows the reader to more reliably guess
        // a file as being encoded in UTF-8.
        // [src:https://stackoverflow.com/questions/2223882/whats-the-difference-between-utf-8-and-utf-8-with-bom]
        const header = self.src.reader().readIntLittle(u24) catch {
            return;
        };

        if (header == defs.UTF8BOMLE) {
            return;
        } else {
            self.src.seekTo(0) catch unreachable;
        }
    }

    /// Consume the current byte and copy it's value to the `out` parameter
    /// in case we reached the end it returns false,
    pub fn nextByte(self: *Self, out: *u8) bool {
        out.* = self.src.reader().readByte() catch {
            return false;
        };
        // Newline means LF (0x0A) or CRLF (0x0D 0x0A).
        // [src:https://toml.io/en/v1.0.0#spec];
        if (out.* == '\n') {
            self.line += 1;
            self.pos = 0;
        } else {
            self.pos += 1;
        }

        return true;
    }

    /// Advances in the buffer until an end of line character ('\n') is found,
    /// if it reaches the end of the stream before finding the newline
    /// it returns false, otherwise true,
    pub fn toNextLine(self: *Self) bool {
        var b: u8 = undefined;
        while (self.nextByte(&b)) {
            if (b == '\n') {
                return true;
            }
        }
        return false;
    }

    /// Rewind the position in the stream by n bytes.
    /// that was read.
    pub inline fn toLastNByte(self: *Self, n: u64) void {
        const p = self.src.getPos() catch unreachable;
        debug.assert(p >= n);
        self.src.seekTo(p - n) catch unreachable;
    }

    /// Rewind the position in the stream to the last byte
    /// that was read.
    pub inline fn toLastByte(self: *Self) void {
        self.toLastNByte(1);
    }

    /// Populate the `out` parameter with the next token
    pub fn nextToken(
        self: *Self,
        out: *Token,
    ) void {
        while (self.nextByte(&out.c)) {
            if (out.c == '#') {
                // skip until the next line.
                if (!self.toNextLine()) {
                    // Reporte the end of stream.
                    out.setContext(TokenType.EOS, self.pos, self.line);
                    return;
                }
                out.setContext(TokenType.EOL, self.pos, self.line);
                return;
            }
            if (out.c == ' ' or out.c == '\t' or out.c == '\r') {
                // Whitespace means tab (0x09) or space (0x20)
                // [src:https://toml.io/en/v1.0.0#spec];
                // skip.
                continue;
            }
            switch (out.c) {
                '\n' => out.setContext(TokenType.EOL, self.pos, self.line - 1),
                '=' => out.setContext(TokenType.Equal, self.pos, self.line),
                '{' => out.setContext(TokenType.LBrace, self.pos, self.line),
                '}' => out.setContext(TokenType.RBrace, self.pos, self.line),
                '[' => out.setContext(TokenType.LBracket, self.pos, self.line),
                ']' => out.setContext(TokenType.RBracket, self.pos, self.line),
                '\'', '"' => out.setContext(TokenType.String, self.pos, self.line),
                ',' => out.setContext(TokenType.Comma, self.pos, self.line),
                '.' => out.setContext(TokenType.Dot, self.pos, self.line),
                else => {
                    out.setContext(TokenType.IdentStart, self.pos, self.line);
                },
            }
            return;
        }
        out.setContext(TokenType.EOS, self.pos, self.line);
    }

    pub fn nextBareKey(
        self: *Self,
        key: *types.Key,
    ) !void {
        var c: u8 = undefined;
        while (self.nextByte(&c)) {
            if (!ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                // rewind and exit.
                self.toLastByte();
                break;
            }
            try key.append(c);
        }
    }

    fn trimNewLine(self: *Self) void {
        var c: u8 = undefined;
        if (self.nextByte(&c) and (c == '\r' or c == '\n')) {
            // Skip
            if (defs.IS_WINDOWS and c == '\r') {
                _ = self.nextByte(&c);
            }
        } else {
            self.toLastByte();
        }
    }

    /// Check if the next byte sequence in stream match the given one.
    fn matchNextSequence(self: *Self, comptime seq_len: comptime_int, seq: []u8) !bool {
        var bytes: [seq_len]u8 = undefined;
        try self.src.reader().readNoEof(&bytes);
        if (mem.eql(u8, &bytes, seq)) {
            return true;
        } else {
            @memcpy(seq, &bytes);
            return false;
        }
    }

    fn handlePreDelimQuottes(self: *Self, str: *types.String, comptime delim: u8) !void {
        var c: u8 = undefined;
        for (0..2) |_| {
            if (self.nextByte(&c)) {
                if (c == delim) {
                    try str.append(delim);
                    continue;
                }
                self.toLastByte();
                break;
            }
            break;
        }
        return;
    }

    pub fn nextStringSQ(self: *Self, str: *types.String, err: *ErrorContext, is_key: bool) !void {
        var c: u8 = undefined;
        if (self.nextByte(&c) and c == '\'') {
            // Possibly a multi-line literal string.
            if (!self.nextByte(&c) or c != '\'') {
                // Empty.
                // Rewind before returning.
                self.toLastByte();
                return;
            }

            if (is_key) {
                // keys can't be a multi-line
                return err.reportError(
                    ParserError.BadSyntax,
                    defs.ERROR_BAD_SYNTAX,
                    .{ self.line, self.pos, "Quotted keys can't be multi-line" },
                );
            }
            // A newline immediately following the opening delimiter will be trimmed.
            self.trimNewLine();

            // ML string processing .
            while (self.nextByte(&c)) {
                if (c == '\'') {
                    var sequence = [2]u8{ '\'', '\'' };
                    const match = self.matchNextSequence(2, &sequence) catch {
                        // Error:
                        // Reached End of stream without closing the string.
                        return err.reportError(
                            ParserError.UnterminatedString,
                            defs.ERROR_SQSTR_UNTERMIN,
                            .{ self.line, self.pos },
                        );
                    };
                    if (match) {
                        try self.handlePreDelimQuottes(str, '\'');
                        return;
                    } else {
                        // check for any " in the sequence and append them
                        try str.append(c);
                        var n: u8 = 2;
                        for (0..2) |i| {
                            if (sequence[i] == '\'') {
                                try str.append(c);
                                n -= 1;
                                continue;
                            } else {
                                self.toLastNByte(n);
                                break;
                            }
                        }
                        continue;
                    }
                }

                // Control characters other than tab are not permitted.
                if ((0x00 <= c and c <= 0x08) or (0x0A <= c and c <= 0x1F) or (c == 0x7F)) {
                    if (c != '\n' and c != '\r') {
                        return err.reportError(
                            ParserError.ForbiddenStringChar,
                            defs.ERROR_STRING_FORBIDDEN,
                            .{ self.line, self.pos, c },
                        );
                    }
                }
                try str.append(c);
            }
            // Error :
            // Reached End of stream without closing the string.
            return err.reportError(
                ParserError.UnterminatedString,
                defs.ERROR_SQSTR_UNTERMIN,
                .{ self.line, self.pos },
            );
        }

        try str.append(c);
        // string processing .
        while (self.nextByte(&c)) {
            if (c == '\'') {
                return;
            }

            // Control characters other than tab are not permitted.
            if ((0x00 <= c and c <= 0x08) or (0x0A <= c and c <= 0x1F) or (c == 0x7F)) {
                return err.reportError(
                    ParserError.ForbiddenStringChar,
                    defs.ERROR_STRING_FORBIDDEN,
                    .{ self.line, self.pos, c },
                );
            }

            try str.append(c);
        }

        // Error:
        // Reached End of stream without closing the string.
        return err.reportError(
            ParserError.UnterminatedString,
            defs.ERROR_SQSTR_UNTERMIN,
            .{ self.line, self.pos },
        );
    }

    pub fn nextStringDQ(self: *Self, str: *types.String, err: *ErrorContext, is_key: bool) !void {
        var c: u8 = undefined;
        var multi_line = false;
        if (self.nextByte(&c) and c == '"') {
            // Possibly a multi-line literal string.
            if (!self.nextByte(&c) or c != '"') {
                // Empty.
                // Rewind before returning.
                self.toLastByte();
                return;
            }
            if (is_key) {
                // keys can't be a multi-line
                return err.reportError(
                    ParserError.BadSyntax,
                    defs.ERROR_BAD_SYNTAX,
                    .{ self.line, self.pos, "Quotted keys can't be multi-line" },
                );
            }
            multi_line = true;
            // A newline immediately following the opening delimiter will be trimmed.
            self.trimNewLine();
        } else {
            try str.append(c);
        }

        while (self.nextByte(&c)) {
            if (c == '"') {
                if (multi_line) {
                    var sequence = [2]u8{ '"', '"' };
                    const match = self.matchNextSequence(2, &sequence) catch {
                        // Error:
                        // Reached End of stream without closing the string.
                        return err.reportError(
                            ParserError.UnterminatedString,
                            defs.ERROR_DQSTR_UNTERMIN,
                            .{ self.line, self.pos },
                        );
                    };
                    if (match) {
                        try self.handlePreDelimQuottes(str, '"');
                        return;
                    } else {
                        // check for any " in the sequence and append them
                        try str.append(c);
                        var n: u8 = 2;
                        for (0..2) |i| {
                            if (sequence[i] == '"') {
                                try str.append(c);
                                n -= 1;
                                continue;
                            } else {
                                self.toLastNByte(n);
                                break;
                            }
                        }
                        continue;
                    }
                } else {
                    return;
                }
            }

            if (c != '\\') {
                // Control characters other than tab are not permitted.
                if ((0x00 <= c and c <= 0x08) or (0x0A <= c and c <= 0x1F) or (c == 0x7F)) {
                    if (!multi_line or (c != '\n' and c != '\r')) {
                        return err.reportError(
                            ParserError.ForbiddenStringChar,
                            defs.ERROR_STRING_FORBIDDEN,
                            .{ self.line, self.pos, c },
                        );
                    }
                }
                try str.append(c);
            } else {
                // Handle escaped character.
                if (self.nextByte(&c)) {
                    switch (c) {
                        ' ', '\t', '\r', '\n' => {
                            if (!multi_line) {
                                return err.reportError(
                                    ParserError.ForbiddenStringChar,
                                    defs.ERROR_STRING_FORBIDDEN,
                                    .{ self.line, self.pos, c },
                                );
                            }

                            // Skip until the next non-whitespace char.
                            while (self.nextByte(&c)) {
                                switch (c) {
                                    ' ', '\t', '\r', '\n' => continue,
                                    else => break,
                                }
                            }

                            self.toLastByte();
                            continue;
                        },
                        'u', 'U' => {
                            const cp_len: u8 = if (c == 'u') 4 else 8;
                            var cp_slice: []const u8 = undefined;
                            var code_point: [8]u8 = undefined;
                            for (0..cp_len) |i| {
                                if (self.nextByte(&c)) {
                                    if (std.ascii.isHex(c)) {
                                        code_point[i] = c;
                                    } else {
                                        return err.reportError(
                                            ParserError.BadStringEscSeq,
                                            defs.ERROR_STRING_BAD_ESC,
                                            .{ self.line, self.pos - 1 },
                                        );
                                    }
                                } else {
                                    // End of stream.
                                    break;
                                }
                            }
                            cp_slice.ptr = &code_point;
                            cp_slice.len = cp_len;
                            const hex = fmt.parseInt(u32, cp_slice, 16) catch {
                                return err.reportError(
                                    ParserError.BadStringEscSeq,
                                    defs.ERROR_STRING_BAD_ESC,
                                    .{ self.line, self.pos - 1 },
                                );
                            };
                            cp_slice.len = std.unicode.utf8Encode(@intCast(hex), &code_point) catch {
                                return err.reportError(
                                    ParserError.BadStringEscSeq,
                                    defs.ERROR_STRING_BAD_ESC,
                                    .{ self.line, self.pos - 1 },
                                );
                            };
                            try str.writer().writeAll(cp_slice);
                            continue;
                        },
                        'b' => c = 0x08, // Backspace
                        't' => c = '\t',
                        'n' => {
                            c = '\n';
                        },
                        'f' => c = 0x0C, // Form feed
                        'r' => c = '\r',
                        '"', '\\' => {
                            try str.append('\\');
                        }, // No need to escape.
                        else => {
                            // What are you trying to escape.
                            return err.reportError(
                                ParserError.BadStringEscSeq,
                                defs.ERROR_STRING_BAD_ESC,
                                .{ self.line, self.pos },
                            );
                        },
                    }
                    try str.append(c);
                }
            }
        }
        // Error :
        // Reached End of stream without closing the string.
        return err.reportError(
            ParserError.UnterminatedString,
            defs.ERROR_DQSTR_UNTERMIN,
            .{ self.line, self.pos },
        );
    }

    fn nextBool(self: *Self, start: u8) !bool {
        switch (start) {
            't' => {
                var buff: [3]u8 = undefined;
                try self.src.reader().readNoEof(&buff);
                if (mem.eql(u8, &buff, &[3]u8{ 'r', 'u', 'e' })) {
                    return true;
                } else {
                    return ParserError.BadSyntax;
                }
            },
            'f' => {
                var buff: [4]u8 = undefined;
                try self.src.reader().readNoEof(&buff);
                if (mem.eql(u8, &buff, &[4]u8{ 'a', 'l', 's', 'e' })) {
                    return false;
                } else {
                    return ParserError.BadSyntax;
                }
            },
            else => unreachable,
        }
    }

    fn readRawValue(self: *Self, buff: []u8) !usize {
        var c: u8 = undefined;
        var i: usize = 1;
        while (self.nextByte(&c)) {
            if (c == '\n' or c == ',' or c == ']') {
                self.toLastByte();
                break;
            }
            if (i >= buff.len) {
                return ParserError.OutOfMemory;
            }
            if (c == ' ') {
                // RFC 3339 section 5.6
                // Date-Time might omit T and replace it with a space.
                if (self.nextByte(&c)) {
                    if (ascii.isDigit(c)) {
                        buff[i] = 'T';
                        i += 1;
                        if (i >= buff.len) {
                            return ParserError.OutOfMemory;
                        }
                        buff[i] = c;
                        i += 1;
                        continue;
                    } else {
                        // Rewind.
                        self.toLastByte();
                        break;
                    }
                }
                break;
            }
            buff[i] = c;
            i += 1;
        }
        return i;
    }

    fn nextInt(buff: []const u8, success: *bool) i64 {
        const num = fmt.parseInt(i64, buff, 0) catch {
            success.* = false;
            return 0;
        };
        success.* = true;
        return num;
    }

    fn nextFloat(buff: []const u8, success: *bool) f64 {
        // Sanitize
        if (buff.len == 0) {
            // empty.
            success.* = false;
            return 0;
        }

        if (buff[0] == '+' or buff[0] == '-') {
            if (buff.len > 1 and buff[1] == '_') {
                // +_ not allowed at the start.
                success.* = false;
                return 0;
            }
        } else {
            if (buff[0] == '_') {
                // _ not allowed at the start.
                success.* = false;
                return 0;
            } else if (buff[0] == '0') {}
        }
        const dot_index = ascii.indexOfIgnoreCase(buff, &[_]u8{'.'});

        if (dot_index) |i| {
            // decimal point, if used, must be surrounded
            // by at least one digit on each side
            if (i == 0 or i == buff.len - 1) {
                // .7 or 7. isn't allowed
                success.* = false;
                return 0;
            } else if (!ascii.isDigit(buff[i - 1]) or !ascii.isDigit(buff[i + 1])) {
                success.* = false;
                return 0;
            }
        }

        const num = fmt.parseFloat(f64, buff) catch {
            success.* = false;
            return 0;
        };
        success.* = true;
        return num;
    }

    fn lexRawValue(buff: []const u8, val: *types.Value) !void {
        var success: bool = false;
        var i = nextInt(buff, &success);
        if (success) {
            val.* = .{ .Integer = i };
            return;
        }

        var f = nextFloat(buff, &success);
        if (success) {
            val.* = .{ .Float = f };
            return;
        }

        // either a date or fail.
        var ts = try date_time.DateTime.fromString(buff);
        val.* = .{ .DateTime = ts };
        return;
    }

    pub fn nextValue(self: *Self, val: *types.Value, start: u8) !void {
        if (start == 't' or start == 'f') {
            // Either a bool or error
            const b = try self.nextBool(start);
            val.* = .{ .Boolean = b };
        } else {
            // An int,float or Date/timestamp
            var buff: [256]u8 = undefined;
            buff[0] = start;
            const len = try self.readRawValue(&buff);
            try lexRawValue(buff[0..len], val);
        }
    }
};
