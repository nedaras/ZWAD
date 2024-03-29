const std = @import("std");
const PathThree = @import("PathThree.zig");

extern fn ZSTD_decompress(dst: *anyopaque, dst_len: usize, src: *const anyopaque, src_len: usize) usize;
extern fn ZSTD_compress(dst: *anyopaque, dst_len: usize, src: *const anyopaque, src_len: usize, compression_level: c_int) usize;
extern fn ZSTD_getErrorName(code: usize) [*c]const u8;
extern fn ZSTD_isError(code: usize) bool;

const XXH3_state_s = extern struct {
    a: u128 = 0,
    b: u128 = 0,
    c: u128 = 0,
    d: u128 = 0,
};

extern fn ZSTD_XXH64(input: *const anyopaque, length: usize, seed: u64) u64;

// why we ant incldue these
extern fn ZSTD_XXH_INLINE_XXH3_128bits_reset(statePtr: *XXH3_state_s) c_int;
extern fn ZSTD_XXH_INLINE_XXH3_128bits_update(statePtr: *XXH3_state_s, input: *const anyopaque, len: usize) c_int;

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const fmt = std.fmt;
const print = std.debug.print;
const Allocator = mem.Allocator;
const File = fs.File;

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,

    fn latest() Version {
        return .{ .magic = [_]u8{ 'R', 'W' }, .major = 3, .minor = 3 };
    }
};

const HeaderV3 = extern struct {
    signature: [16]u8,
    signature_unused: [240]u8,
    checksum: [8]u8,
    entries_count: u32,
};

const EntryType = enum(u4) { raw, link, gzip, zstd, zstd_multi };

const EntryV3 = packed struct {
    hash: u64,
    offset: u32,
    size_compressed: u32,
    size_decompressed: u32,
    type: EntryType,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

pub const WADFile = struct {
    file: File,
    entries_count: u32,

    entry_index: u32 = 0,

    pub const OpenError = error{
        InvalidVersion,
    } || File.OpenError;

    pub const DecompressError = error{
        InvalidEntry,
        InvalidEntryType,
        InvalidEntrySize,
    } || Allocator.Error || File.ReadError || File.SeekError || File.GetSeekPosError;

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.entries_count) return null;

        self.entry_index += 1;

        const reader = self.file.reader();
        return try reader.readStruct(EntryV3);
    }

    fn fillBuffer(self: WADFile, buffer: []u8, offset: u32) !void {
        const pos = try self.file.getPos();
        try self.file.seekTo(offset);

        _ = try self.file.read(buffer);

        try self.file.seekTo(pos);
    }

    // well multithreading would be cool
    pub fn decompressEntry(self: WADFile, allocator: Allocator, entry: EntryV3) DecompressError![]u8 {
        var out = try allocator.alloc(u8, entry.size_decompressed);
        errdefer allocator.free(out);

        switch (entry.type) {
            EntryType.raw => {
                if (entry.size_compressed != entry.size_decompressed) return WADFile.DecompressError.InvalidEntrySize;

                try self.fillBuffer(out, entry.offset);
                return out;
            },
            EntryType.zstd => {
                var src = try allocator.alloc(u8, entry.size_compressed);
                defer allocator.free(src);

                try self.fillBuffer(src, entry.offset);

                const bytes = ZSTD_decompress(out.ptr, entry.size_decompressed, src.ptr, entry.size_compressed);
                if (ZSTD_isError(bytes)) return WADFile.DecompressError.InvalidEntry;
            },
            else => return WADFile.DecompressError.InvalidEntryType,
        }

        return out;
    }

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    const reader = file.reader(); // we can read ver and head with one sys call

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);

    return .{
        .file = file,
        .entries_count = header.entries_count,
    };
}

pub fn importHashes(allocator: Allocator, path: []const u8) !PathThree {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var buffered_reader = io.bufferedReader(file.reader());

    var three = PathThree.init(allocator);
    errdefer three.deinit();

    // TODO: make buffer size of MAX_PATH_LEN + 16(hash) + 1(space)
    // and we we get error out of mem we will try ig change the file name
    var buffer: [1024 * 8]u8 = undefined;
    while (try streamUntilDelimiterOrEof(&buffered_reader, &buffer, '\n')) |data| {
        const hex_hash = data[0..16];
        const file_path = data[16 + 1 ..];

        const hash = try std.fmt.parseInt(u64, hex_hash, 16);

        try three.addFile(file_path, hash);
    }

    return three;
}

fn streamUntilDelimiterOrEof(buffered: anytype, buffer: []u8, delimiter: u8) !?[]u8 {
    var fbs = io.fixedBufferStream(buffer);
    const writer = fbs.writer();

    while (true) {
        const start = buffered.start;
        if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) |pos| {
            try writer.writeAll(buffered.buf[start .. start + pos]);
            buffered.start += pos + 1;
            break;
        }
        try writer.writeAll(buffered.buf[start..buffered.end]);

        const n = try buffered.unbuffered_reader.read(buffered.buf[0..]);

        if (n == 0) return null;

        buffered.start = 0;
        buffered.end = n;
    }

    const output = fbs.getWritten();
    buffer[output.len] = delimiter; // emulating old behaviour
    return output;
}

