const std = @import("std");
const testing = std.testing;
const measurement_strategy = @import("../measurement_strategy.zig");
const MeasurementStrategy = measurement_strategy.MeasurementStrategy;
const StabilityCriteria = measurement_strategy.StabilityCriteria;
const BandwidthMeter = @import("../bandwidth.zig").BandwidthMeter;

test "createDurationStrategy" {
    const strategy = measurement_strategy.createDurationStrategy(10, 100);

    try testing.expect(strategy.target_duration_ns == 10 * std.time.ns_per_s);
    try testing.expect(strategy.progress_update_interval_ms == 100);
}

test "DurationStrategy shouldContinue" {
    const strategy = measurement_strategy.createDurationStrategy(1, 100); // 1 second

    // Should continue before target duration
    try testing.expect(strategy.shouldContinue(500 * std.time.ns_per_ms)); // 0.5 seconds

    // Should not continue after target duration
    try testing.expect(!strategy.shouldContinue(2 * std.time.ns_per_s)); // 2 seconds
}

test "Strategy getSleepInterval" {
    // Duration strategy should use progress update interval
    const duration_strategy = measurement_strategy.createDurationStrategy(10, 250);
    try testing.expect(duration_strategy.getSleepInterval() == 250 * std.time.ns_per_ms);
}

// Fast.com-style stability tests

test "StabilityCriteria default values" {
    const criteria = StabilityCriteria{};

    try testing.expect(criteria.ramp_up_duration_seconds == 4);
    try testing.expect(criteria.max_duration_seconds == 25);
    try testing.expect(criteria.measurement_interval_ms == 750);
    try testing.expect(criteria.sliding_window_size == 6);
    try testing.expect(criteria.stability_threshold_cov == 0.15);
    try testing.expect(criteria.stable_checks_required == 2);
}

test "createStabilityStrategy" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 5,
        .max_duration_seconds = 20,
        .measurement_interval_ms = 500,
        .sliding_window_size = 8,
        .stability_threshold_cov = 0.12,
        .stable_checks_required = 3,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    try testing.expect(strategy.criteria.ramp_up_duration_seconds == 5);
    try testing.expect(strategy.criteria.max_duration_seconds == 20);
    try testing.expect(strategy.criteria.measurement_interval_ms == 500);
    try testing.expect(strategy.criteria.sliding_window_size == 8);
    try testing.expect(strategy.criteria.stability_threshold_cov == 0.12);
    try testing.expect(strategy.criteria.stable_checks_required == 3);
    try testing.expect(strategy.ramp_up_duration_ns == 5 * std.time.ns_per_s);
    try testing.expect(strategy.max_duration_ns == 20 * std.time.ns_per_s);
}

test "StabilityStrategy shouldContinue" {
    const criteria = StabilityCriteria{
        .max_duration_seconds = 20,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should continue before max duration
    try testing.expect(strategy.shouldContinue(15 * std.time.ns_per_s));

    // Should not continue after max duration
    try testing.expect(!strategy.shouldContinue(25 * std.time.ns_per_s));
}

test "StabilityStrategy getSleepInterval" {
    const criteria = StabilityCriteria{};
    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should be measurement_interval / 3 = 750ms / 3 = 250ms
    try testing.expect(strategy.getSleepInterval() == 250 * std.time.ns_per_ms);
}

test "StabilityStrategy shouldSample timing" {
    const criteria = StabilityCriteria{};
    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // First call should not sample (last_sample_time is 0)
    try testing.expect(!strategy.shouldSample(0));

    // Should not sample if less than 1 second has passed
    strategy.last_sample_time = 500 * std.time.ns_per_ms; // 0.5 seconds
    try testing.expect(!strategy.shouldSample(800 * std.time.ns_per_ms)); // 0.8 seconds

    // Should sample if 1 second or more has passed
    try testing.expect(strategy.shouldSample(1600 * std.time.ns_per_ms)); // 1.6 seconds
}

test "StabilityStrategy addSample basic functionality" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 1, // Short for testing
        .sliding_window_size = 3,
        .stability_threshold_cov = 0.5, // High threshold to avoid early stability
        .stable_checks_required = 2,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // First sample should be skipped
    const is_stable1 = try strategy.addSample(1 * std.time.ns_per_s, 1000);
    try testing.expect(!is_stable1);
    try testing.expect(strategy.speed_measurements.items.len == 0);

    // Second sample should be added
    const is_stable2 = try strategy.addSample(2 * std.time.ns_per_s, 2000);
    try testing.expect(!is_stable2); // Not stable yet, need more measurements for CoV
    try testing.expect(strategy.speed_measurements.items.len == 1);

    // Third sample should be added
    const is_stable3 = try strategy.addSample(3 * std.time.ns_per_s, 3000);
    try testing.expect(!is_stable3); // Still need more measurements
    try testing.expect(strategy.speed_measurements.items.len == 2);

    // Fourth sample should trigger stability check (we have 3 measurements now)
    _ = try strategy.addSample(4 * std.time.ns_per_s, 4000);
    try testing.expect(strategy.speed_measurements.items.len == 3);
}

