const std = @import("std");
const http = std.http;
const log = std.log.scoped(.cli);

pub const HttpLatencyTester = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
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

        var latencies: std.ArrayList(f64) = .{};
        defer latencies.deinit(self.allocator);

        // HTTP client for all requests
        var client = http.Client{ .allocator = self.allocator };
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
        _ = self;

        // Parse URL
        const uri = try std.Uri.parse(url);

        // Measure request/response timing
        const start_time = std.time.nanoTimestamp();

        _ = try client.fetch(.{
            .method = .HEAD,
            .location = .{ .uri = uri },
        });

        const end_time = std.time.nanoTimestamp();

        // Convert to milliseconds
        const latency_ns = end_time - start_time;
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
    var tester = HttpLatencyTester.init(testing.allocator);
    defer tester.deinit();

    // Test with empty URLs
    const result = try tester.measureLatency(&[_][]const u8{});
    try testing.expect(result == null);
}

test "calculateMedian" {
    var tester = HttpLatencyTester.init(testing.allocator);
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

test "HttpLatencyTester integration with example.com" {
    var tester = HttpLatencyTester.init(testing.allocator);
    defer tester.deinit();

    // Test with real HTTP endpoint
    const urls = [_][]const u8{"https://example.com"};
    const result = tester.measureLatency(&urls) catch |err| {
        // Allow network errors in CI environments
        std.log.warn("Network error in integration test (expected in CI): {}", .{err});
        return;
    };

    if (result) |latency_ms| {
        // Reasonable latency bounds (1ms to 5000ms)
        try testing.expect(latency_ms >= 1.0);
        try testing.expect(latency_ms <= 5000.0);
        std.log.info("example.com latency: {d:.1}ms", .{latency_ms});
    }
}
