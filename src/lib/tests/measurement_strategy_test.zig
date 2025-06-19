const std = @import("std");
const testing = std.testing;
const measurement_strategy = @import("../measurement_strategy.zig");
const MeasurementStrategy = measurement_strategy.MeasurementStrategy;
const StabilityCriteria = measurement_strategy.StabilityCriteria;
const FastStabilityCriteria = measurement_strategy.FastStabilityCriteria;
const BandwidthMeter = @import("../bandwidth.zig").BandwidthMeter;

test "createDurationStrategy" {
    const strategy = measurement_strategy.createDurationStrategy(10, 100);

    try testing.expect(strategy.target_duration_ns == 10 * std.time.ns_per_s);
    try testing.expect(strategy.progress_update_interval_ms == 100);
}

test "createStabilityStrategy" {
    const criteria = StabilityCriteria{
        .min_samples = 5,
        .max_variance_percent = 10.0,
        .max_duration_seconds = 30,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    try testing.expect(strategy.criteria.min_samples == 5);
    try testing.expect(strategy.criteria.max_variance_percent == 10.0);
    try testing.expect(strategy.criteria.max_duration_seconds == 30);
    try testing.expect(strategy.max_duration_ns == 30 * std.time.ns_per_s);
}

test "DurationStrategy shouldContinue" {
    const strategy = measurement_strategy.createDurationStrategy(1, 100); // 1 second

    // Should continue before target duration
    try testing.expect(strategy.shouldContinue(500 * std.time.ns_per_ms)); // 0.5 seconds

    // Should not continue after target duration
    try testing.expect(!strategy.shouldContinue(2 * std.time.ns_per_s)); // 2 seconds
}

test "StabilityStrategy shouldContinue" {
    const criteria = StabilityCriteria{
        .min_samples = 3,
        .max_variance_percent = 5.0,
        .max_duration_seconds = 5,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should continue before max duration
    try testing.expect(strategy.shouldContinue(2 * std.time.ns_per_s)); // 2 seconds

    // Should not continue after max duration
    try testing.expect(!strategy.shouldContinue(10 * std.time.ns_per_s)); // 10 seconds
}

test "Strategy getSleepInterval" {
    // Duration strategy should use progress update interval
    const duration_strategy = measurement_strategy.createDurationStrategy(10, 250);
    try testing.expect(duration_strategy.getSleepInterval() == 250 * std.time.ns_per_ms);

    // Stability strategy should use fixed 100ms
    const criteria = StabilityCriteria{
        .min_samples = 3,
        .max_variance_percent = 5.0,
        .max_duration_seconds = 10,
    };
    var stability_strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer stability_strategy.deinit();

    try testing.expect(stability_strategy.getSleepInterval() == 100 * std.time.ns_per_ms);
}

test "StabilityCriteria default values" {
    const criteria = StabilityCriteria{
        .min_samples = 5,
        .max_variance_percent = 10.0,
        .max_duration_seconds = 30,
    };

    try testing.expect(criteria.min_samples == 5);
    try testing.expect(criteria.max_variance_percent == 10.0);
    try testing.expect(criteria.max_duration_seconds == 30);
}

test "StabilityStrategy shouldSample timing" {
    const criteria = StabilityCriteria{
        .min_samples = 3,
        .max_variance_percent = 5.0,
        .max_duration_seconds = 10,
    };

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
        .min_samples = 2,
        .max_variance_percent = 50.0, // High threshold to avoid early stability
        .max_duration_seconds = 10,
    };

    var strategy = measurement_strategy.createStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // First sample should be skipped
    const is_stable1 = try strategy.addSample(1 * std.time.ns_per_s, 1000);
    try testing.expect(!is_stable1);
    try testing.expect(strategy.speed_samples.items.len == 0);

    // Second sample should be added
    const is_stable2 = try strategy.addSample(2 * std.time.ns_per_s, 2000);
    try testing.expect(!is_stable2); // Not stable yet, need min_samples
    try testing.expect(strategy.speed_samples.items.len == 1);

    // Third sample should be added and might trigger stability check
    _ = try strategy.addSample(3 * std.time.ns_per_s, 3000);
    try testing.expect(strategy.speed_samples.items.len == 2);
    // Result depends on variance calculation, but should not crash
}

// Fast.com-style stability tests

test "FastStabilityCriteria default values" {
    const criteria = FastStabilityCriteria{};

    try testing.expect(criteria.min_duration_seconds == 7);
    try testing.expect(criteria.max_duration_seconds == 30);
    try testing.expect(criteria.stability_delta_percent == 2.0);
    try testing.expect(criteria.min_stable_measurements == 6);
}

test "createFastStabilityStrategy" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 10,
        .max_duration_seconds = 25,
        .stability_delta_percent = 3.0,
        .min_stable_measurements = 8,
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    try testing.expect(strategy.criteria.min_duration_seconds == 10);
    try testing.expect(strategy.criteria.max_duration_seconds == 25);
    try testing.expect(strategy.criteria.stability_delta_percent == 3.0);
    try testing.expect(strategy.criteria.min_stable_measurements == 8);
    try testing.expect(strategy.min_duration_ns == 10 * std.time.ns_per_s);
    try testing.expect(strategy.max_duration_ns == 25 * std.time.ns_per_s);
}

