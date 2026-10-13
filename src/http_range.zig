//! HTTP Range transport for the nzip CLI.
//!
//! One persistent `std.http.Client` (connection pool + TLS session reuse) backs
//! every ranged read, so a full extract is 2-3 round trips on one warm socket.

const std = @import("std");
const nzip = @import("nzip");

pub const HttpRange = struct {
    alloc: std.mem.Allocator,
    client: std.http.Client,
    uri: std.Uri,
    url_buf: []u8,
    head_buf: [32 * 1024]u8 = undefined,
    total_size: u64 = 0,
    calls: u64 = 0,
    bytes: u64 = 0,
    net_ns: u64 = 0,
    fail: bool = false,

    pub fn init(alloc: std.mem.Allocator, url: []const u8) !*HttpRange {
        const self = try alloc.create(HttpRange);
        errdefer alloc.destroy(self);
        const url_buf = try alloc.dupe(u8, url);
        errdefer alloc.free(url_buf);
        self.* = .{
            .alloc = alloc,
            .client = .{ .allocator = alloc },
            .uri = try std.Uri.parse(url_buf),
            .url_buf = url_buf,
        };
        errdefer self.client.deinit();
        return self;
    }

    pub fn deinit(self: *HttpRange) void {
        self.client.deinit();
        self.alloc.free(self.url_buf);
        self.alloc.destroy(self);
    }

    /// Discover the archive length with `Range: bytes=0-0` and read the
    /// `Content-Range: bytes 0-0/<total>` reply. Works on servers that refuse
    /// HEAD and never pulls more than one byte of body.
    pub fn discoverSize(self: *HttpRange) !u64 {
        if (self.total_size != 0) return self.total_size;
        var req = try self.client.open(.GET, self.uri, .{
            .server_header_buffer = &self.head_buf,
            .extra_headers = &.{.{ .name = "range", .value = "bytes=0-0" }},
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        const status = req.response.status;
        if (status != .partial_content and status != .ok) return error.HttpRequestFailed;

        var total: ?u64 = null;
        var it = req.response.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-range")) {
                total = parseContentRangeTotal(h.value) orelse null;
            }
        }
        if (total == null) total = req.response.content_length;
        self.total_size = total orelse return error.SizeUnknown;

        // Drain the 1-byte body so the connection goes back to the pool.
        var scratch: [16]u8 = undefined;
        _ = try req.readAll(&scratch);
        return self.total_size;
    }

    pub fn readRange(self: *HttpRange, offset: u64, len: usize, dst: []u8) !void {
        if (len == 0) return;
        if (dst.len < len) return error.BufferTooSmall;
        if (offset + len > self.total_size) return error.RangeOutOfBounds;

        var range_val: [64]u8 = undefined;
        const range_str = try std.fmt.bufPrint(&range_val, "bytes={d}-{d}", .{ offset, offset + len - 1 });

        const t0 = std.time.nanoTimestamp();
        var req = try self.client.open(.GET, self.uri, .{
            .server_header_buffer = &self.head_buf,
            .extra_headers = &.{.{ .name = "range", .value = range_str }},
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        const status = req.response.status;
        if (status != .partial_content) {
            // Some servers ignore Range and answer 200 with the whole body.
            if (status == .ok and req.response.content_length == self.total_size) {
                return error.ServerIgnoredRange;
            }
            return error.HttpRequestFailed;
        }

        const n = try req.readAll(dst[0..len]);
        self.net_ns +%= @intCast(@max(0, std.time.nanoTimestamp() - t0));
        self.calls += 1;
        self.bytes += n;
        if (n != len) return error.ShortRead;
    }

    /// trampoline matching nzip.RangeFn
    pub fn cRead(ctx: ?*anyopaque, offset: u64, len: usize, dst: [*]u8) callconv(.C) c_int {
        const self: *HttpRange = @ptrCast(@alignCast(ctx orelse return -1));
        self.readRange(offset, len, dst[0..len]) catch {
            self.fail = true;
            return -1;
        };
        return 0;
    }
};

/// "bytes 0-0/123456789" -> 123456789
fn parseContentRangeTotal(v: []const u8) ?u64 {
    const slash = std.mem.lastIndexOfScalar(u8, v, '/') orelse return null;
    const tail = std.mem.trim(u8, v[slash + 1 ..], " \t");
    if (std.mem.eql(u8, tail, "*")) return null;
    return std.fmt.parseInt(u64, tail, 10) catch null;
}
