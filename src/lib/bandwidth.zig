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

    fn bitsPerSecond(self: SpeedUnit) f64 {
        return switch (self) {
            .bps => 1,
            .kbps => 1_000,
            .mbps => 1_000_000,
            .gbps => 1_000_000_000,
        };
    }
};

pub const SpeedMeasurement = struct {
    value: f64,
    unit: SpeedUnit,
};

pub const Speed = struct {
    bits_per_second: f64,

    pub fn fromBytesPerSecond(bytes_per_second: f64) Speed {
        return fromBitsPerSecond(bytes_per_second * 8);
    }

    pub fn fromBitsPerSecond(bits_per_second: f64) Speed {
        return .{ .bits_per_second = bits_per_second };
    }

    pub fn valueIn(self: Speed, unit: SpeedUnit) f64 {
        return self.bits_per_second / unit.bitsPerSecond();
    }

    pub fn forDisplay(self: Speed) SpeedMeasurement {
        const unit: SpeedUnit = if (@abs(self.bits_per_second) >= 1_000_000_000)
            .gbps
        else if (@abs(self.bits_per_second) >= 1_000_000)
            .mbps
        else if (@abs(self.bits_per_second) >= 1_000)
            .kbps
        else
            .bps;

        return .{
            .value = self.valueIn(unit),
            .unit = unit,
        };
    }
};

pub const BandwidthMeter = struct {
    io: std.Io,
    _bytes_transferred: u64 = 0,
    _started_at: std.Io.Timestamp = .zero,
    _started: bool = false,

    pub fn init(io: std.Io) BandwidthMeter {
        return .{ .io = io };
    }

    pub fn start(self: *BandwidthMeter) void {
        self._started_at = .now(self.io, .awake);
        self._started = true;
    }

    pub fn update_total(self: *BandwidthMeter, total_bytes: u64) void {
        assert(self._started);
        self._bytes_transferred = total_bytes;
    }

    pub fn bandwidth(self: *BandwidthMeter) f64 {
        if (!self._started) return 0;

        const delta_nanos = self._started_at.untilNow(self.io, .awake).toNanoseconds();
        const delta_secs = @as(f64, @floatFromInt(delta_nanos)) / std.time.ns_per_s;

        return @as(f64, @floatFromInt(self._bytes_transferred)) / delta_secs;
    }

    pub fn speed(self: *BandwidthMeter) Speed {
        return Speed.fromBytesPerSecond(self.bandwidth());
    }
};

const testing = std.testing;

test "BandwidthMeter init" {
    const meter = BandwidthMeter.init(testing.io);
    try testing.expect(!meter._started);
    try testing.expectEqual(@as(u64, 0), meter._bytes_transferred);
}

test "BandwidthMeter start" {
    var meter = BandwidthMeter.init(testing.io);
    meter.start();
    try testing.expect(meter._started);
}

test "BandwidthMeter record_bytes" {
    var meter = BandwidthMeter.init(testing.io);
    meter.start();

    meter.update_total(1000);
    meter.update_total(1500);

    // Just test that bandwidth calculation works
    const bw = meter.bandwidth();
    try testing.expect(bw >= 0);
}

test "BandwidthMeter bandwidth calculation" {
    var meter = BandwidthMeter.init(testing.io);
    meter.start();

    meter.update_total(1000); // 1000 bytes

    // Sleep briefly to ensure time passes
    try testing.io.sleep(.fromMilliseconds(10), .awake);

    const bw = meter.bandwidth();
    try testing.expect(bw > 0);
}

test "BandwidthMeter not started errors" {
    var meter = BandwidthMeter.init(testing.io);

    // Should return 0 bandwidth when not started
    try testing.expectEqual(@as(f64, 0), meter.bandwidth());
}

test "BandwidthMeter unit conversion" {
    var meter = BandwidthMeter.init(testing.io);
    meter.start();

    // Test different speed ranges
    meter._bytes_transferred = 1000;
    meter._started_at = .now(testing.io, .awake);
    try testing.io.sleep(.fromSeconds(1), .awake);

    const measurement = meter.speed().forDisplay();

    // Should automatically select appropriate unit
    try testing.expect(measurement.value > 0);
    try testing.expect(measurement.unit != .gbps); // Shouldn't be gigabits for small test
}

test "Speed converts bytes per second to canonical bits per second" {
    const speed = Speed.fromBytesPerSecond(312_500_000);

    try testing.expectEqual(@as(f64, 2_500_000_000), speed.bits_per_second);
    try testing.expectEqual(@as(f64, 2_500), speed.valueIn(.mbps));
}

test "Speed converts canonical bits per second to every unit" {
    const speed = Speed.fromBitsPerSecond(2_500_000_000);

    try testing.expectEqual(@as(f64, 2_500_000_000), speed.valueIn(.bps));
    try testing.expectEqual(@as(f64, 2_500_000), speed.valueIn(.kbps));
    try testing.expectEqual(@as(f64, 2_500), speed.valueIn(.mbps));
    try testing.expectEqual(@as(f64, 2.5), speed.valueIn(.gbps));
}

test "Speed selects display units at decimal boundaries" {
    const cases = [_]struct {
        bits_per_second: f64,
        expected_value: f64,
        expected_unit: SpeedUnit,
    }{
        .{ .bits_per_second = 0, .expected_value = 0, .expected_unit = .bps },
        .{ .bits_per_second = 999, .expected_value = 999, .expected_unit = .bps },
        .{ .bits_per_second = 1_000, .expected_value = 1, .expected_unit = .kbps },
        .{ .bits_per_second = 999_999, .expected_value = 999.999, .expected_unit = .kbps },
        .{ .bits_per_second = 1_000_000, .expected_value = 1, .expected_unit = .mbps },
        .{ .bits_per_second = 999_999_999, .expected_value = 999.999999, .expected_unit = .mbps },
        .{ .bits_per_second = 1_000_000_000, .expected_value = 1, .expected_unit = .gbps },
        .{ .bits_per_second = -1_000_000_000, .expected_value = -1, .expected_unit = .gbps },
    };

    for (cases) |case| {
        const display = Speed.fromBitsPerSecond(case.bits_per_second).forDisplay();
        try testing.expectApproxEqAbs(case.expected_value, display.value, 1e-9);
        try testing.expectEqual(case.expected_unit, display.unit);
    }
}