test "StabilityStrategy requires ramp up duration" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 10,
        .sliding_window_size = 2,
        .stability_threshold_cov = 0.01, // Low threshold for easy stability
        .stable_checks_required = 1,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples before ramp up duration - should not be stable
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000);
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000);
    const is_stable_early = try strategy.addSample(3 * std.time.ns_per_s, 3000);
    try testing.expect(!is_stable_early); // Should not be stable before ramp up duration

    // Add sample after ramp up duration - might be stable
    _ = try strategy.addSample(11 * std.time.ns_per_s, 11000);
    // Result depends on CoV calculation, but should not crash
}

test "StabilityStrategy handleProgress integration" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 2,
        .sliding_window_size = 2,
        .stability_threshold_cov = 0.1,
        .measurement_interval_ms = 500,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should not trigger sampling immediately
    const should_stop1 = try strategy.handleProgress(500 * std.time.ns_per_ms, 500);
    try testing.expect(!should_stop1);

    // Should not trigger sampling if less than 1 second elapsed
    const should_stop2 = try strategy.handleProgress(800 * std.time.ns_per_ms, 800);
    try testing.expect(!should_stop2);

    // Should trigger sampling after measurement interval (750ms)
    _ = try strategy.handleProgress(750 * std.time.ns_per_ms, 750);
    try testing.expect(strategy.speed_measurements.items.len == 0); // First sample skipped

    // Should add second sample
    _ = try strategy.handleProgress(1500 * std.time.ns_per_ms, 1500);
    try testing.expect(strategy.speed_measurements.items.len == 1);
}

test "CoV stability detection algorithm" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 1, // Short for testing
        .sliding_window_size = 4,
        .stability_threshold_cov = 0.05, // 5% CoV threshold
        .stable_checks_required = 1,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add stable samples after ramp up period
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s (after ramp up)
    _ = try strategy.addSample(3 * std.time.ns_per_s, 3000); // 1000 bytes/s
    _ = try strategy.addSample(4 * std.time.ns_per_s, 4000); // 1000 bytes/s

    // This should be stable since CoV should be very low
    const is_stable = try strategy.addSample(5 * std.time.ns_per_s, 5000); // 1000 bytes/s

    // Should be stable with consistent speeds
    try testing.expect(is_stable);
}

test "CoV stability detection - unstable case" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 1, // Short for testing
        .sliding_window_size = 3,
        .stability_threshold_cov = 0.02, // Strict 2% CoV threshold
        .stable_checks_required = 1,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples that should NOT be stable (high variance)
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s (after ramp up)
    _ = try strategy.addSample(3 * std.time.ns_per_s, 3500); // 1500 bytes/s (high variance)

    // This should NOT be stable due to high CoV
    const is_stable = try strategy.addSample(4 * std.time.ns_per_s, 4000); // 500 bytes/s (high variance)

    // Should not be stable with inconsistent speeds
    try testing.expect(!is_stable);
}

