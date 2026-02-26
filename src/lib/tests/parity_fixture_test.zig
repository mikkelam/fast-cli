const std = @import("std");
const testing = std.testing;
const measurement_strategy = @import("../measurement_strategy.zig");

const Fixture = struct {
    name: []const u8,
    direction: []const u8,
    criteria: measurement_strategy.StabilityCriteria,
    samples: []Sample,
    expected: Expected,

    const Sample = struct {
        t_ms: u64,
        total_bytes: u64,
    };

    const Expected = struct {
        stop_at_ms: u64,
        speed_mbps: f64,
        speed_tolerance_mbps: f64,
        stable: bool,
    };
};

fn absDiffU64(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn runFixture(comptime path: []const u8) !void {
    const data = @embedFile(path);
    var parsed = try std.json.parseFromSlice(Fixture, testing.allocator, data, .{});
    defer parsed.deinit();

    const fixture = parsed.value;

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, fixture.criteria);
    defer strategy.deinit();

    var stop_at_ms = fixture.samples[fixture.samples.len - 1].t_ms;
    var stopped = false;

    for (fixture.samples) |sample| {
        const decision = try strategy.handleProgress(sample.t_ms * std.time.ns_per_ms, sample.total_bytes);
        if (decision.should_stop) {
            stopped = true;
            stop_at_ms = sample.t_ms;
            break;
        }
    }

    const max_duration_ms = @as(u64, fixture.criteria.max_duration_seconds) * 1000;
    const stable_detected = stopped and stop_at_ms < max_duration_ms;
    try testing.expectEqual(fixture.expected.stable, stable_detected);

    if (stable_detected) {
        const stop_tolerance_ms = fixture.criteria.progress_frequency_ms;
        try testing.expect(absDiffU64(stop_at_ms, fixture.expected.stop_at_ms) <= stop_tolerance_ms);
    } else {
        try testing.expect(stop_at_ms >= fixture.expected.stop_at_ms);
    }

    const duration_ns = stop_at_ms * std.time.ns_per_ms;
    const total_bytes = fixture.samples[fixture.samples.len - 1].total_bytes;
    const speed_bits_per_sec = strategy.finalSpeedBitsPerSecond(total_bytes, duration_ns);
    const speed_mbps = speed_bits_per_sec / 1_000_000;

    try testing.expect(@abs(speed_mbps - fixture.expected.speed_mbps) <= fixture.expected.speed_tolerance_mbps);
}

test "fixture replay: steady download" {
    try runFixture("fixtures/download_steady.json");
}

test "fixture replay: bursty download" {
    try runFixture("fixtures/download_bursty.json");
}

test "fixture replay: steady upload" {
    try runFixture("fixtures/upload_steady.json");
}

test "fixture replay: unstable upload" {
    try runFixture("fixtures/upload_unstable.json");
}
