//! C ABI surface for nzip. Mirrors include/nzip.h.

const std = @import("std");
const zip = @import("zip.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

pub const nzip_archive_t = zip.Archive;
pub const nzip_range_read_cb = zip.RangeFn;

pub const nzip_entry_info_t = extern struct {
    uncompressed_size: u64,
    compressed_size: u64,
    local_header_offset: u64,
    method: u16,
    flags: u16,
    crc32: u32,
    index: u32,
};

/// Error codes returned by the int-returning entry points.
pub const NZIP_OK: c_int = 0;
pub const NZIP_ERR_NOT_FOUND: c_int = -1;
pub const NZIP_ERR_BUFFER: c_int = -2;
pub const NZIP_ERR_IO: c_int = -3;
pub const NZIP_ERR_FORMAT: c_int = -4;
pub const NZIP_ERR_METHOD: c_int = -5;
pub const NZIP_ERR_ARG: c_int = -6;

export fn nzip_version() [*:0]const u8 {
    return "nzip 0.1.0";
}

/// Open a remote archive by reading only its Central Directory metadata.
/// `total_archive_size` is the archive's byte length as reported by the server.
export fn nzip_open_remote(
    read_cb: ?nzip_range_read_cb,
    user_ctx: ?*anyopaque,
    total_archive_size: u64,
) ?*nzip_archive_t {
    const cb = read_cb orelse return null;
    return zip.Archive.open(alloc, cb, user_ctx, total_archive_size) catch null;
}

/// Find an entry by exact relative path.
/// Writes the uncompressed size to `out_uncompressed_size` when non-null.
/// Returns the entry index (>= 0) or a negative NZIP_ERR_* code.
export fn nzip_find_entry(
    z: ?*nzip_archive_t,
    filename: ?[*:0]const u8,
    out_uncompressed_size: ?*u64,
) c_int {
    const a = z orelse return NZIP_ERR_ARG;
    const name_z = filename orelse return NZIP_ERR_ARG;
    const name = std.mem.span(name_z);
    const idx = a.find(name) orelse return NZIP_ERR_NOT_FOUND;
    if (out_uncompressed_size) |p| p.* = a.entries[idx].uncompressed_size;
    return @intCast(idx);
}

/// Extract an entry by name into caller-provided memory.
export fn nzip_extract_entry(
    z: ?*nzip_archive_t,
    filename: ?[*:0]const u8,
    dst: ?[*]u8,
    dst_len: usize,
) c_int {
    const a = z orelse return NZIP_ERR_ARG;
    const name_z = filename orelse return NZIP_ERR_ARG;
    const out = dst orelse return NZIP_ERR_ARG;
    const n = a.extract(std.mem.span(name_z), out[0..dst_len]) catch |e| return errCode(e);
    return @intCast(n);
}

/// Extract by index (from nzip_find_entry / nzip_entry_at).
export fn nzip_extract_entry_at(
    z: ?*nzip_archive_t,
    index: c_int,
    dst: ?[*]u8,
    dst_len: usize,
) c_int {
    const a = z orelse return NZIP_ERR_ARG;
    if (index < 0) return NZIP_ERR_ARG;
    const out = dst orelse return NZIP_ERR_ARG;
    const n = a.extractAt(@intCast(index), out[0..dst_len]) catch |e| return errCode(e);
    return @intCast(n);
}

/// Allocate and fill a buffer with the entry's bytes. `out_len` receives the
/// byte length. Free with nzip_free(ptr, out_len).
export fn nzip_extract_entry_alloc(z: ?*nzip_archive_t, index: c_int, out_len: ?*u64) ?[*]u8 {
    const a = z orelse return null;
    if (index < 0) return null;
    const buf = a.extractAlloc(@intCast(index)) catch return null;
    if (out_len) |p| p.* = buf.len;
    return buf.ptr;
}

export fn nzip_entry_count(z: ?*nzip_archive_t) c_int {
    const a = z orelse return 0;
    return @intCast(a.entries.len);
}

/// Fill `info` and (optionally) copy the entry name into `name_out`.
/// Returns 0 on success or a negative NZIP_ERR_* code.
export fn nzip_entry_at(
    z: ?*nzip_archive_t,
    index: c_int,
    name_out: ?[*]u8,
    name_cap: usize,
    info: ?*nzip_entry_info_t,
) c_int {
    const a = z orelse return NZIP_ERR_ARG;
    if (index < 0 or index >= a.entries.len) return NZIP_ERR_NOT_FOUND;
    const e = a.entries[@intCast(index)];
    if (info) |p| {
        p.* = .{
            .uncompressed_size = e.uncompressed_size,
            .compressed_size = e.compressed_size,
            .local_header_offset = e.local_header_offset,
            .method = e.method,
            .flags = e.flags,
            .crc32 = e.crc32,
            .index = e.index,
        };
    }
    if (name_out) |p| {
        if (name_cap == 0) return NZIP_ERR_BUFFER;
        const n = @min(e.name.len, name_cap - 1);
        @memcpy(p[0..n], e.name[0..n]);
        p[n] = 0;
    }
    return 0;
}

export fn nzip_fetched_bytes(z: ?*nzip_archive_t) u64 {
    const a = z orelse return 0;
    return a.stats.fetched_bytes;
}

/// Enable or disable CRC-32 verification of decompressed output.
export fn nzip_set_verify_crc(z: ?*nzip_archive_t, enable: c_int) void {
    const a = z orelse return;
    a.verify_crc = enable != 0;
}

export fn nzip_range_calls(z: ?*nzip_archive_t) u32 {
    const a = z orelse return 0;
    return @intCast(a.stats.range_calls);
}

export fn nzip_total_size(z: ?*nzip_archive_t) u64 {
    const a = z orelse return 0;
    return a.total_size;
}

export fn nzip_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    alloc.free(p[0..len]);
}

export fn nzip_close(z: ?*nzip_archive_t) void {
    const a = z orelse return;
    a.deinit();
}

fn errCode(e: zip.Error) c_int {
    return switch (e) {
        error.EntryNotFound => NZIP_ERR_NOT_FOUND,
        error.BufferTooSmall => NZIP_ERR_BUFFER,
        error.RangeReadFailed => NZIP_ERR_IO,
        error.Truncated, error.NotAZip, error.NoEocd, error.CorruptCentralDirectory, error.CorruptLocalHeader => NZIP_ERR_FORMAT,
        error.UnsupportedMethod => NZIP_ERR_METHOD,
        error.ChecksumMismatch => NZIP_ERR_FORMAT,
        error.OutOfMemory => NZIP_ERR_IO,
    };
}
