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
