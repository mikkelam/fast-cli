const builtin = @import("builtin");
const std = @import("std");

const RESET_ATTRIBUTES = "\x1b[0m"; // ECMA-48 SGR 0
const SHOW_CURSOR = "\x1b[?25h"; // DEC DECTCEM set
pub const RESTORE_TERMINAL = RESET_ATTRIBUTES ++ SHOW_CURSOR;

pub fn installInterruptHandler() void {
    if (builtin.os.tag == .windows) return;

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn handleInterrupt(signal: std.posix.SIG) callconv(.c) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, RESTORE_TERMINAL.ptr, RESTORE_TERMINAL.len);

    const status: u8 = @intCast(128 + @intFromEnum(signal));
    if (builtin.link_libc) std.c._exit(status);
    std.posix.system.exit(status);
}
