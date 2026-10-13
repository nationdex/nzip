//! nzip core — zero-copy, range-aware remote ZIP reader.
//!
//! Three linear steps, no full download:
//!   1. Range-read the tail window, locate + parse the EOCD (and ZIP64 locator).
//!   2. Range-read the Central Directory, index every entry.
//!   3. Range-read exactly the target's local header + compressed stream and
//!      hand the payload to nstd's inflate / zstd decoder.

const std = @import("std");
const nstd = @import("nstd");
const Allocator = std.mem.Allocator;

pub const SIG_LFH: u32 = 0x04034b50;
pub const SIG_CD: u32 = 0x02014b50;
pub const SIG_EOCD: u32 = 0x06054b50;
pub const SIG_Z64_EOCD: u32 = 0x06064b50;
pub const SIG_Z64_LOC: u32 = 0x07064b50;

/// Big enough for the largest legal EOCD (22 fixed + 65535 comment bytes).
/// Used only when the first, small probe fails to locate the EOCD.
pub const TAIL_WINDOW: u64 = 22 + 65535;

/// First probe size. Covers EOCD + a few KiB of central directory, which is
/// all a typical archive needs; the escalation above handles the rest.
pub const TAIL_PROBE: u64 = 4096;

pub const Method = enum(u16) {
    stored = 0,
    deflate = 8,
    bzip2 = 12,
    lzma = 14,
    zstd = 93,
    _,
};

/// Caller-supplied byte-range provider. Must fill `dst[0..len]` with the
/// archive bytes at `offset`. Returns 0 on success, non-zero on failure.
pub const RangeFn = *const fn (ctx: ?*anyopaque, offset: u64, len: usize, dst: [*]u8) callconv(.C) c_int;

pub const Entry = struct {
    name: []const u8,
    method: u16,
    flags: u16,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    local_header_offset: u64,
    index: u32,

    pub fn isDirectory(e: Entry) bool {
        return e.name.len > 0 and e.name[e.name.len - 1] == '/';
    }

    pub fn methodName(e: Entry) []const u8 {
        return switch (@as(Method, @enumFromInt(e.method))) {
            .stored => "stored",
            .deflate => "deflate",
            .bzip2 => "bzip2",
            .lzma => "lzma",
            .zstd => "zstd",
            _ => "unknown",
        };
    }
};

pub const Stats = struct {
    range_calls: u64 = 0,
    fetched_bytes: u64 = 0,
};

pub const Error = error{
    NotAZip,
    NoEocd,
    Truncated,
    CorruptCentralDirectory,
    CorruptLocalHeader,
    EntryNotFound,
    BufferTooSmall,
    UnsupportedMethod,
    ChecksumMismatch,
    RangeReadFailed,
    OutOfMemory,
};

fn rd16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}
fn rd32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
fn rd64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

