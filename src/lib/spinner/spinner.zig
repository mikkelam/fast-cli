const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const Spinner = @This();

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const Options = struct {
    refresh_rate_ms: u64 = 80,
};

// ANSI escape codes
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";
const CLEAR_LINE = "\r\x1b[K";
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const RESET = "\x1b[0m";

allocator: Allocator,
message: []u8,
stderr_buffer: [4096]u8 = undefined,
thread: ?Thread = null,
mutex: Thread.Mutex = .{},
should_stop: std.atomic.Value(bool),
refresh_rate_ms: u64,

pub fn init(allocator: Allocator) Spinner {
    return initWithOptions(allocator, .{});
}

pub fn initWithOptions(allocator: Allocator, options: Options) Spinner {
    return .{
        .allocator = allocator,
        .message = &.{},
        .should_stop = std.atomic.Value(bool).init(true),
        .refresh_rate_ms = options.refresh_rate_ms,
    };
}

pub fn deinit(self: *Spinner) void {
    self.stop();
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.message.len > 0) {
        self.allocator.free(self.message);
        self.message = &.{};
    }
}

pub fn start(self: *Spinner, comptime fmt: []const u8, args: anytype) !void {
    self.stop();

    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.message.len > 0) {
        self.allocator.free(self.message);
    }
    self.message = try std.fmt.allocPrint(self.allocator, fmt, args);

    // Hide cursor
    var stderr_writer = std.fs.File.stderr().writerStreaming(&self.stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(HIDE_CURSOR) catch {};

    self.should_stop.store(false, .release);
    self.thread = try Thread.spawn(.{}, spinLoop, .{self});
}

pub fn stop(self: *Spinner) void {
    if (self.should_stop.load(.acquire)) return;

    self.should_stop.store(true, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    // Clear the line and show cursor
    var stderr_writer = std.fs.File.stderr().writerStreaming(&self.stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(CLEAR_LINE ++ SHOW_CURSOR) catch {};
    stderr.flush() catch {};
}

pub fn updateMessage(self: *Spinner, comptime fmt: []const u8, args: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.message.len > 0) {
        self.allocator.free(self.message);
    }
    self.message = try std.fmt.allocPrint(self.allocator, fmt, args);
}

pub fn succeed(self: *Spinner, comptime fmt: []const u8, args: anytype) !void {
    self.stop();

    self.mutex.lock();
    const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(msg);
    self.mutex.unlock();

    var stderr_writer = std.fs.File.stderr().writerStreaming(&self.stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(SHOW_CURSOR) catch {};
    try stderr.print(GREEN ++ "✔" ++ RESET ++ " {s}\n", .{msg});
    try stderr.flush();
}

pub fn fail(self: *Spinner, comptime fmt: []const u8, args: anytype) !void {
    self.stop();

    self.mutex.lock();
    const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(msg);
    self.mutex.unlock();

    var stderr_writer = std.fs.File.stderr().writerStreaming(&self.stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(SHOW_CURSOR) catch {};
    try stderr.print(RED ++ "✖" ++ RESET ++ " {s}\n", .{msg});
    try stderr.flush();
}

fn spinLoop(self: *Spinner) void {
    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    var frame_idx: usize = 0;

    while (!self.should_stop.load(.acquire)) {
        self.mutex.lock();
        const msg = self.message;
        stderr.print(CLEAR_LINE ++ "{s} {s}", .{ frames[frame_idx], msg }) catch {};
        stderr.flush() catch {};
        self.mutex.unlock();

        frame_idx = (frame_idx + 1) % frames.len;
        Thread.sleep(self.refresh_rate_ms * std.time.ns_per_ms);
    }
}

test "spinner init and deinit" {
    const testing = std.testing;
    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    try testing.expect(spinner.message.len == 0);
    try testing.expect(spinner.thread == null);
}

test "spinner start and stop" {
    const testing = std.testing;

    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    try spinner.start("Testing {s}", .{"spinner"});
    try testing.expect(!spinner.should_stop.load(.acquire));
    try testing.expect(spinner.thread != null);

    Thread.sleep(50 * std.time.ns_per_ms);

    spinner.stop();
    try testing.expect(spinner.should_stop.load(.acquire));
    try testing.expect(spinner.thread == null);
}

test "spinner updateMessage" {
    const testing = std.testing;

    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    try spinner.start("Initial", .{});
    Thread.sleep(20 * std.time.ns_per_ms);

    try spinner.updateMessage("Updated {d}", .{42});
    Thread.sleep(20 * std.time.ns_per_ms);

    spinner.stop();
}

test "spinner multiple start/stop cycles" {
    const testing = std.testing;

    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    for (0..3) |i| {
        try spinner.start("Cycle {d}", .{i});
        Thread.sleep(20 * std.time.ns_per_ms);
        spinner.stop();
    }
}

test "spinner succeed" {
    const testing = std.testing;

    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    try spinner.start("Processing...", .{});
    Thread.sleep(20 * std.time.ns_per_ms);
    try spinner.succeed("Test completed", .{});
}

test "spinner fail" {
    const testing = std.testing;

    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    try spinner.start("Processing...", .{});
    Thread.sleep(20 * std.time.ns_per_ms);
    try spinner.fail("Test error", .{});
}

test "spinner stop without start is safe" {
    const testing = std.testing;
    var spinner = Spinner.init(testing.allocator);
    defer spinner.deinit();

    spinner.stop();
    spinner.stop();
}
