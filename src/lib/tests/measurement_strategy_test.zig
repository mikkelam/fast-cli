const std = @import("std");
const testing = std.testing;
const measurement_strategy = @import("../measurement_strategy.zig");
const StabilityCriteria = measurement_strategy.StabilityCriteria;

fn runStableSequence(strategy: *measurement_strategy.StabilityStrategy, bytes_per_tick: u64, tick_ms: u64, steps: usize) !measurement_strategy.StabilityDecision {
    var total_bytes: u64 = 0;
    var decision = measurement_strategy.StabilityDecision{
        .should_stop = false,
        .desired_connections = 1,
        .speed_bits_per_sec = 0,
    };

    _ = try strategy.handleProgress(0, 0);

    for (0..steps) |i| {
        total_bytes += bytes_per_tick;
        const t_ms = (i + 1) * tick_ms;
        decision = try strategy.handleProgress(t_ms * std.time.ns_per_ms, total_bytes);
        if (decision.should_stop) break;
    }

    return decision;
}

test "createDurationStrategy" {
    const strategy = measurement_strategy.createDurationStrategy(10, 100);

    try testing.expect(strategy.target_duration_ns == 10 * std.time.ns_per_s);
    try testing.expect(strategy.progress_update_interval_ms == 100);
}

test "DurationStrategy shouldContinue" {
    const strategy = measurement_strategy.createDurationStrategy(1, 100);

    try testing.expect(strategy.shouldContinue(500 * std.time.ns_per_ms));
    try testing.expect(!strategy.shouldContinue(2 * std.time.ns_per_s));
}

test "StabilityCriteria defaults" {
    const criteria = StabilityCriteria{};

    try testing.expectEqual(@as(u32, 7), criteria.min_duration_seconds);
    try testing.expectEqual(@as(u32, 30), criteria.max_duration_seconds);
    try testing.expectEqual(@as(u64, 150), criteria.progress_frequency_ms);
    try testing.expectEqual(@as(u32, 5), criteria.moving_average_window_size);
    try testing.expectEqual(@as(u32, 6), criteria.min_stable_measurements);
    try testing.expectEqual(@as(u32, 1), criteria.connections_min);
    try testing.expectEqual(@as(u32, 8), criteria.connections_max);
}

test "StabilityStrategy detects stable throughput" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 2,
        .max_duration_seconds = 10,
        .progress_frequency_ms = 100,
        .moving_average_window_size = 5,
        .stability_delta_percent = 2.0,
        .min_stable_measurements = 6,
        .connections_min = 1,
        .connections_max = 8,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // 2,250,000 bytes / 150ms ~= 120 Mbps. We use 1,500,000 / 100ms for the same speed.
    const decision = try runStableSequence(&strategy, 1_500_000, 100, 80);

    try testing.expect(decision.should_stop);
    try testing.expect(decision.speed_bits_per_sec > 100_000_000);
    try testing.expect(decision.speed_bits_per_sec < 140_000_000);
}

test "StabilityStrategy ramps connections with speed" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 30,
        .max_duration_seconds = 30,
        .progress_frequency_ms = 100,
        .moving_average_window_size = 1,
        .stability_delta_percent = 0.5,
        .min_stable_measurements = 100,
        .connections_min = 1,
        .connections_max = 8,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    _ = try strategy.handleProgress(0, 0);

    // ~560 Kbps
    _ = try strategy.handleProgress(100 * std.time.ns_per_ms, 7_000);
    var decision = try strategy.handleProgress(200 * std.time.ns_per_ms, 14_000);
    try testing.expectEqual(@as(u32, 2), decision.desired_connections);

    // ~1.6 Mbps
    decision = try strategy.handleProgress(300 * std.time.ns_per_ms, 34_000);
    try testing.expectEqual(@as(u32, 3), decision.desired_connections);

    // ~12 Mbps
    decision = try strategy.handleProgress(400 * std.time.ns_per_ms, 184_000);
    try testing.expectEqual(@as(u32, 5), decision.desired_connections);

    // ~52 Mbps
    decision = try strategy.handleProgress(500 * std.time.ns_per_ms, 834_000);
    try testing.expectEqual(@as(u32, 8), decision.desired_connections);
}

test "StabilityStrategy stops at max duration when unstable" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 2,
        .max_duration_seconds = 4,
        .progress_frequency_ms = 100,
        .moving_average_window_size = 1,
        .stability_delta_percent = 1.0,
        .min_stable_measurements = 6,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    _ = try strategy.handleProgress(0, 0);

    var total_bytes: u64 = 0;
    var decision = measurement_strategy.StabilityDecision{
        .should_stop = false,
        .desired_connections = 1,
        .speed_bits_per_sec = 0,
    };

    for (0..60) |i| {
        const t_ms: u64 = @intCast((i + 1) * 100);
        // Alternate between low/high deltas so we remain unstable.
        total_bytes += if (i % 2 == 0) 200_000 else 2_000_000;
        decision = try strategy.handleProgress(t_ms * std.time.ns_per_ms, total_bytes);
        if (decision.should_stop) break;
    }

    try testing.expect(decision.should_stop);
}

test "finalSpeedBitsPerSecond falls back to totals when no measurements" {
    const criteria = StabilityCriteria{};
    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    const speed_bits = strategy.finalSpeedBitsPerSecond(10_000_000, 2 * std.time.ns_per_s);
    // 10,000,000 bytes in 2 seconds = 40,000,000 bps
    try testing.expectApproxEqAbs(@as(f64, 40_000_000), speed_bits, 0.1);
}