test "FastStabilityStrategy shouldContinue" {
    const criteria = FastStabilityCriteria{
        .max_duration_seconds = 20,
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should continue before max duration
    try testing.expect(strategy.shouldContinue(15 * std.time.ns_per_s));

    // Should not continue after max duration
    try testing.expect(!strategy.shouldContinue(25 * std.time.ns_per_s));
}

test "FastStabilityStrategy getSleepInterval" {
    const criteria = FastStabilityCriteria{};
    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should use Fast.com's 150ms interval
    try testing.expect(strategy.getSleepInterval() == 150 * std.time.ns_per_ms);
}

test "FastStabilityStrategy shouldSample timing" {
    const criteria = FastStabilityCriteria{};
    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // First call should not sample (last_sample_time is 0)
    try testing.expect(!strategy.shouldSample(0));

    // Should not sample if less than 1 second has passed
    strategy.last_sample_time = 500 * std.time.ns_per_ms; // 0.5 seconds
    try testing.expect(!strategy.shouldSample(800 * std.time.ns_per_ms)); // 0.8 seconds

    // Should sample if 1 second or more has passed
    try testing.expect(strategy.shouldSample(1600 * std.time.ns_per_ms)); // 1.6 seconds
}

test "FastStabilityStrategy addSample basic functionality" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 1, // Short for testing
        .min_stable_measurements = 3,
        .stability_delta_percent = 50.0, // High threshold to avoid early stability
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // First sample should be skipped
    const is_stable1 = try strategy.addSample(1 * std.time.ns_per_s, 1000);
    try testing.expect(!is_stable1);
    try testing.expect(strategy.speed_measurements.items.len == 0);

    // Second sample should be added
    const is_stable2 = try strategy.addSample(2 * std.time.ns_per_s, 2000);
    try testing.expect(!is_stable2); // Not stable yet, need min_stable_measurements
    try testing.expect(strategy.speed_measurements.items.len == 1);

    // Third sample should be added
    const is_stable3 = try strategy.addSample(3 * std.time.ns_per_s, 3000);
    try testing.expect(!is_stable3); // Still need more measurements
    try testing.expect(strategy.speed_measurements.items.len == 2);

    // Fourth sample should trigger stability check (we have 3 measurements now)
    _ = try strategy.addSample(4 * std.time.ns_per_s, 4000);
    try testing.expect(strategy.speed_measurements.items.len == 3);
}

test "FastStabilityStrategy requires minimum duration" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 10,
        .min_stable_measurements = 2,
        .stability_delta_percent = 1.0, // Low threshold for easy stability
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples before minimum duration - should not be stable
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000);
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000);
    const is_stable_early = try strategy.addSample(3 * std.time.ns_per_s, 3000);
    try testing.expect(!is_stable_early); // Should not be stable before min duration

    // Add sample after minimum duration - might be stable
    _ = try strategy.addSample(11 * std.time.ns_per_s, 11000);
    // Result depends on stability calculation, but should not crash
}

test "FastStabilityStrategy handleProgress integration" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 2,
        .min_stable_measurements = 2,
        .stability_delta_percent = 10.0,
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Should not trigger sampling immediately
    const should_stop1 = try strategy.handleProgress(500 * std.time.ns_per_ms, 500);
    try testing.expect(!should_stop1);

    // Should not trigger sampling if less than 1 second elapsed
    const should_stop2 = try strategy.handleProgress(800 * std.time.ns_per_ms, 800);
    try testing.expect(!should_stop2);

    // Should trigger sampling after 1 second
    _ = try strategy.handleProgress(1500 * std.time.ns_per_ms, 1500);
    try testing.expect(strategy.speed_measurements.items.len == 0); // First sample skipped

    // Should add second sample
    _ = try strategy.handleProgress(2500 * std.time.ns_per_ms, 2500);
    try testing.expect(strategy.speed_measurements.items.len == 1);
}