fn makeFile(path: []const u8, hash: u64, data: []const u8) !void {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') break;
    }

    try fs.cwd().makePath(path[0..i]);
    fs.cwd().writeFile(path, data) catch |err| {
        if (err != error.NameTooLong) return err;

        var buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
        const file_path = try fmt.bufPrint(&buffer, "{s}/{d}", .{ path[0..i], hash });

        try fs.cwd().writeFile(file_path, data);
    };
}

pub fn extractWAD(allocator: Allocator, wad: []const u8, out: []const u8, hashes: PathThree) !void {
    var wad_file = try openFile(wad);
    defer wad_file.close();

    while (try wad_file.next()) |entry| {
        const data = try wad_file.decompressEntry(allocator, entry);
        defer allocator.free(data);

        // remove alloc print for these print functions, and only put the hash if out of mem error
        const file_name = try hashes.getFile(allocator, entry.hash);

        if (file_name) |file| {
            defer allocator.free(file);

            const path = try fmt.allocPrint(allocator, "{s}//{s}", .{ out, file });
            defer allocator.free(path);

            try makeFile(path, entry.hash, data);

            continue;
        }

        const path = try fmt.allocPrint(allocator, "{s}/{d}", .{ out, entry.hash });
        // add extract wad into memory
        // f
        defer allocator.free(path);

        try makeFile(path, entry.hash, data);
    }
}

fn isHashedFile(file_name: []const u8) bool {
    for (file_name) |c| {
        if (c >= '0' and c <= '9') continue;
        return false;
    }
    return true;
}

// would be the coolest thing ever if we would like compress hashes in entry, like its hash would be zeros,
// and from there we could get file names, and if there is now hash with zero at index 1 it means that there are no hashes
pub fn makeWAD(allocator: Allocator, wad: []const u8, out: []const u8, hashes: []const u8) !void {
    var entries = std.ArrayList(EntryV3).init(allocator);
    defer entries.deinit();

    const path_iteratable_dir = try fs.cwd().openIterableDir(wad, .{});

    var entries_count: u32 = 0;

    {
        const hashes_file = try fs.cwd().createFile(hashes, .{});
        defer hashes_file.close();

        var buffered_writer = io.bufferedWriter(hashes_file.writer());
        const writer = buffered_writer.writer();

        var buffer: [16 + 1 + fs.MAX_PATH_BYTES + 1]u8 = undefined;

        var path_iterator = try path_iteratable_dir.walk(allocator);
        defer path_iterator.deinit();

        while (try path_iterator.next()) |entry| : (entries_count += 1) {
            if (entry.kind == .directory) continue;

            if (isHashedFile(entry.basename)) continue;
            const hash = ZSTD_XXH64(entry.path.ptr, entry.path.len, 0);

            const line = try fmt.bufPrint(&buffer, "{x:0>16} {s}\n", .{ hash, entry.path });
            _ = try writer.write(line);
        }
    }

    var out_file = try fs.cwd().createFile(out, .{});
    defer out_file.close();

    const writer = out_file.writer();

    try writer.writeStruct(Version.latest());

    var path_iterator = try path_iteratable_dir.walk(allocator);
    defer path_iterator.deinit();

    print("{d}\n", .{@sizeOf(EntryV3)});

    while (try path_iterator.next()) |entry| {
        //const entry_file = try entry.dir.openFile(entry.basename, .{});
        //defer entry_file.close();

        //const size_decompressed = try entry_file.getEndPos();

        //var data = try allocator.alloc(u8, size_decompressed);
        //defer allocator.free(data);

        //var dt = try allocator.alloc(u8, size_decompressed);
        //defer allocator.free(dt);

        //_ = try entry_file.readAll(data);

        // TODO: if compressed is bigger t means we need to use raw
        //const size_compressed = ZSTD_compress(dt.ptr, size_decompressed, data.ptr, size_decompressed, 0);

        //if (ZSTD_isError(size_compressed)) {
        //print("err: {s}\n", .{ZSTD_getErrorName(size_compressed)});
        _ = entry;
    }

    var state: XXH3_state_s = .{};
    _ = ZSTD_XXH_INLINE_XXH3_128bits_reset(&state);
    _ = ZSTD_XXH_INLINE_XXH3_128bits_update(&state, &Version.latest(), @sizeOf(Version));

    //print("fine\n", .{});

    //const wad_entry: EntryV3 = .{
    //.hash = hash,
    //.offset = 0,
    //.size_compressed = @intCast(size_compressed),
    //.size_decompressed = @intCast(size_decompressed),
    //.type = EntryType.zstd,
    //.subchunk_count = 0,
    //.is_duplicate = 0,
    //.subchunk_index = 0,
    //.checksum_old = 0,
    //};

    //try entries.append(wad_entry);
    //}

}
