const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const Option = union(enum) {
    extract: ?[]const u8,
    list: ?[]const u8,
    file: ?[]const u8,
    hashes: ?[]const u8,
    unknown,
};

pub const OptionIterator = struct {
    buffer: []const u8,
    index: ?usize,

    pub fn next(self: *OptionIterator) ?Option {
        var start = self.index orelse return null;
        if (start == 0) {
            if (self.buffer.len < 2) {
                self.index = null;
                return null;
            }
            if (self.buffer[0] == '-' and self.buffer[1] == '-') {
                self.index = null;
                return getOptionFromName(self.buffer[2..]); // todo: handle key value pairs --file=bob
            }
            self.index.? += 1;
            start += 1;
        }

        if (start == self.buffer.len) {
            self.index = null;
            return null;
        }
        self.index.? += 1;

        return switch (self.buffer[start]) {
            't' => .{ .list = null },
            'x' => .{ .extract = null },
            'f' => .{ .file = null },
            'h' => .{ .hashes = null },
            else => .unknown,
        };
    }
};

pub fn optionIterator(slice: []const u8) OptionIterator {
    assert(mem.count(u8, slice, " ") == 0);
    return .{
        .buffer = slice,
        .index = 0,
    };
}

fn getOptionFromName(slice: []const u8) Option {
    if (slice.len <= 1) return .unknown;

    const end = mem.indexOfScalar(u8, slice, '=');
    const key = slice[0 .. end orelse slice.len];
    const val = if (end) |pos| slice[pos + 1 ..] else null;

    if (mem.eql(u8, key, "list")) return .{ .list = val };
    if (mem.eql(u8, key, "extract")) return .{ .extract = val };
    if (mem.eql(u8, key, "get")) return .{ .extract = val };
    if (mem.eql(u8, key, "file")) return .{ .file = val };
    if (mem.eql(u8, key, "hashes")) return .{ .hashes = val };
    return .unknown;
}