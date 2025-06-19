const std = @import("std");

pub const FastStabilityCriteria = struct {
    min_duration_seconds: u32 = 7,
    max_duration_seconds: u32 = 30,
    stability_delta_percent: f64 = 5.0,
    min_stable_measurements: u32 = 6,
};

// Keep old struct for backward compatibility during transition
pub const StabilityCriteria = struct {
    min_samples: u32,
    max_variance_percent: f64,
    max_duration_seconds: u32,
};

pub const DurationStrategy = struct {
    target_duration_ns: u64,
    progress_update_interval_ms: u64,

    pub fn shouldContinue(self: DurationStrategy, current_time: u64) bool {
        return current_time < self.target_duration_ns;
    }

    pub fn getSleepInterval(self: DurationStrategy) u64 {
        return std.time.ns_per_ms * self.progress_update_interval_ms;
    }
};

pub const FastStabilityStrategy = struct {
    criteria: FastStabilityCriteria,
    min_duration_ns: u64,
    max_duration_ns: u64,
    speed_measurements: std.ArrayList(SpeedMeasurement),
    last_sample_time: u64 = 0,
    last_total_bytes: u64 = 0,

    const SpeedMeasurement = struct {
        speed: f64,
        time: u64,
    };

    pub fn init(allocator: std.mem.Allocator, criteria: FastStabilityCriteria) FastStabilityStrategy {
        return FastStabilityStrategy{
            .criteria = criteria,
            .min_duration_ns = @as(u64, criteria.min_duration_seconds) * std.time.ns_per_s,
            .max_duration_ns = @as(u64, criteria.max_duration_seconds) * std.time.ns_per_s,
            .speed_measurements = std.ArrayList(SpeedMeasurement).init(allocator),
        };
    }

    pub fn deinit(self: *FastStabilityStrategy) void {
        self.speed_measurements.deinit();
    }

    pub fn shouldContinue(self: FastStabilityStrategy, current_time: u64) bool {
        return current_time < self.max_duration_ns;
    }

    pub fn getSleepInterval(self: FastStabilityStrategy) u64 {
        _ = self;
        return std.time.ns_per_ms * 150; // Fast.com uses 150ms
    }

    pub fn shouldSample(self: *FastStabilityStrategy, current_time: u64) bool {
        return current_time - self.last_sample_time >= std.time.ns_per_s;
    }

    pub fn addSample(self: *FastStabilityStrategy, current_time: u64, current_total_bytes: u64) !bool {
        // Skip first sample
        if (self.last_sample_time > 0) {
            const bytes_diff = current_total_bytes - self.last_total_bytes;
            const time_diff_s = @as(f64, @floatFromInt(current_time - self.last_sample_time)) / std.time.ns_per_s;
            const current_speed = @as(f64, @floatFromInt(bytes_diff)) / time_diff_s;

            try self.speed_measurements.append(SpeedMeasurement{
                .speed = current_speed,
                .time = current_time,
            });

            // Apply Fast.com stability logic
            if (current_time >= self.min_duration_ns) {
                if (self.speed_measurements.items.len >= self.criteria.min_stable_measurements) {
                    if (isFastStable(
                        self.speed_measurements.items,
                        current_speed,
                        self.criteria.stability_delta_percent,
                        self.criteria.min_stable_measurements,
                    )) {
                        return true; // Stable, can stop
                    }
                }
            }
        }

        self.last_sample_time = current_time;
        self.last_total_bytes = current_total_bytes;
        return false; // Not stable yet
    }

    pub fn handleProgress(self: *FastStabilityStrategy, current_time: u64, current_bytes: u64) !bool {
        if (self.shouldSample(current_time)) {
            return try self.addSample(current_time, current_bytes);
        }
        return false;
    }
};

