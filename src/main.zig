const std = @import("std");
const cli = @import("cli/root.zig");

pub const std_options: std.Options = .{
    // Set log level based on build mode
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .warn,
    },
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var root = try cli.build(allocator);
    defer root.deinit();

    try root.execute(.{});
}
