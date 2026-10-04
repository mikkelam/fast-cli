const std = @import("std");
const http = std.http;
const log = std.log.scoped(.cli);

pub const HttpLatencyTester = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Measure latency to multiple URLs using HEAD requests
    /// Returns median latency in milliseconds, or null if all requests failed
    /// Zig's http client seems to be ~20ms slower than curl.
    /// Let's not worry about that misreporting for now
    pub fn measureLatency(self: *Self, urls: []const []const u8) !?f64 {
        if (urls.len == 0) return null;

        var latencies: std.ArrayList(f64) = .empty;
        defer latencies.deinit(self.allocator);

        // HTTP client for all requests
        var client = http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        // Test each URL
        for (urls) |url| {
            if (self.measureSingleUrl(url, &client)) |latency_ms| {
                try latencies.append(self.allocator, latency_ms);
            } else |_| {
                // Ignore errors, continue with other URLs
                continue;
            }
        }

        if (latencies.items.len == 0) return null;

        log.info("Latencies: {any}", .{latencies.items});

        // Return median latency
        return self.calculateMedian(latencies.items);
    }

    /// Measure latency to a single URL using HEAD request
    fn measureSingleUrl(self: *Self, url: []const u8, client: *http.Client) !f64 {
        const uri = try std.Uri.parse(url);
        var redirect_buffer: [1024]u8 = undefined;
        var req = try client.request(.HEAD, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        // Measure request/response timing
        const start_time = std.Io.Timestamp.now(self.io, .awake);
        try req.sendBodiless();
        _ = try req.receiveHead(&redirect_buffer);

        const end_time = std.Io.Timestamp.now(self.io, .awake);

        // Convert to milliseconds
        const latency_ns = start_time.durationTo(end_time).toNanoseconds();
        const latency_ms = @as(f64, @floatFromInt(latency_ns)) / std.time.ns_per_ms;

        return latency_ms;
    }

    /// Calculate median from array of latencies
    fn calculateMedian(self: *Self, latencies: []f64) f64 {
        _ = self;

        if (latencies.len == 0) return 0;
        if (latencies.len == 1) return latencies[0];

        // Sort latencies
        std.mem.sort(f64, latencies, {}, std.sort.asc(f64));

        const mid = latencies.len / 2;
        if (latencies.len % 2 == 0) {
            // Even number of elements - average of two middle values
            return (latencies[mid - 1] + latencies[mid]) / 2.0;
        } else {
            // Odd number of elements - middle value
            return latencies[mid];
        }
    }
};

const testing = std.testing;

test "HttpLatencyTester init/deinit" {
    var tester = HttpLatencyTester.init(testing.allocator, testing.io);
    defer tester.deinit();

    // Test with empty URLs
    const result = try tester.measureLatency(&[_][]const u8{});
    try testing.expect(result == null);
}

test "calculateMedian" {
    var tester = HttpLatencyTester.init(testing.allocator, testing.io);
    defer tester.deinit();

    // Test odd number of elements
    var latencies_odd = [_]f64{ 10.0, 20.0, 30.0 };
    const median_odd = tester.calculateMedian(&latencies_odd);
    try testing.expectEqual(@as(f64, 20.0), median_odd);

    // Test even number of elements
    var latencies_even = [_]f64{ 10.0, 20.0, 30.0, 40.0 };
    const median_even = tester.calculateMedian(&latencies_even);
    try testing.expectEqual(@as(f64, 25.0), median_even);

    // Test single element
    var latencies_single = [_]f64{15.0};
    const median_single = tester.calculateMedian(&latencies_single);
    try testing.expectEqual(@as(f64, 15.0), median_single);
}

test "HttpLatencyTester integration with local HTTP server" {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);

    const server_thread = try std.Thread.spawn(.{}, serveSingleHeadRequest, .{ &server, testing.io });
    defer server_thread.join();

    const port = server.socket.address.getPort();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/latency", .{port});

    var tester = HttpLatencyTester.init(testing.allocator, testing.io);
    defer tester.deinit();

    const urls = [_][]const u8{url};
    const result = try tester.measureLatency(&urls);

    if (result) |latency_ms| {
        try testing.expect(latency_ms >= 0.0);
        // Loopback should be very fast; keep bound generous for loaded CI runners.
        try testing.expect(latency_ms <= 1000.0);
    } else {
        return error.TestUnexpectedResult;
    }
}

fn serveSingleHeadRequest(server: *std.Io.net.Server, io: std.Io) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    _ = reader.interface.takeDelimiterInclusive('\n') catch return;

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 0\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch return;
}