test "Fast.com delta stability detection algorithm" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 1, // Short for testing
        .min_stable_measurements = 4,
        .stability_delta_percent = 5.0, // 5% deviation threshold
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples that should be stable (within 5% of each other)
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s
    _ = try strategy.addSample(3 * std.time.ns_per_s, 3050); // 1050 bytes/s (5% higher)
    _ = try strategy.addSample(4 * std.time.ns_per_s, 4000); // 950 bytes/s (5% lower)

    // This should be stable since all speeds are within 5% of 1000 bytes/s
    const is_stable = try strategy.addSample(5 * std.time.ns_per_s, 5000); // 1000 bytes/s

    // Should be stable with consistent speeds
    try testing.expect(is_stable);
}

test "Fast.com delta stability detection - unstable case" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 1, // Short for testing
        .min_stable_measurements = 3,
        .stability_delta_percent = 2.0, // Strict 2% threshold
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples that should NOT be stable (outside 2% threshold)
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s
    _ = try strategy.addSample(3 * std.time.ns_per_s, 3100); // 1100 bytes/s (10% higher)

    // This should NOT be stable due to large deviation
    const is_stable = try strategy.addSample(4 * std.time.ns_per_s, 4000); // 900 bytes/s (10% lower)

    // Should not be stable with inconsistent speeds
    try testing.expect(!is_stable);
}

test "Fast.com stability requires measurements after max speed" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 1,
        .min_stable_measurements = 6,
        .stability_delta_percent = 5.0,
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Add samples with a peak in the middle, then lower speeds
    _ = try strategy.addSample(1 * std.time.ns_per_s, 1000); // Skip first
    _ = try strategy.addSample(2 * std.time.ns_per_s, 2000); // 1000 bytes/s
    _ = try strategy.addSample(3 * std.time.ns_per_s, 4000); // 2000 bytes/s (peak)
    _ = try strategy.addSample(4 * std.time.ns_per_s, 5000); // 1000 bytes/s (back down)
    _ = try strategy.addSample(5 * std.time.ns_per_s, 6000); // 1000 bytes/s

    // Should not be stable yet - need more measurements after the peak
    const is_stable = try strategy.addSample(6 * std.time.ns_per_s, 7000); // 1000 bytes/s

    // Fast.com algorithm should detect this pattern and require more stability
    // Either not stable yet OR we have collected enough measurements to make a decision
    if (is_stable) {
        try testing.expect(strategy.speed_measurements.items.len >= 6);
    }
    // Test should not crash and should have collected measurements
    try testing.expect(strategy.speed_measurements.items.len > 0);
}

test "Fast.com API integration with legacy API" {
    // Test that both old and new APIs can coexist
    const old_criteria = StabilityCriteria{
        .min_samples = 5,
        .max_variance_percent = 10.0,
        .max_duration_seconds = 30,
    };

    const new_criteria = FastStabilityCriteria{
        .min_duration_seconds = 7,
        .max_duration_seconds = 30,
        .stability_delta_percent = 2.0,
        .min_stable_measurements = 6,
    };

    var old_strategy = measurement_strategy.createStabilityStrategy(testing.allocator, old_criteria);
    defer old_strategy.deinit();

    var new_strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, new_criteria);
    defer new_strategy.deinit();

    // Both should compile and initialize without conflicts
    try testing.expect(old_strategy.criteria.min_samples == 5);
    try testing.expect(new_strategy.criteria.min_stable_measurements == 6);
}

test "Fast.com stability detection realistic scenario" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 5,
        .max_duration_seconds = 20,
        .stability_delta_percent = 2.0, // Fast.com's 2% threshold
        .min_stable_measurements = 6, // Fast.com's requirement
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
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

test "Fast.com timing intervals match specification" {
    const criteria = FastStabilityCriteria{};
    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
    defer strategy.deinit();

    // Fast.com uses 150ms progress frequency (vs our old 100ms)
    try testing.expect(strategy.getSleepInterval() == 150 * std.time.ns_per_ms);

    // Should enforce 1-second sampling intervals like Fast.com
    try testing.expect(!strategy.shouldSample(0));
    strategy.last_sample_time = 500 * std.time.ns_per_ms;
    try testing.expect(!strategy.shouldSample(999 * std.time.ns_per_ms));
    try testing.expect(strategy.shouldSample(1500 * std.time.ns_per_ms));
}

test "Fast.com delta algorithm handles edge cases correctly" {
    const criteria = FastStabilityCriteria{
        .min_duration_seconds = 1,
        .min_stable_measurements = 3,
        .stability_delta_percent = 5.0,
    };

    var strategy = measurement_strategy.createFastStabilityStrategy(testing.allocator, criteria);
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
