//! Unit tests for the nzip core. Builds synthetic archives in memory and runs
//! them through the real range-read path.

const std = @import("std");
const testing = std.testing;
const zip = @import("zip.zig");

const MemRange = struct {
    data: []const u8,
    calls: u32 = 0,
    bytes: u64 = 0,
    /// When set, every read is capped to this many bytes; the reader must cope.
    chunk: ?usize = null,
    fail_at: ?u32 = null,

    fn cb(ctx: ?*anyopaque, offset: u64, len: usize, dst: [*]u8) callconv(.C) c_int {
        const self: *MemRange = @ptrCast(@alignCast(ctx.?));
        if (self.fail_at) |n| {
            if (self.calls == n) {
                self.calls += 1;
                return -1;
            }
        }
        if (offset + len > self.data.len) return -1;
        @memcpy(dst[0..len], self.data[offset..][0..len]);
        self.calls += 1;
        self.bytes += len;
        return 0;
    }
};

const Member = struct {
    name: []const u8,
    method: u16,
    data: []const u8, // uncompressed
    cdata: []const u8, // compressed stream (or == data for stored)
    local_extra: []const u8 = &.{},
    cd_extra: []const u8 = &.{},
    crc: u32 = 0,
};

fn put16(l: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try l.appendSlice(&b);
}
fn put32(l: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try l.appendSlice(&b);
}
fn put64(l: *std.ArrayList(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try l.appendSlice(&b);
}

/// Assemble a ZIP byte-for-byte. `zip64` forces the 0xFFFFFFFF / 0xFFFF
/// placeholders plus a real ZIP64 EOCD + locator so the upgrade path runs.
fn buildZip(alloc: std.mem.Allocator, members: []const Member, zip64: bool) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    const Off = struct { lhoff: u32, usize: u32, csize: u32 };
    var offs = try alloc.alloc(Off, members.len);
    defer alloc.free(offs);

    for (members, 0..) |m, i| {
        offs[i] = .{ .lhoff = @intCast(out.items.len), .usize = @intCast(m.data.len), .csize = @intCast(m.cdata.len) };
        try put32(&out, zip.SIG_LFH);
        try put16(&out, 20); // version needed
        try put16(&out, 0); // flags
        try put16(&out, m.method);
        try put16(&out, 0); // time
        try put16(&out, 0); // date
        try put32(&out, m.crc);
        try put32(&out, if (zip64) 0xFFFFFFFF else offs[i].csize);
        try put32(&out, if (zip64) 0xFFFFFFFF else offs[i].usize);
        try put16(&out, @intCast(m.name.len));
        try put16(&out, @intCast(m.local_extra.len));
        try out.appendSlice(m.name);
        try out.appendSlice(m.local_extra);
        try out.appendSlice(m.cdata);
    }

    const cd_off: u32 = @intCast(out.items.len);
    for (members, 0..) |m, i| {
        try put32(&out, zip.SIG_CD);
        try put16(&out, 20); // made by
        try put16(&out, 20); // needed
        try put16(&out, 0); // flags
        try put16(&out, m.method);
        try put16(&out, 0);
        try put16(&out, 0);
        try put32(&out, m.crc);
        try put32(&out, if (zip64) 0xFFFFFFFF else offs[i].csize);
        try put32(&out, if (zip64) 0xFFFFFFFF else offs[i].usize);
        try put16(&out, @intCast(m.name.len));
        try put16(&out, @intCast(m.cd_extra.len));
        try put16(&out, 0); // comment len
        try put16(&out, 0); // disk
        try put16(&out, 0); // internal attr
        try put32(&out, 0); // external attr
        try put32(&out, if (zip64) 0xFFFFFFFF else offs[i].lhoff);
        try out.appendSlice(m.name);
        try out.appendSlice(m.cd_extra);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_off);

    if (zip64) {
        const z64_off: u64 = out.items.len;
        try put32(&out, zip.SIG_Z64_EOCD);
        try put64(&out, 44); // size of record from here
        try put16(&out, 45); // made by
        try put16(&out, 45);
        try put32(&out, 0); // disk
        try put32(&out, 0); // cd disk
        try put64(&out, members.len);
        try put64(&out, members.len);
        try put64(&out, cd_size);
        try put64(&out, cd_off);

        try put32(&out, zip.SIG_Z64_LOC);
        try put32(&out, 0); // cd disk
        try put64(&out, z64_off);
        try put32(&out, 1); // total disks
    }

    try put32(&out, zip.SIG_EOCD);
    try put16(&out, 0);
    try put16(&out, 0);
    try put16(&out, if (zip64) 0xFFFF else @as(u16, @intCast(members.len)));
    try put16(&out, if (zip64) 0xFFFF else @as(u16, @intCast(members.len)));
    try put32(&out, if (zip64) 0xFFFFFFFF else cd_size);
    try put32(&out, if (zip64) 0xFFFFFFFF else cd_off);
    try put16(&out, 0); // comment len

    return out.toOwnedSlice();
}

