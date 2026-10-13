//! nzip — zero-copy, range-aware remote ZIP reader.
//!
//! Read a single member out of a multi-hundred-megabyte archive over HTTP Range
//! requests without ever downloading the archive.

const std = @import("std");

pub const zip = @import("zip.zig");
pub const Archive = zip.Archive;
pub const Entry = zip.Entry;
pub const Method = zip.Method;
pub const Stats = zip.Stats;
pub const RangeFn = zip.RangeFn;

comptime {
    _ = @import("c_abi.zig");
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("zip.zig");
    _ = @import("c_abi.zig");
    _ = @import("zip_test.zig");
}
