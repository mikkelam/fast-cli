const std = @import("std");
const assert = @import("std").debug.assert;

pub const SpeedUnit = enum {
    bps,
    kbps,
    mbps,
    gbps,

    pub fn toString(self: SpeedUnit) []const u8 {
        return switch (self) {
            .bps => "bps",
            .kbps => "Kbps",
            .mbps => "Mbps",
            .gbps => "Gbps",
        };
    }
};

pub const SpeedMeasurement = struct {
    value: f64,
    unit: SpeedUnit,

    pub fn format(self: SpeedMeasurement, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ self.value, self.unit.toString() });
    }
};

pub const BandwidthMeter = struct {
    bytes_transferred: u64 = 0,
    timer: std.time.Timer = undefined,
    started: bool = false,

    pub fn init() BandwidthMeter {
        return .{};
    }

    pub fn start(self: *BandwidthMeter) !void {
        self.timer = try std.time.Timer.start();
        self.started = true;
    }

    pub fn record_bytes(self: *BandwidthMeter, byte_count: usize) void {
        assert(self.started);
        self.bytes_transferred += byte_count;
    }

    pub fn record_data(self: *BandwidthMeter, data: []const u8) usize {
        assert(self.started);
        const n = data.len;
        self.bytes_transferred += n;
        return n;
    }

    pub fn bandwidth(self: *BandwidthMeter) f64 {
        if (!self.started) return 0;

        const delta_nanos = self.timer.read();
        const delta_secs = @as(f64, @floatFromInt(delta_nanos)) / std.time.ns_per_s;

        return @as(f64, @floatFromInt(self.bytes_transferred)) / delta_secs;
    }

    /// Get the total bytes transferred (uploaded or downloaded)
    pub fn bytesTransferred(self: *const BandwidthMeter) u64 {
        return self.bytes_transferred;
    }

    /// Get the duration since start in nanoseconds
    pub fn duration(self: *BandwidthMeter) !u64 {
        if (!self.started) return error.NotStarted;
        return self.timer.read();
    }

    /// Get bandwidth with automatic unit selection for optimal readability
    pub fn bandwidthWithUnits(self: *BandwidthMeter) SpeedMeasurement {
        const speed_bps = self.bandwidth();
        return selectOptimalUnit(speed_bps);
    }

    /// Convert bytes per second to optimal unit for display (in bits per second)
    fn selectOptimalUnit(speed_bytes_per_sec: f64) SpeedMeasurement {
        // Convert bytes/s to bits/s
        const speed_bits_per_sec = speed_bytes_per_sec * 8.0;
        const abs_speed = @abs(speed_bits_per_sec);

        if (abs_speed >= 1_000_000_000) {
            return SpeedMeasurement{ .value = speed_bits_per_sec / 1_000_000_000, .unit = .gbps };
        } else if (abs_speed >= 1_000_000) {
            return SpeedMeasurement{ .value = speed_bits_per_sec / 1_000_000, .unit = .mbps };
        } else if (abs_speed >= 1_000) {
            return SpeedMeasurement{ .value = speed_bits_per_sec / 1_000, .unit = .kbps };
        } else {
            return SpeedMeasurement{ .value = speed_bits_per_sec, .unit = .bps };
        }
    }

    /// Get bandwidth in Mbps (commonly used for internet speeds)
    pub fn bandwidthMbps(self: *BandwidthMeter) f64 {
        return self.bandwidth() / 1_000_000;
    }

    /// Format bandwidth as human-readable string with appropriate units
    pub fn formatBandwidth(self: *BandwidthMeter, allocator: std.mem.Allocator) ![]u8 {
        const measurement = self.bandwidthWithUnits();
        return measurement.format(allocator);
    }
};

const testing = std.testing;

test "BandwidthMeter init" {
    const meter = BandwidthMeter.init();
    try testing.expect(!meter.started);
    try testing.expectEqual(@as(u64, 0), meter.bytes_transferred);
}

test "BandwidthMeter start" {
    var meter = BandwidthMeter.init();
    try meter.start();
    try testing.expect(meter.started);
}

test "BandwidthMeter record_data and bytesTransferred" {
    var meter = BandwidthMeter.init();
    try meter.start();

    const data = "hello world";
    const recorded = meter.record_data(data);

    try testing.expectEqual(data.len, recorded);
    try testing.expectEqual(@as(u64, data.len), meter.bytesTransferred());

    // Record more data
    const more_data = "test";
    _ = meter.record_data(more_data);
    try testing.expectEqual(@as(u64, data.len + more_data.len), meter.bytesTransferred());
}

test "BandwidthMeter record_bytes" {
    var meter = BandwidthMeter.init();
    try meter.start();

    meter.record_bytes(1000);
    try testing.expectEqual(@as(u64, 1000), meter.bytesTransferred());

    meter.record_bytes(500);
    try testing.expectEqual(@as(u64, 1500), meter.bytesTransferred());
}

test "BandwidthMeter bandwidth calculation" {
    var meter = BandwidthMeter.init();
    try meter.start();

    meter.record_bytes(1000); // 1000 bytes

    // Sleep briefly to ensure time passes
    std.time.sleep(std.time.ns_per_ms * 10); // 10ms

    const bw = meter.bandwidth();
    try testing.expect(bw > 0);
}

test "BandwidthMeter duration" {
    var meter = BandwidthMeter.init();
    try meter.start();

    std.time.sleep(std.time.ns_per_ms * 10); // 10ms

    const dur = try meter.duration();
    try testing.expect(dur >= std.time.ns_per_ms * 5); // Allow more variance
}

test "BandwidthMeter not started errors" {
    var meter = BandwidthMeter.init();

    // Should return 0 bandwidth when not started
    try testing.expectEqual(@as(f64, 0), meter.bandwidth());

    // Should error when getting duration before start
    try testing.expectError(error.NotStarted, meter.duration());
}

test "BandwidthMeter unit conversion" {
    var meter = BandwidthMeter.init();
    try meter.start();

    // Test different speed ranges
    meter.bytes_transferred = 1000;
    meter.timer = try std.time.Timer.start();
    std.time.sleep(std.time.ns_per_s); // 1 second

    const measurement = meter.bandwidthWithUnits();

    // Should automatically select appropriate unit
    try testing.expect(measurement.value > 0);
    try testing.expect(measurement.unit != .gbps); // Shouldn't be gigabits for small test
}

test "BandwidthMeter Mbps conversion" {
    var meter = BandwidthMeter.init();
    try meter.start();

    meter.bytes_transferred = 1_000_000; // 1MB
    meter.timer = try std.time.Timer.start();
    std.time.sleep(std.time.ns_per_s); // 1 second

    const mbps = meter.bandwidthMbps();
    try testing.expect(mbps > 0);
}

test "SpeedMeasurement format" {
    const measurement = SpeedMeasurement{ .value = 100.5, .unit = .mbps };
    const allocator = testing.allocator;

    const formatted = try measurement.format(allocator);
    defer allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "100.5") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Mbps") != null);
}