/// ZIP64 extra field body for one entry: usize, csize, lhoff (all u64).
fn zip64Extra(alloc: std.mem.Allocator, usize_: u64, csize: u64, lhoff: u64) ![]u8 {
    var l = std.ArrayList(u8).init(alloc);
    errdefer l.deinit();
    try put16(&l, 0x0001);
    try put16(&l, 24);
    try put64(&l, usize_);
    try put64(&l, csize);
    try put64(&l, lhoff);
    return l.toOwnedSlice();
}

fn deflateData(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    return @import("nstd").deflate.deflate.deflate(alloc, raw);
}
fn zstdData(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    return @import("nstd").zstd.compress.compress(alloc, raw);
}

fn openBytes(alloc: std.mem.Allocator, bytes: []const u8) !struct { a: *zip.Archive, m: *MemRange } {
    const m = try alloc.create(MemRange);
    m.* = .{ .data = bytes };
    const a = try zip.Archive.open(alloc, MemRange.cb, m, bytes.len);
    return .{ .a = a, .m = m };
}

test "open + list + extract stored member" {
    const alloc = testing.allocator;
    const bytes = try buildZip(alloc, &.{
        .{ .name = "a.txt", .method = 0, .data = "hello nzip\n", .cdata = "hello nzip\n", .crc = 0x11111111 },
        .{ .name = "dir/b.txt", .method = 0, .data = "second", .cdata = "second" },
    }, false);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    try testing.expectEqual(@as(usize, 2), h.a.count());
    // Tail window covers the whole fixture: exactly one range call.
    try testing.expectEqual(@as(u32, 1), h.m.calls);

    const idx = h.a.find("a.txt").?;
    try testing.expectEqual(@as(u32, 0), idx);
    try testing.expectEqualStrings("a.txt", h.a.entries[idx].name);

    var buf: [64]u8 = undefined;
    const n = try h.a.extract("a.txt", &buf);
    try testing.expectEqualStrings("hello nzip\n", buf[0..n]);

    const n2 = try h.a.extract("dir/b.txt", &buf);
    try testing.expectEqualStrings("second", buf[0..n2]);

    try testing.expectError(error.EntryNotFound, h.a.extract("missing", &buf));
}

test "deflate + zstd members decode bit-exact" {
    const alloc = testing.allocator;
    const raw = try alloc.alloc(u8, 40_000);
    defer alloc.free(raw);
    for (raw, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 5));

    const def = try deflateData(alloc, raw);
    defer alloc.free(def);
    const zst = try zstdData(alloc, raw);
    defer alloc.free(zst);

    const bytes = try buildZip(alloc, &.{
        .{ .name = "big.deflate", .method = 8, .data = raw, .cdata = def },
        .{ .name = "big.zst", .method = 93, .data = raw, .cdata = zst },
    }, false);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    for ([_][]const u8{ "big.deflate", "big.zst" }) |name| {
        const out = try h.a.extractAlloc(h.a.find(name).?);
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, raw, out);
    }
}

test "ZIP64 archive: oversized sizes and offsets" {
    const alloc = testing.allocator;
    const payload = "zip64 payload payload payload";
    const extra = try zip64Extra(alloc, payload.len, payload.len, 0);
    defer alloc.free(extra);

    const bytes = try buildZip(alloc, &.{
        .{ .name = "z64.txt", .method = 0, .data = payload, .cdata = payload, .cd_extra = extra },
    }, true);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    try testing.expect(h.a.zip64);
    try testing.expectEqual(@as(usize, 1), h.a.count());
    const e = h.a.entries[0];
    try testing.expectEqual(@as(u64, payload.len), e.uncompressed_size);
    try testing.expectEqual(@as(u64, payload.len), e.compressed_size);

    var buf: [64]u8 = undefined;
    const n = try h.a.extract("z64.txt", &buf);
    try testing.expectEqualStrings(payload, buf[0..n]);
}