// Keep old strategy for backward compatibility
pub const StabilityStrategy = struct {
    criteria: StabilityCriteria,
    max_duration_ns: u64,
    speed_samples: std.ArrayList(f64),
    last_sample_time: u64 = 0,
    last_total_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
        return StabilityStrategy{
            .criteria = criteria,
            .max_duration_ns = @as(u64, criteria.max_duration_seconds) * std.time.ns_per_s,
            .speed_samples = std.ArrayList(f64).init(allocator),
        };
    }

    pub fn deinit(self: *StabilityStrategy) void {
        self.speed_samples.deinit();
    }

    pub fn shouldContinue(self: StabilityStrategy, current_time: u64) bool {
        return current_time < self.max_duration_ns;
    }

    pub fn getSleepInterval(self: StabilityStrategy) u64 {
        _ = self;
        return std.time.ns_per_ms * 100; // 100ms for stability sampling
    }

    pub fn shouldSample(self: *StabilityStrategy, current_time: u64) bool {
        return current_time - self.last_sample_time >= std.time.ns_per_s;
    }

    pub fn addSample(self: *StabilityStrategy, current_time: u64, current_total_bytes: u64) !bool {
        // Skip first sample
        if (self.last_sample_time > 0) {
            const bytes_diff = current_total_bytes - self.last_total_bytes;
            const time_diff_s = @as(f64, @floatFromInt(current_time - self.last_sample_time)) / std.time.ns_per_s;
            const current_speed = @as(f64, @floatFromInt(bytes_diff)) / time_diff_s;

            try self.speed_samples.append(current_speed);

            // Check stability if we have enough samples
            if (self.speed_samples.items.len >= self.criteria.min_samples) {
                if (isStable(self.speed_samples.items, self.criteria.max_variance_percent)) {
                    return true; // Stable, can stop
                }
            }
        }

        self.last_sample_time = current_time;
        self.last_total_bytes = current_total_bytes;
        return false; // Not stable yet
    }

    pub fn handleProgress(self: *StabilityStrategy, current_time: u64, current_bytes: u64) !bool {
        if (self.shouldSample(current_time)) {
            return try self.addSample(current_time, current_bytes);
        }
        return false;
    }
};

/// Simplified stability detection using recent measurements
fn isFastStable(
    measurements: []const FastStabilityStrategy.SpeedMeasurement,
    current_speed: f64,
    stability_delta_percent: f64,
    min_stable_measurements: u32,
) bool {
    if (measurements.len < min_stable_measurements) return false;
    if (current_speed == 0) return false;

    // Check if recent measurements are within delta threshold
    const window_size = @min(measurements.len, min_stable_measurements);
    const recent_start = measurements.len - window_size;

    // Calculate average of recent measurements
    var speed_sum: f64 = 0;
    for (measurements[recent_start..]) |measurement| {
        speed_sum += measurement.speed;
    }
    const avg_speed = speed_sum / @as(f64, @floatFromInt(window_size));

    // Check if all recent measurements are within threshold of average
    for (measurements[recent_start..]) |measurement| {
        const deviation_percent = @abs(measurement.speed - avg_speed) / avg_speed * 100.0;
        if (deviation_percent > stability_delta_percent) {
            return false;
        }
    }

    return true;
}

/// Legacy variance-based stability detection (for backward compatibility)
fn isStable(samples: []const f64, max_variance_percent: f64) bool {
    if (samples.len < 2) return false;

    // Calculate mean
    var sum: f64 = 0;
    for (samples) |sample| {
        sum += sample;
    }
    const mean = sum / @as(f64, @floatFromInt(samples.len));

    if (mean == 0) return false;

    // Calculate variance
    var variance: f64 = 0;
    for (samples) |sample| {
        const diff = sample - mean;
        variance += diff * diff;
    }
    variance = variance / @as(f64, @floatFromInt(samples.len));

    // Calculate coefficient of variation (standard deviation / mean)
    const std_dev = @sqrt(variance);
    const cv_percent = (std_dev / mean) * 100.0;

    return cv_percent <= max_variance_percent;
}

// Clean helper functions
pub fn createDurationStrategy(duration_seconds: u32, progress_update_interval_ms: u64) DurationStrategy {
    return DurationStrategy{
        .target_duration_ns = @as(u64, duration_seconds) * std.time.ns_per_s,
        .progress_update_interval_ms = progress_update_interval_ms,
    };
}

pub fn createFastStabilityStrategy(allocator: std.mem.Allocator, criteria: FastStabilityCriteria) FastStabilityStrategy {
    return FastStabilityStrategy.init(allocator, criteria);
}

pub fn createStabilityStrategy(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
    return StabilityStrategy.init(allocator, criteria);
}
