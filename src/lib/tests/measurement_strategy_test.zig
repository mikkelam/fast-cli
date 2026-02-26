const std = @import("std");
const testing = std.testing;
const measurement_strategy = @import("../measurement_strategy.zig");
const StabilityCriteria = measurement_strategy.StabilityCriteria;
const EstimationPhase = measurement_strategy.EstimationPhase;

fn defaultDecision() measurement_strategy.StabilityDecision {
    return .{
        .should_stop = false,
        .desired_connections = 1,
        .phase = .ramp,
        .display_speed_bits_per_sec = 0,
        .authoritative_speed_bits_per_sec = 0,
        .speed_bits_per_sec = 0,
        .sampled = false,
    };
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

test "StabilityStrategy transitions to steady phase and locks estimator" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 2,
        .max_duration_seconds = 10,
        .progress_frequency_ms = 100,
        .moving_average_window_size = 5,
        .stability_delta_percent = 2.0,
        .min_stable_measurements = 100,
        .connections_min = 1,
        .connections_max = 8,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    _ = try strategy.handleProgress(0, 0);

    var total_bytes: u64 = 0;
    var saw_ramp = false;
    var saw_steady = false;

    for (0..120) |i| {
        total_bytes += 1_500_000;
        const t_ms = @as(u64, @intCast(i + 1)) * 100;
        const decision = try strategy.handleProgress(t_ms * std.time.ns_per_ms, total_bytes);
        if (!decision.sampled) continue;

        if (decision.phase == .ramp and decision.display_speed_bits_per_sec > 0) {
            saw_ramp = true;
        }
        if (decision.phase == .steady) {
            saw_steady = true;
            try testing.expectEqual(decision.display_speed_bits_per_sec, decision.authoritative_speed_bits_per_sec);
            try testing.expectEqual(decision.desired_connections, strategy.locked_connections);
            break;
        }
    }

    try testing.expect(saw_ramp);
    try testing.expect(saw_steady);
}

test "StabilityStrategy steady estimator uses time-weighted average" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 0,
        .max_duration_seconds = 30,
        .progress_frequency_ms = 50,
        .moving_average_window_size = 5,
        .stability_delta_percent = 0.1,
        .min_stable_measurements = 100,
        .connections_min = 1,
        .connections_max = 1,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    _ = try strategy.handleProgress(0, 0);

    var total_bytes: u64 = 0;
    var now_ms: u64 = 0;
    var decision = defaultDecision();

    const warmup_intervals_ms = [_]u64{ 100, 100, 100, 100 };
    for (warmup_intervals_ms) |dt_ms| {
        now_ms += dt_ms;
        total_bytes += 500_000;
        decision = try strategy.handleProgress(now_ms * std.time.ns_per_ms, total_bytes);
    }

    while (decision.phase != .steady) {
        now_ms += 100;
        total_bytes += 500_000;
        decision = try strategy.handleProgress(now_ms * std.time.ns_per_ms, total_bytes);
    }

    now_ms += 100;
    total_bytes += 1_000_000;
    decision = try strategy.handleProgress(now_ms * std.time.ns_per_ms, total_bytes);

    now_ms += 300;
    total_bytes += 1_000_000;
    decision = try strategy.handleProgress(now_ms * std.time.ns_per_ms, total_bytes);

    const expected_bps = (@as(f64, 2_000_000) * 8.0) / 0.4;
    try testing.expectApproxEqAbs(expected_bps, decision.authoritative_speed_bits_per_sec, 0.001);
}

test "StabilityStrategy final speed equals last displayed speed after steady samples" {
    const criteria = StabilityCriteria{
        .min_duration_seconds = 0,
        .max_duration_seconds = 10,
        .progress_frequency_ms = 100,
        .moving_average_window_size = 5,
        .stability_delta_percent = 2.0,
        .min_stable_measurements = 100,
        .connections_min = 1,
        .connections_max = 3,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    _ = try strategy.handleProgress(0, 0);

    var total_bytes: u64 = 0;
    var last_time_ms: u64 = 0;
    var last_display_bps: f64 = 0;
    var last_phase: EstimationPhase = .ramp;

    for (0..80) |i| {
        total_bytes += 800_000;
        last_time_ms = @as(u64, @intCast(i + 1)) * 100;
        const decision = try strategy.handleProgress(last_time_ms * std.time.ns_per_ms, total_bytes);
        if (!decision.sampled) continue;
        last_display_bps = decision.display_speed_bits_per_sec;
        last_phase = decision.phase;
    }

    try testing.expect(last_display_bps > 0);
    try testing.expectEqual(EstimationPhase.steady, last_phase);

    const final_bps = strategy.finalSpeedBitsPerSecond(total_bytes, last_time_ms * std.time.ns_per_ms);
    try testing.expectEqual(last_display_bps, final_bps);
}
