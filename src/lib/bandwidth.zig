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
};

pub const BandwidthMeter = struct {
    _bytes_transferred: u64 = 0,
    _timer: std.time.Timer = undefined,
    _started: bool = false,

    pub fn init() BandwidthMeter {
        return .{};
    }

    pub fn start(self: *BandwidthMeter) !void {
        self._timer = try std.time.Timer.start();
        self._started = true;
    }

    pub fn update_total(self: *BandwidthMeter, total_bytes: u64) void {
        assert(self._started);
        self._bytes_transferred = total_bytes;
    }

    pub fn record_bytes(self: *BandwidthMeter, byte_count: usize) void {
        assert(self._started);
        self._bytes_transferred += byte_count;
    }

    pub fn bandwidth(self: *BandwidthMeter) f64 {
        if (!self._started) return 0;

        const delta_nanos = self._timer.read();
        const delta_secs = @as(f64, @floatFromInt(delta_nanos)) / std.time.ns_per_s;

        return @as(f64, @floatFromInt(self._bytes_transferred)) / delta_secs;
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
};

const testing = std.testing;

test "BandwidthMeter init" {
    const meter = BandwidthMeter.init();
    try testing.expect(!meter._started);
    try testing.expectEqual(@as(u64, 0), meter._bytes_transferred);
}

test "BandwidthMeter start" {
    var meter = BandwidthMeter.init();
    try meter.start();
    try testing.expect(meter._started);
}

test "BandwidthMeter record_bytes" {
    var meter = BandwidthMeter.init();
    try meter.start();

    meter.record_bytes(1000);
    meter.record_bytes(500);

    // Just test that bandwidth calculation works
    const bw = meter.bandwidth();
    try testing.expect(bw >= 0);
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

test "BandwidthMeter not started errors" {
    var meter = BandwidthMeter.init();

    // Should return 0 bandwidth when not started
    try testing.expectEqual(@as(f64, 0), meter.bandwidth());
}

test "BandwidthMeter unit conversion" {
    var meter = BandwidthMeter.init();
    try meter.start();

    // Test different speed ranges
    meter._bytes_transferred = 1000;
    meter._timer = try std.time.Timer.start();
    std.time.sleep(std.time.ns_per_s); // 1 second

    const measurement = meter.bandwidthWithUnits();

    // Should automatically select appropriate unit
    try testing.expect(measurement.value > 0);
    try testing.expect(measurement.unit != .gbps); // Shouldn't be gigabits for small test
}