pub const Archive = struct {
    alloc: Allocator,
    range: RangeFn,
    ctx: ?*anyopaque,
    total_size: u64,

    cd: []u8 = &.{},
    entries: []Entry = &.{},
    lookup: std.StringHashMapUnmanaged(u32) = .{},

    zip64: bool = false,
    eocd_offset: u64 = 0,
    cd_offset: u64 = 0,
    cd_size: u64 = 0,
    /// Check the CRC-32 from the central directory after every decompress.
    verify_crc: bool = false,
    stats: Stats = .{},

    /// Step 1 + 2. Opens the archive using only ranged reads.
    ///
    /// Reads a small tail probe first (4 KiB). That is enough whenever the
    /// EOCD and the central directory both sit near the end, which is the
    /// common case and costs a single round trip. Otherwise the window
    /// escalates to the guaranteed 64 KiB + comment span, or the central
    /// directory is fetched by exact range.
    pub fn open(alloc: Allocator, range: RangeFn, ctx: ?*anyopaque, total_size: u64) Error!*Archive {
        if (total_size < 22) return error.NotAZip;

        const a = alloc.create(Archive) catch return error.OutOfMemory;
        a.* = .{
            .alloc = alloc,
            .range = range,
            .ctx = ctx,
            .total_size = total_size,
        };
        errdefer a.deinit();

        // ---- Step 1: locate the EOCD ----
        var tail_len: usize = @intCast(@min(total_size, TAIL_PROBE));
        var tail_start: u64 = total_size - tail_len;
        var tail = alloc.alloc(u8, tail_len) catch return error.OutOfMemory;
        defer alloc.free(tail);
        try a.readInto(tail_start, tail);

        const eocd: usize = if (findEocdAbs(tail, tail_start, total_size)) |rel| rel else |err| blk: {
            if (err != error.NoEocd) return err;
            // Escalate: EOCD (or its comment) is bigger than the probe.
            alloc.free(tail);
            tail_len = @intCast(@min(total_size, TAIL_WINDOW));
            tail_start = total_size - tail_len;
            tail = alloc.alloc(u8, tail_len) catch return error.OutOfMemory;
            try a.readInto(tail_start, tail);
            break :blk try findEocdAbs(tail, tail_start, total_size);
        };
        a.eocd_offset = tail_start + eocd;

        var total_entries: u64 = rd16(tail[eocd + 10 ..]);
        var cd_size: u64 = rd32(tail[eocd + 12 ..]);
        var cd_offset: u64 = rd32(tail[eocd + 16 ..]);

        // ---- ZIP64 upgrade ----
        const need_z64 = total_entries == 0xFFFF or
            cd_size == 0xFFFFFFFF or
            cd_offset == 0xFFFFFFFF;
        if (need_z64) {
            a.zip64 = true;
            var loc: [20]u8 = undefined;
            const loc_off = a.eocd_offset - 20;
            if (eocd >= 20) {
                const rel = eocd - 20;
                @memcpy(&loc, tail[rel..][0..20]);
            } else {
                try a.readInto(loc_off, &loc);
            }
            if (rd32(&loc) != SIG_Z64_LOC) return error.NotAZip;
            const z64_off = rd64(loc[8..]);

            var z64: [56]u8 = undefined;
            if (z64_off >= tail_start and z64_off + 56 <= tail_start + tail.len) {
                const rel: usize = @intCast(z64_off - tail_start);
                @memcpy(&z64, tail[rel..][0..56]);
            } else {
                try a.readInto(z64_off, &z64);
            }
            if (rd32(&z64) != SIG_Z64_EOCD) return error.NotAZip;
            total_entries = rd64(z64[32..]);
            cd_size = rd64(z64[40..]);
            cd_offset = rd64(z64[48..]);
        }

        if (cd_offset > total_size or cd_size > total_size or cd_offset + cd_size > total_size) {
            return error.Truncated;
        }
        a.cd_offset = cd_offset;
        a.cd_size = cd_size;

        // ---- Step 2: central directory ----
        if (cd_size == 0) {
            a.cd = alloc.alloc(u8, 0) catch return error.OutOfMemory;
        } else if (cd_offset >= tail_start and cd_offset + cd_size <= tail_start + tail.len) {
            // Already in the tail buffer: zero extra network round-trips.
            const rel: usize = @intCast(cd_offset - tail_start);
            a.cd = alloc.dupe(u8, tail[rel..][0..cd_size]) catch return error.OutOfMemory;
        } else {
            // Exact range fetch: only the central directory, nothing else.
            a.cd = alloc.alloc(u8, cd_size) catch return error.OutOfMemory;
            errdefer {
                alloc.free(a.cd);
                a.cd = &.{};
            }
            try a.readInto(cd_offset, a.cd);
        }

        try a.indexEntries(@intCast(total_entries));
        return a;
    }

    pub fn deinit(a: *Archive) void {
        a.lookup.deinit(a.alloc);
        a.alloc.free(a.entries);
        a.alloc.free(a.cd);
        a.alloc.destroy(a);
    }

    /// Number of entries in the archive.
    pub fn count(a: *const Archive) usize {
        return a.entries.len;
    }

    /// O(1) name lookup. Returns entry index.
    pub fn find(a: *const Archive, name: []const u8) ?u32 {
        return a.lookup.get(name);
    }

    pub fn entryAt(a: *const Archive, index: u32) ?Entry {
        if (index >= a.entries.len) return null;
        return a.entries[index];
    }

    /// Step 3. Decompress entry `index` into caller memory.
    pub fn extractAt(a: *Archive, index: u32, dst: []u8) Error!usize {
        const e = a.entries[index];
        if (e.uncompressed_size > dst.len) return error.BufferTooSmall;
        if (e.isDirectory()) return 0;

        const payload = try a.fetchPayload(e);
        defer if (payload.base) |b| a.alloc.free(b);
        const n = try inflateInto(a.alloc, e, payload.bytes, dst);
        try a.checkCrc(e, dst[0..n]);
        return n;
    }

    pub fn extract(a: *Archive, name: []const u8, dst: []u8) Error!usize {
        const idx = a.find(name) orelse return error.EntryNotFound;
        return a.extractAt(idx, dst);
    }

    /// Like extractAt but allocates the output buffer.
    pub fn extractAlloc(a: *Archive, index: u32) Error![]u8 {
        const e = a.entries[index];
        if (e.isDirectory()) return a.alloc.alloc(u8, 0) catch return error.OutOfMemory;

        const payload = try a.fetchPayload(e);
        defer if (payload.base) |b| a.alloc.free(b);

        const out = a.alloc.alloc(u8, e.uncompressed_size) catch return error.OutOfMemory;
        errdefer a.alloc.free(out);
        const n = try inflateInto(a.alloc, e, payload.bytes, out);
        if (n != out.len) {
            a.alloc.free(out);
            return error.Truncated;
        }
        a.checkCrc(e, out) catch |err| {
            a.alloc.free(out);
            return err;
        };
        return out;
    }

    fn checkCrc(a: *const Archive, e: Entry, data: []const u8) Error!void {
        if (!a.verify_crc) return;
        const got = nstd.core.checksum.crc32(data, 0);
        if (got != e.crc32) return error.ChecksumMismatch;
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    fn readInto(a: *Archive, offset: u64, buf: []u8) Error!void {
        if (buf.len == 0) return;
        if (offset + buf.len > a.total_size) return error.Truncated;
        a.stats.range_calls += 1;
        a.stats.fetched_bytes += buf.len;
        const rc = a.range(a.ctx, offset, buf.len, buf.ptr);
        if (rc != 0) return error.RangeReadFailed;
    }

    fn indexEntries(a: *Archive, total_entries: u32) Error!void {
        const cd = a.cd;
        var list = std.ArrayList(Entry).init(a.alloc);
        defer list.deinit();

        var pos: usize = 0;
        var i: u32 = 0;
        while (i < total_entries) : (i += 1) {
            if (pos + 46 > cd.len) return error.CorruptCentralDirectory;
            if (rd32(cd[pos..]) != SIG_CD) return error.CorruptCentralDirectory;

            const method = rd16(cd[pos + 10 ..]);
            const flags = rd16(cd[pos + 8 ..]);
            const crc32 = rd32(cd[pos + 16 ..]);
            var csize: u64 = rd32(cd[pos + 20 ..]);
            var usize_: u64 = rd32(cd[pos + 24 ..]);
            const name_len = rd16(cd[pos + 28 ..]);
            const extra_len = rd16(cd[pos + 30 ..]);
            const cmt_len = rd16(cd[pos + 32 ..]);
            var lhoff: u64 = rd32(cd[pos + 42 ..]);

            const name_start = pos + 46;
            const name_end = name_start + name_len;
            const extra_end = name_end + extra_len;
            if (extra_end + cmt_len > cd.len) return error.CorruptCentralDirectory;

            if (csize == 0xFFFFFFFF or usize_ == 0xFFFFFFFF or lhoff == 0xFFFFFFFF) {
                parseZip64Extra(cd[name_end..extra_end], &usize_, &csize, &lhoff);
            }

            // Name is a zero-copy slice into the central directory buffer,
            // which the archive owns for its whole lifetime.
            list.append(.{
                .name = cd[name_start..name_end],
                .method = method,
                .flags = flags,
                .crc32 = crc32,
                .compressed_size = csize,
                .uncompressed_size = usize_,
                .local_header_offset = lhoff,
                .index = i,
            }) catch return error.OutOfMemory;

            pos = extra_end + cmt_len;
        }

        a.entries = list.toOwnedSlice() catch return error.OutOfMemory;

        // Name -> index map. Grown once: no rehash churn on big archives.
        a.lookup.ensureTotalCapacity(a.alloc, @intCast(a.entries.len)) catch return error.OutOfMemory;
        for (a.entries, 0..) |e, idx| {
            const gop = a.lookup.getOrPutAssumeCapacity(e.name);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(idx);
        }
    }

    const Payload = struct {
        /// The compressed stream, zero-copy slice of `base`.
        bytes: []const u8,
        /// Owned backing allocation, freed by the caller. Null when `bytes`
        /// points into caller memory we do not own.
        base: ?[]u8,
    };

    /// Step 3, network half: one range read covering the local file header and
    /// the compressed stream. Falls back to a second read only when the local
    /// header carries a longer name/extra than we budgeted for.
    fn fetchPayload(a: *Archive, e: Entry) Error!Payload {
        if (e.compressed_size > a.total_size) return error.Truncated;
        const lhoff = e.local_header_offset;

        // Budget: 30-byte fixed header + name + generous extra slack + stream.
        const slack: u64 = 256;
        var want: u64 = 30 + e.name.len + slack + e.compressed_size;
        const avail = a.total_size - lhoff;
        if (want > avail) want = avail;

        const probe = a.alloc.alloc(u8, @intCast(want)) catch return error.OutOfMemory;
        errdefer a.alloc.free(probe);
        try a.readInto(lhoff, probe);

        const hdr = try parseLocalHeader(probe);
        const payload_off: u64 = 30 + hdr.name_len + hdr.extra_len;
        const end = payload_off + e.compressed_size;

        if (end <= probe.len) {
            // Fast path: whole stream landed in the probe. Zero extra RT.
            return .{ .bytes = probe[payload_off..][0..e.compressed_size], .base = probe };
        }

        // Rare: local name/extra longer than budget. Re-read exactly.
        if (end > a.total_size - lhoff) return error.Truncated;
        const exact = a.alloc.alloc(u8, @intCast(end)) catch return error.OutOfMemory;
        errdefer a.alloc.free(exact);
        try a.readInto(lhoff, exact);
        a.alloc.free(probe);
        return .{ .bytes = exact[payload_off..][0..e.compressed_size], .base = exact };
    }
};

const LocalHeader = struct { name_len: u32, extra_len: u32 };

fn parseLocalHeader(buf: []const u8) Error!LocalHeader {
    if (buf.len < 30) return error.CorruptLocalHeader;
    if (rd32(buf) != SIG_LFH) return error.CorruptLocalHeader;
    return .{
        .name_len = rd16(buf[26..]),
        .extra_len = rd16(buf[28..]),
    };
}

/// ZIP64 extended information (extra id 0x0001). Only the fields that were
/// 0xFFFFFFFF in the 32-bit record are present, in the spec-mandated order.
fn parseZip64Extra(extra: []const u8, usize_: *u64, csize: *u64, lhoff: *u64) void {
    var pos: usize = 0;
    while (pos + 4 <= extra.len) {
        const id = rd16(extra[pos..]);
        const sz = rd16(extra[pos + 2 ..]);
        const body = extra[pos + 4 ..];
        if (body.len < sz) return;
        if (id == 0x0001) {
            var off: usize = 0;
            if (usize_.* == 0xFFFFFFFF) {
                if (off + 8 <= sz) usize_.* = rd64(body[off..]);
                off += 8;
            }
            if (csize.* == 0xFFFFFFFF) {
                if (off + 8 <= sz) csize.* = rd64(body[off..]);
                off += 8;
            }
            if (lhoff.* == 0xFFFFFFFF) {
                if (off + 8 <= sz) lhoff.* = rd64(body[off..]);
            }
            return;
        }
        pos += 4 + sz;
    }
}

/// Locate the EOCD inside `tail`, validating candidates against the real
/// archive length so a truncated probe cannot be fooled by a signature that
/// happens to appear inside the archive comment.
fn findEocdAbs(tail: []const u8, tail_start: u64, total_size: u64) Error!usize {
    if (tail.len < 22) return error.NoEocd;
    var i: usize = tail.len - 22;
    var loose: ?usize = null;
    while (true) {
        if (rd32(tail[i..]) == SIG_EOCD) {
            const comment_len = rd16(tail[i + 20 ..]);
            const end = tail_start + i + 22 + comment_len;
            if (end == total_size) return i; // exact: unambiguous
            if (end <= total_size and loose == null) loose = i;
        }
        if (i == 0) break;
        i -= 1;
    }
    return loose orelse error.NoEocd;
}

fn inflateInto(alloc: Allocator, e: Entry, payload: []const u8, dst: []u8) Error!usize {
    switch (@as(Method, @enumFromInt(e.method))) {
        .stored => {
            if (payload.len > dst.len) return error.BufferTooSmall;
            @memcpy(dst[0..payload.len], payload);
            return payload.len;
        },
        .deflate => {
            const r = nstd.deflate.deflate.inflateEx(alloc, payload, e.uncompressed_size) catch return error.Truncated;
            defer alloc.free(r.data);
            if (r.data.len > dst.len) return error.BufferTooSmall;
            @memcpy(dst[0..r.data.len], r.data);
            return r.data.len;
        },
        .zstd => {
            const out = nstd.zstd.decompress.decompress(alloc, payload) catch return error.Truncated;
            defer alloc.free(out);
            if (out.len > dst.len) return error.BufferTooSmall;
            @memcpy(dst[0..out.len], out);
            return out.len;
        },
        else => return error.UnsupportedMethod,
    }
}
