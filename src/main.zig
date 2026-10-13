//! nzip CLI — list, stat and extract remote ZIP members over HTTP Range.

const std = @import("std");
const nzip = @import("nzip");
const http_range = @import("http_range.zig");

const usage =
    \\nzip — zero-copy, range-aware remote ZIP reader
    \\
    \\usage:
    \\  nzip ls   <url>                       list archive entries
    \\  nzip stat <url> [name]                archive or entry metadata
    \\  nzip get  <url> <name> [-o FILE] [--crc]   extract one member
    \\  nzip find <url> <substring>           filter entries by name
    \\  nzip bench <url> <name> [-n N] [--crc]     timing + bandwidth breakdown
    \\
    \\options:
    \\  -o FILE   write to FILE instead of stdout
    \\  --crc     verify the CRC-32 from the central directory
    \\  -n N      iterations for bench
    \\
    \\examples:
    \\  nzip ls  https://cdn.tse.jus.br/.../votacao_candidato_munzona_2022.zip
    \\  nzip get https://cdn.tse.jus.br/.../votacao_candidato_munzona_2022.zip _BR.csv -o br.csv --crc
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(2);
    };
    const url = args.next() orelse {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(2);
    };

    if (std.mem.eql(u8, cmd, "ls")) return cmdList(alloc, url, null);
    if (std.mem.eql(u8, cmd, "find")) {
        const pat = args.next() orelse return fail("find needs a substring");
        return cmdList(alloc, url, pat);
    }
    if (std.mem.eql(u8, cmd, "stat")) return cmdStat(alloc, url, args.next());
    if (std.mem.eql(u8, cmd, "get")) {
        const name = args.next() orelse return fail("get needs an entry name");
        return cmdGet(alloc, url, name, try parseOpts(&args));
    }
    if (std.mem.eql(u8, cmd, "bench")) {
        const name = args.next() orelse return fail("bench needs an entry name");
        return cmdBench(alloc, url, name, try parseOpts(&args));
    }
    try std.io.getStdErr().writeAll(usage);
    std.process.exit(2);
}

const Opts = struct {
    out: ?[]const u8 = null,
    crc: bool = false,
    iters: usize = 1,
};

fn parseOpts(args: *std.process.ArgIterator) !Opts {
    var o: Opts = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            o.out = args.next() orelse return fail("-o needs a path");
        } else if (std.mem.eql(u8, a, "--crc")) {
            o.crc = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            const v = args.next() orelse return fail("-n needs a count");
            o.iters = try std.fmt.parseInt(usize, v, 10);
        } else {
            return fail("unknown option");
        }
    }
    return o;
}

fn fail(msg: []const u8) error{CliUsage} {
    std.io.getStdErr().writer().print("error: {s}\n", .{msg}) catch {};
    return error.CliUsage;
}

const Opened = struct {
    hr: *http_range.HttpRange,
    ar: *nzip.Archive,

    fn close(self: Opened) void {
        self.ar.deinit();
        self.hr.deinit();
    }
};

fn openArchive(alloc: std.mem.Allocator, url: []const u8) !Opened {
    const hr = try http_range.HttpRange.init(alloc, url);
    errdefer hr.deinit();
    const total = try hr.discoverSize();
    const ar = try nzip.Archive.open(alloc, http_range.HttpRange.cRead, hr, total);
    return .{ .hr = hr, .ar = ar };
}

fn cmdList(alloc: std.mem.Allocator, url: []const u8, filter: ?[]const u8) !void {
    const o = try openArchive(alloc, url);
    defer o.close();
    const out = std.io.getStdOut().writer();

    var shown: usize = 0;
    for (o.ar.entries) |e| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, e.name, f) == null) continue;
        }
        try out.print("{d:>12} {d:>12} {s:<8} {s}\n", .{
            e.uncompressed_size,
            e.compressed_size,
            e.methodName(),
            e.name,
        });
        shown += 1;
    }
    try out.print("\n{d} entries ({d} shown) / archive {d} bytes / fetched {d} bytes in {d} range calls\n", .{
        o.ar.count(),
        shown,
        o.ar.total_size,
        o.ar.stats.fetched_bytes,
        o.ar.stats.range_calls,
    });
}

