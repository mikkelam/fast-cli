const std = @import("std");
const cli = @import("cli/root.zig");
const terminal = @import("lib/terminal.zig");

pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .warn,
    },
};

pub fn main(init: std.process.Init) !void {
    terminal.installInterruptHandler();
    try cli.run(init.gpa, init.io, init.minimal.args);
}
