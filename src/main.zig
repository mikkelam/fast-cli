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

    const file = std.fs.File.stdout();
    var writer = file.writerStreaming(&.{}).interface;

    const root = try cli.build(&writer, allocator);
    defer root.deinit();

    try root.execute(.{});
}