fn cmdStat(alloc: std.mem.Allocator, url: []const u8, name: ?[]const u8) !void {
    const o = try openArchive(alloc, url);
    defer o.close();
    const out = std.io.getStdOut().writer();

    if (name) |n| {
        const idx = o.ar.find(n) orelse return fail("entry not found");
        const e = o.ar.entryAt(idx).?;
        try out.print("name        {s}\n", .{e.name});
        try out.print("method      {s} ({d})\n", .{ e.methodName(), e.method });
        try out.print("flags       0x{x:0>4}\n", .{e.flags});
        try out.print("crc32       0x{x:0>8}\n", .{e.crc32});
        try out.print("compressed  {d}\n", .{e.compressed_size});
        try out.print("uncompressed {d}\n", .{e.uncompressed_size});
        try out.print("local offset {d}\n", .{e.local_header_offset});
        if (e.compressed_size > 0) {
            try out.print("ratio       {d:.2}x\n", .{@as(f64, @floatFromInt(e.uncompressed_size)) / @as(f64, @floatFromInt(e.compressed_size))});
        }
        return;
    }

    try out.print("archive     {s}\n", .{url});
    try out.print("size        {d} bytes\n", .{o.ar.total_size});
    try out.print("entries     {d}\n", .{o.ar.count()});
    try out.print("zip64       {}\n", .{o.ar.zip64});
    try out.print("cd offset   {d}\n", .{o.ar.cd_offset});
    try out.print("cd size     {d}\n", .{o.ar.cd_size});
    try out.print("eocd offset {d}\n", .{o.ar.eocd_offset});
    try out.print("metadata    {d} bytes in {d} range calls\n", .{
        o.ar.stats.fetched_bytes,
        o.ar.stats.range_calls,
    });
}

fn cmdGet(alloc: std.mem.Allocator, url: []const u8, name: []const u8, opts: Opts) !void {
    const t0 = std.time.nanoTimestamp();
    const o = try openArchive(alloc, url);
    defer o.close();

    o.ar.verify_crc = opts.crc;
    const idx = o.ar.find(name) orelse return fail("entry not found");
    const e = o.ar.entryAt(idx).?;

    const buf = try o.ar.extractAlloc(idx);
    defer alloc.free(buf);

    if (opts.out) |p| {
        const f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll(buf);
    } else {
        try std.io.getStdOut().writeAll(buf);
    }

    const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t0));
    const stderr = std.io.getStdErr().writer();
    try stderr.print("\n[s] {s}: {d} -> {d} bytes via {s}; fetched {d} bytes in {d} range calls; {d} ms\n", .{
        e.name,
        e.compressed_size,
        buf.len,
        e.methodName(),
        o.ar.stats.fetched_bytes,
        o.ar.stats.range_calls,
        dt / 1_000_000,
    });
}

fn cmdBench(alloc: std.mem.Allocator, url: []const u8, name: []const u8, opts: Opts) !void {
    const out = std.io.getStdOut().writer();

    const o = try openArchive(alloc, url);
    o.ar.verify_crc = opts.crc;
    const iters = opts.iters;
    const archive_size = o.ar.total_size;
    const meta_bytes = o.ar.stats.fetched_bytes;
    const meta_calls = o.ar.stats.range_calls;

    const idx = o.ar.find(name) orelse {
        o.close();
        return fail("entry not found");
    };
    const e = o.ar.entryAt(idx).?;

    var best: u128 = std.math.maxInt(u128);
    var total: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        const buf = try o.ar.extractAlloc(idx);
        const dt: u128 = @intCast(@max(0, std.time.nanoTimestamp() - t0));
        alloc.free(buf);
        best = @min(best, dt);
        total += dt;
    }
    const extract_bytes = o.ar.stats.fetched_bytes - meta_bytes;
    const extract_calls = o.ar.stats.range_calls - meta_calls;
    o.close();

    // What a naive full download would have cost, per extract.
    const naive: u64 = archive_size;
    const per_extract: u64 = extract_bytes / @max(1, iters);
    const lean: u64 = meta_bytes + per_extract;

    try out.print("archive       {d} bytes\n", .{archive_size});
    try out.print("target        {s}\n", .{name});
    try out.print("compressed    {d} bytes ({s})\n", .{ e.compressed_size, e.methodName() });
    try out.print("uncompressed  {d} bytes\n", .{e.uncompressed_size});
    try out.print("metadata      {d} bytes / {d} range calls (once)\n", .{ meta_bytes, meta_calls });
    try out.print("payload       {d} bytes / {d} range calls per extract ({d} total over {d} runs)\n", .{
        per_extract,
        extract_calls / @max(1, iters),
        extract_bytes,
        iters,
    });
    try out.print("iterations    {d}  best {d} ms  mean {d} ms\n", .{
        iters,
        best / 1_000_000,
        (total / iters) / 1_000_000,
    });
    const factor = @as(f64, @floatFromInt(naive)) / @as(f64, @floatFromInt(@max(1, lean)));
    try out.print("bandwidth     {d} bytes instead of {d} bytes -> {d:.1}x less per extract\n", .{ lean, naive, factor });
}
