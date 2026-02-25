const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const Spinner = @This();

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const WriterType = union(enum) {
    file: std.fs.File.Writer,
    test_writer: std.Io.Writer,
};

pub const Options = struct {
    refresh_rate_ms: u64 = 80,
    writer: ?WriterType = null,
};

// ANSI escape codes
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";
const CLEAR_LINE = "\r\x1b[K";
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const RESET = "\x1b[0m";

allocator: Allocator,
message: []u8 = &.{},
writer_buffer: [4096]u8,
writer: WriterType,
thread: ?Thread = null,
mutex: Thread.Mutex = .{},
should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
refresh_rate_ms: u64,

pub fn init(allocator: Allocator, options: Options) Spinner {
    var spinner: Spinner = undefined;
    spinner.allocator = allocator;
    spinner.refresh_rate_ms = options.refresh_rate_ms;
    spinner.message = &.{};
    spinner.thread = null;
    spinner.mutex = .{};
    spinner.should_stop = std.atomic.Value(bool).init(true);

    if (options.writer) |w| {
        spinner.writer_buffer = undefined;
        spinner.writer = w;
    } else {
        spinner.writer = .{ .file = std.fs.File.stderr().writer(&spinner.writer_buffer) };
    }

    return spinner;
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

    switch (self.writer) {
        .file => |*w| {
            w.interface.writeAll(HIDE_CURSOR) catch {};
            w.interface.flush() catch {};
        },
        .test_writer => |*w| {
            w.writeAll(HIDE_CURSOR) catch {};
        },
    }

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

    switch (self.writer) {
        .file => |*w| {
            w.interface.writeAll(CLEAR_LINE ++ SHOW_CURSOR) catch {};
            w.interface.flush() catch {};
        },
        .test_writer => |*w| {
            w.writeAll(CLEAR_LINE ++ SHOW_CURSOR) catch {};
        },
    }
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

    switch (self.writer) {
        .file => |*w| {
            w.interface.writeAll(SHOW_CURSOR) catch {};
            try w.interface.print(GREEN ++ "✔" ++ RESET ++ " {s}\n", .{msg});
            try w.interface.flush();
        },
        .test_writer => |*w| {
            w.writeAll(SHOW_CURSOR) catch {};
            try w.print(GREEN ++ "✔" ++ RESET ++ " {s}\n", .{msg});
        },
    }
}

pub fn fail(self: *Spinner, comptime fmt: []const u8, args: anytype) !void {
    self.stop();

    self.mutex.lock();
    const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(msg);
    self.mutex.unlock();

    switch (self.writer) {
        .file => |*w| {
            w.interface.writeAll(SHOW_CURSOR) catch {};
            try w.interface.print(RED ++ "✖" ++ RESET ++ " {s}\n", .{msg});
            try w.interface.flush();
        },
        .test_writer => |*w| {
            w.writeAll(SHOW_CURSOR) catch {};
            try w.print(RED ++ "✖" ++ RESET ++ " {s}\n", .{msg});
        },
    }
}

fn spinLoop(self: *Spinner) void {
    var frame_idx: usize = 0;

    while (!self.should_stop.load(.acquire)) {
        self.mutex.lock();
        const msg = self.message;
        switch (self.writer) {
            .file => |*w| {
                w.interface.print(CLEAR_LINE ++ "{s} {s}", .{ frames[frame_idx], msg }) catch {};
                w.interface.flush() catch {};
            },
            .test_writer => |*w| {
                w.print(CLEAR_LINE ++ "{s} {s}", .{ frames[frame_idx], msg }) catch {};
            },
        }
        self.mutex.unlock();

        frame_idx = (frame_idx + 1) % frames.len;
        Thread.sleep(self.refresh_rate_ms * std.time.ns_per_ms);
    }
}

test "spinner outputs hide cursor on start" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer } });
    defer spinner.deinit();

    try spinner.start("Processing", .{});
    Thread.sleep(50 * std.time.ns_per_ms);
    spinner.stop();

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, HIDE_CURSOR) != null);
}

test "spinner outputs show cursor on stop" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer } });
    defer spinner.deinit();

    try spinner.start("Loading", .{});
    Thread.sleep(50 * std.time.ns_per_ms);
    spinner.stop();

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, SHOW_CURSOR) != null);
}

test "spinner outputs message and frames" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer }, .refresh_rate_ms = 30 });
    defer spinner.deinit();

    try spinner.start("Loading {s}", .{"data"});
    Thread.sleep(150 * std.time.ns_per_ms);
    spinner.stop();

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, "Loading data") != null);
    try testing.expect(std.mem.indexOf(u8, output, CLEAR_LINE) != null);
}

test "spinner succeed outputs green checkmark" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer } });
    defer spinner.deinit();

    try spinner.start("Working", .{});
    Thread.sleep(50 * std.time.ns_per_ms);
    try spinner.succeed("Done", .{});

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, "✔") != null);
    try testing.expect(std.mem.indexOf(u8, output, GREEN) != null);
    try testing.expect(std.mem.indexOf(u8, output, "Done") != null);
}

test "spinner fail outputs red cross" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer } });
    defer spinner.deinit();

    try spinner.start("Working", .{});
    Thread.sleep(50 * std.time.ns_per_ms);
    try spinner.fail("Error occurred", .{});

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, "✖") != null);
    try testing.expect(std.mem.indexOf(u8, output, RED) != null);
    try testing.expect(std.mem.indexOf(u8, output, "Error occurred") != null);
}

test "spinner updateMessage changes displayed text" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer }, .refresh_rate_ms = 30 });
    defer spinner.deinit();

    try spinner.start("Step 1", .{});
    Thread.sleep(100 * std.time.ns_per_ms);
    try spinner.updateMessage("Step 2", .{});
    Thread.sleep(100 * std.time.ns_per_ms);
    spinner.stop();

    const output = getTestOutput(&spinner);
    try testing.expect(std.mem.indexOf(u8, output, "Step 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Step 2") != null);
}

test "spinner can stop without starting" {
    const testing = std.testing;
    var spinner = Spinner.init(testing.allocator, .{});
    defer spinner.deinit();

    spinner.stop();
    try testing.expect(spinner.should_stop.load(.acquire));
}

test "spinner multiple start/stop cycles work" {
    const testing = std.testing;

    var buffer: [4096]u8 = undefined;
    const test_writer = std.Io.Writer.fixed(&buffer);

    var spinner = Spinner.init(testing.allocator, .{ .writer = .{ .test_writer = test_writer } });
    defer spinner.deinit();

    for (0..3) |i| {
        try spinner.start("Cycle {d}", .{i});
        Thread.sleep(50 * std.time.ns_per_ms);
        spinner.stop();
    }

    try testing.expect(spinner.thread == null);
}

fn getTestOutput(spinner: *Spinner) []const u8 {
    return switch (spinner.writer) {
        .test_writer => |*w| w.buffer[0..w.end],
        else => &.{},
    };
}
