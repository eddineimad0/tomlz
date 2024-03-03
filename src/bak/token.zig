pub const TokenType = enum(u8) {
    EOS, // End Of Stream (be more inclusive)
    EOL, // End Of Line
    Dot,
    Comma,
    Equal,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    String,
    IdentStart,
};

pub const Token = struct {
    cntxt: struct {
        type: TokenType,
        line: usize,
        pos: u64,
    },
    c: u8,
    const Self = @This();

    pub inline fn setContext(self: *Self, t: TokenType, pos: u64, line: usize) void {
        self.cntxt.type = t;
        self.cntxt.pos = pos;
        self.cntxt.line = line;
    }
};