test "local extra longer than the budget triggers the exact re-read" {
    const alloc = testing.allocator;
    const payload = "0123456789";
    // Local extra is 400 bytes: past the 256-byte slack budget.
    var big_extra = try alloc.alloc(u8, 400);
    defer alloc.free(big_extra);
    @memset(big_extra, 0xAA);
    std.mem.writeInt(u16, big_extra[0..2], 0x9999, .little); // unknown id
    std.mem.writeInt(u16, big_extra[2..4], 396, .little);

    const bytes = try buildZip(alloc, &.{
        .{ .name = "x.bin", .method = 0, .data = payload, .cdata = payload, .local_extra = big_extra },
    }, false);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    const before = h.m.calls;
    var buf: [64]u8 = undefined;
    const n = try h.a.extract("x.bin", &buf);
    try testing.expectEqualStrings(payload, buf[0..n]);
    // Fallback path costs one extra range call but stays correct.
    try testing.expect(h.m.calls - before >= 2);
}

test "range read failure surfaces as error.RangeReadFailed" {
    const alloc = testing.allocator;
    const bytes = try buildZip(alloc, &.{
        .{ .name = "a", .method = 0, .data = "aa", .cdata = "aa" },
    }, false);
    defer alloc.free(bytes);

    const m = try alloc.create(MemRange);
    defer alloc.destroy(m);
    m.* = .{ .data = bytes, .fail_at = 0 };
    try testing.expectError(error.RangeReadFailed, zip.Archive.open(alloc, MemRange.cb, m, bytes.len));
}

test "missing EOCD is rejected" {
    const alloc = testing.allocator;
    const junk = try alloc.alloc(u8, 300);
    defer alloc.free(junk);
    @memset(junk, 0x5A);
    const m = try alloc.create(MemRange);
    defer alloc.destroy(m);
    m.* = .{ .data = junk };
    try testing.expectError(error.NoEocd, zip.Archive.open(alloc, MemRange.cb, m, junk.len));
}

test "central directory outside the tail window costs a second read" {
    const alloc = testing.allocator;
    // A CD larger than the 65557-byte tail window cannot be served from it.
    // 1200 entries x (46 header + 40 name) ~= 103 KB.
    const n: usize = 1200;
    const members = try alloc.alloc(Member, n);
    defer {
        for (members) |m| alloc.free(m.name);
        alloc.free(members);
    }
    for (members, 0..) |*m, i| {
        const name = try std.fmt.allocPrint(alloc, "dir/sub/file-{d:0>6}.dat", .{i});
        m.* = .{ .name = name, .method = 0, .data = "x", .cdata = "x" };
    }

    const bytes = try buildZip(alloc, members, false);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    try testing.expectEqual(@as(usize, n), h.a.count());
    // tail window no longer contains the CD -> 2 reads for metadata.
    try testing.expectEqual(@as(u32, 2), h.m.calls);

    var buf: [8]u8 = undefined;
    const nn = try h.a.extract("dir/sub/file-000777.dat", &buf);
    try testing.expectEqualStrings("x", buf[0..nn]);
}

test "buffer too small is rejected before any network work" {
    const alloc = testing.allocator;
    const bytes = try buildZip(alloc, &.{
        .{ .name = "big", .method = 0, .data = "0123456789", .cdata = "0123456789" },
    }, false);
    defer alloc.free(bytes);

    const h = try openBytes(alloc, bytes);
    defer h.a.deinit();
    defer alloc.destroy(h.m);

    const small = try alloc.alloc(u8, 4);
    defer alloc.free(small);
    try testing.expectError(error.BufferTooSmall, h.a.extract("big", small));
}

test "CRC verification catches a corrupted member" {
    const alloc = testing.allocator;
    const payload = "the quick brown fox";
    const good_crc = @import("nstd").core.checksum.crc32(payload, 0);

    const good = try buildZip(alloc, &.{
        .{ .name = "f", .method = 0, .data = payload, .cdata = payload, .crc = good_crc },
    }, false);
    defer alloc.free(good);
    const bad = try buildZip(alloc, &.{
        .{ .name = "f", .method = 0, .data = payload, .cdata = payload, .crc = good_crc ^ 0xFFFFFFFF },
    }, false);
    defer alloc.free(bad);

    {
        const h = try openBytes(alloc, good);
        defer h.a.deinit();
        defer alloc.destroy(h.m);
        h.a.verify_crc = true;
        var buf: [64]u8 = undefined;
        const n = try h.a.extract("f", &buf);
        try testing.expectEqual(@as(usize, payload.len), n);
    }
    {
        const h = try openBytes(alloc, bad);
        defer h.a.deinit();
        defer alloc.destroy(h.m);
        h.a.verify_crc = true;
        var buf: [64]u8 = undefined;
        try testing.expectError(error.ChecksumMismatch, h.a.extract("f", &buf));
    }
}
