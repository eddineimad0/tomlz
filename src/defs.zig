const b = @import("builtin");
pub const IS_WINDOWS: bool = b.os.tag == .windows;
pub const UTF8BOMLE: u24 = 0xBFBBEF;
// Options
pub const MAX_NESTTING_LEVEL = @as(u8, 8);
pub const INITAL_KEY_LEN = @as(u8, 128);
pub const INITAL_STRING_LEN = @as(u16, 512);
pub const INITAL_ERROR_BUFFER_LEN = @as(u16, 256);
// Errors Formats
pub const ERROR_HEADER = "[line:{d},col:{d}] ";
pub const ERROR_OUT_OF_MEMORY = "Couldn't allocate memory.";
pub const ERROR_BAD_SYNTAX = ERROR_HEADER ++ "Bad syntax: {s}";
pub const ERROR_DUP_KEY = ERROR_HEADER ++ "Reassignment to key `{s}`.";
pub const ERROR_DUP_TABLE = ERROR_HEADER ++ "Table `{s}` was redefined.";
pub const ERROR_BAD_KEY = ERROR_HEADER ++ "Key can't contain `{c}` character";
pub const ERROR_BAD_VALUE = ERROR_HEADER ++ "Unkown Value type";
pub const ERROR_NESSTING = ERROR_HEADER ++ "Surpassed the maximum allowed nestting level.";
pub const ERROR_MISSING_EQUAL = ERROR_HEADER ++ "Expected and `=` in front of key `{s}`.";
pub const ERROR_DQSTR_UNTERMIN = ERROR_HEADER ++ "Missing string delimiter:\"";
pub const ERROR_SQSTR_UNTERMIN = ERROR_HEADER ++ "Missing string delimiter:\'";
pub const ERROR_STRING_FORBIDDEN = ERROR_HEADER ++ "Forbidden string byte: `0x{x:0>2}`, was found.";
pub const ERROR_STRING_BAD_ESC = ERROR_HEADER ++ "Bad string escape sequence.";
