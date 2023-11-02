const std = @import("std");
const ascii = std.ascii;
const utils = @import("utils.zig");

pub const DateTimeError = error{
    InvalidDate,
    InvalidTime,
    BadDateTimeFormat,
};

const Date = struct {
    // year   = 4DIGIT
    // month  = 2DIGIT  ; 01-12
    // day    = 2DIGIT  ; 01-28, 01-29, 01-30, 01-31 based on month/year
    year: u32,
    month: u8,
    day: u8,

    const Self = @This();

    pub fn init(y: u32, m: u8, d: u8) Self {
        return Self{
            .year = y,
            .month = m,
            .day = d,
        };
    }

    // Parses a string of format YYYY-MM-DD into
    // a Date instance.
    pub fn fromString(src: []const u8) ?Self {
        if (src.len < 10) {
            return null;
        }
        if (src[4] != '-' or src[7] != '-') {
            return null;
        }
        const y = utils.parseDigits(u32, src[0..4]) catch return null;
        const m = utils.parseDigits(u8, src[5..7]) catch return null;
        const d = utils.parseDigits(u8, src[8..10]) catch return null;
        return init(y, m, d);
    }

    // Preform validation on the month and day field
    pub fn isValid(self: *const Self) bool {
        if (self.month > 12 or self.day > 31) {
            return false;
        }

        // This assumes that the year is a 4 digits year.
        const year_by_100 = @rem(self.year, 100);
        var is_leap = (self.year >> 2 == 0 and (year_by_100 != 0 or year_by_100 >> 2 == 0));

        switch (self.month) {
            2 => {
                if (self.day > 29) {
                    return false;
                } else if (!is_leap and self.day > 28) {
                    return false;
                }
            },
            4, 6, 9, 11 => {
                if (self.day > 30) {
                    return false;
                }
            },
            else => {},
        }
        return true;
    }
};

const TimeOffset = struct {
    // Suffix which denotes a UTC offset of 00:00
    z: bool,
    // Optional offset between local time and UTC
    minutes: i16,
};

const Time = struct {
    // hour    = 2DIGIT  ; 00-23
    // minute  = 2DIGIT  ; 00-59
    // second  = 2DIGIT  ; 00-58, 00-59, 00-60 based on leap second
    hour: u8,
    minute: u8,
    second: u8,
    nano_sec: u32,
    offset: ?TimeOffset,
    const Self = @This();

    pub fn init(h: u8, m: u8, s: u8, ns: u32, offs: ?TimeOffset) Self {
        return Self{
            .hour = h,
            .minute = m,
            .second = s,
            .nano_sec = ns,
            .offset = offs,
        };
    }

    /// Parses a string into a Time instance.
    /// Accepted formats:
    /// HH:MM:SS.FFZ
    /// HH:MM:SS.FF
    pub fn fromString(src: []const u8) ?Self {
        if (src.len < 8) {
            return null;
        }
        if (src[2] != ':' or src[5] != ':') {
            return null;
        }
        const h = utils.parseDigits(u8, src[0..2]) catch return null;
        const m = utils.parseDigits(u8, src[3..5]) catch return null;
        const s = utils.parseDigits(u8, src[6..8]) catch return null;

        var ns: u32 = 0;

        var offs: ?TimeOffset = null;

        if (src.len > 8) {
            var slice = src[8..src.len];
            if (slice[0] == '.') {
                const stop = parseNS(slice[1..slice.len], &ns);
                slice = slice[stop + 1 .. slice.len];
            }

            if (slice.len > 0) {
                switch (slice[0]) {
                    'Z', 'z' => offs = TimeOffset{ .z = true, .minutes = 0 },
                    '+', '-' => {
                        var sign: i16 = switch (slice[0]) {
                            '+' => -1,
                            '-' => 1,
                            else => return null,
                        };
                        if (slice.len < 6 or slice[3] != ':') {
                            return null;
                        }
                        var off_h: u8 = utils.parseDigits(u8, slice[1..3]) catch return null;
                        var off_m: u8 = utils.parseDigits(u8, slice[4..6]) catch return null;

                        offs = TimeOffset{
                            .z = false,
                            .minutes = ((@as(i16, off_h) * 60) + @as(i16, off_m)) * sign,
                        };
                    },
                    else => return null,
                }
            }
        }

        return init(
            h,
            m,
            s,
            ns,
            offs,
        );
    }

    fn parseNS(src: []const u8, ns: *u32) usize {
        ns.* = 0;
        var offset: u32 = 100000000;
        for (0..src.len) |i| {
            if (ascii.isDigit(src[i])) {
                ns.* = ns.* + (src[i] - '0') * offset;
                offset /= 10;
            } else {
                return i;
            }
        }
        return src.len;
    }

    pub fn isValid(self: *const Self) bool {
        if (self.hour > 23 or self.minute > 59 or self.second > 59) {
            return false;
        }
        return true;
    }
};

pub const DateTime = struct {
    date: ?Date,
    time: ?Time,

    const Self = @This();
    pub fn init(d: *const Date, t: *const Time) Self {
        return Self{
            .date = d.*,
            .time = t.*,
        };
    }

    pub fn fromString(src: []const u8) !Self {
        var self: Self = undefined;
        var slice = src;
        self.date = Date.fromString(slice);

        if (self.date) |*d| {
            if (!d.isValid()) {
                return DateTimeError.InvalidDate;
            }
            if (slice.len > 10 and (slice[10] == 'T' or slice[10] == 't')) {
                slice = slice[11..slice.len];
            } else {
                self.time = null;
                return self;
            }
        }

        self.time = Time.fromString(slice);

        if (self.time) |*t| {
            if (!t.isValid()) {
                return DateTimeError.InvalidTime;
            }
        } else {
            if (self.date == null) {
                // Error couldn't parse a date or a time
                return DateTimeError.BadDateTimeFormat;
            }
        }

        return self;
    }
};

test "DateTime" {
    const testing = std.testing;
    try testing.expectError(DateTimeError.InvalidDate, DateTime.fromString("1977-02-29T07:32:00"));
}