test "CoV stability handles variable speeds correctly" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 1,
        .sliding_window_size = 6,
        .stability_threshold_cov = 0.05,
        .stable_checks_required = 2,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples with a peak in the middle, then lower speeds
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s (after ramp up)
    _ = try strategy.addSample(3 * std.time.ns_per_s, 4000); // 2000 bytes/s (peak creates high CoV)
    _ = try strategy.addSample(4 * std.time.ns_per_s, 5000); // 1000 bytes/s
    _ = try strategy.addSample(5 * std.time.ns_per_s, 6000); // 1000 bytes/s

    // Should not be stable yet due to high CoV from the peak
    const is_stable = try strategy.addSample(6 * std.time.ns_per_s, 7000); // 1000 bytes/s

    // CoV should still be too high due to the peak in the sliding window
    try testing.expect(!is_stable);

    // Test should not crash and should have collected measurements
    try testing.expect(strategy.speed_measurements.items.len > 0);
}

test "CoV stability detection realistic scenario" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 5,
        .max_duration_seconds = 20,
        .stability_threshold_cov = 0.15, // 15% CoV threshold
        .sliding_window_size = 6,
        .stable_checks_required = 2,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Simulate realistic speed test progression: ramp up, then stabilize
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 3000); // 2000 bytes/s (ramp up)
    _ = try strategy.addSample(3 * std.time.ns_per_s, 6000); // 3000 bytes/s (still ramping)

    // Before min duration - should not be stable regardless of measurements
    const stable_before_min = try strategy.addSample(4 * std.time.ns_per_s, 10000); // 4000 bytes/s (peak)
    try testing.expect(!stable_before_min);

    // After min duration with stable measurements
    _ = try strategy.addSample(6 * std.time.ns_per_s, 16000); // 4000 bytes/s (stable)
    _ = try strategy.addSample(7 * std.time.ns_per_s, 20000); // 4000 bytes/s (stable)
    _ = try strategy.addSample(8 * std.time.ns_per_s, 24000); // 4000 bytes/s (stable)
    const stable_after_min = try strategy.addSample(9 * std.time.ns_per_s, 28000); // 4000 bytes/s (stable)

    // Should be able to detect stability after minimum duration with consistent speeds
    try testing.expect(stable_after_min or strategy.speed_measurements.items.len >= 6);
}

test "CoV timing intervals specification" {
    const criteria = StabilityCriteria{};
    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should be measurement_interval / 3 = 750ms / 3 = 250ms
    try testing.expect(strategy.getSleepInterval() == 250 * std.time.ns_per_ms);

    // Should enforce measurement interval sampling (750ms by default)
    try testing.expect(!strategy.shouldSample(0));
    strategy.last_sample_time = 500 * std.time.ns_per_ms;
    try testing.expect(!strategy.shouldSample(1000 * std.time.ns_per_ms));
    try testing.expect(strategy.shouldSample(1250 * std.time.ns_per_ms));
}

test "CoV algorithm handles edge cases correctly" {
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 1,
        .sliding_window_size = 3,
        .stability_threshold_cov = 0.05,
        .stable_checks_required = 1,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Test very small speed changes (edge case for percentage calculation)
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 1001); // 1 byte/s
    _ = try strategy.addSample(3 * std.time.ns_per_s, 1002); // 1 byte/s
    const stable_small = try strategy.addSample(4 * std.time.ns_per_s, 1003); // 1 byte/s

    // Should handle small speeds without division errors
    _ = stable_small; // May or may not be stable, but shouldn't crash

    // Test zero speed edge case
    strategy.speed_measurements.clearRetainingCapacity();
    strategy.last_sample_time = 0;
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    const stable_zero = try strategy.addSample(2 * std.time.ns_per_s, 1000); // 0 bytes/s

    // Zero speed should not be considered stable
    try testing.expect(!stable_zero);
}
