const std = @import("std");

pub const StabilityCriteria = struct {
    ramp_up_duration_seconds: u32 = 4,
    max_duration_seconds: u32 = 25,
    measurement_interval_ms: u64 = 750,
    sliding_window_size: u32 = 6,
    stability_threshold_cov: f64 = 0.15,
    stable_checks_required: u32 = 2,
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

pub const StabilityStrategy = struct {
    criteria: StabilityCriteria,
    ramp_up_duration_ns: u64,
    max_duration_ns: u64,
    measurement_interval_ns: u64,
    speed_measurements: std.ArrayList(f64), // Sliding window of recent speeds
    last_sample_time: u64 = 0,
    last_total_bytes: u64 = 0,
    consecutive_stable_checks: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
        return StabilityStrategy{
            .criteria = criteria,
            .ramp_up_duration_ns = @as(u64, criteria.ramp_up_duration_seconds) * std.time.ns_per_s,
            .max_duration_ns = @as(u64, criteria.max_duration_seconds) * std.time.ns_per_s,
            .measurement_interval_ns = criteria.measurement_interval_ms * std.time.ns_per_ms,
            .speed_measurements = std.ArrayList(f64).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StabilityStrategy) void {
        self.speed_measurements.deinit(self.allocator);
    }

    pub fn shouldContinue(self: StabilityStrategy, current_time: u64) bool {
        return current_time < self.max_duration_ns;
    }

    pub fn getSleepInterval(self: StabilityStrategy) u64 {
        return self.measurement_interval_ns / 3; // Sample more frequently than measurement interval
    }

    pub fn shouldSample(self: *StabilityStrategy, current_time: u64) bool {
        return current_time - self.last_sample_time >= self.measurement_interval_ns;
    }

    pub fn addSample(self: *StabilityStrategy, current_time: u64, current_total_bytes: u64) !bool {
        // Skip first sample to calculate speed
        if (self.last_sample_time > 0) {
            const bytes_diff = current_total_bytes - self.last_total_bytes;
            const time_diff_ns = current_time - self.last_sample_time;
            const time_diff_s = @as(f64, @floatFromInt(time_diff_ns)) / std.time.ns_per_s;

            const interval_speed = @as(f64, @floatFromInt(bytes_diff)) / time_diff_s;

            // Phase 1: Ramp-up - collect measurements but don't check stability
            if (current_time < self.ramp_up_duration_ns) {
                try self.speed_measurements.append(self.allocator, interval_speed);

                // Keep sliding window size
                if (self.speed_measurements.items.len > self.criteria.sliding_window_size) {
                    _ = self.speed_measurements.orderedRemove(0);
                }
            } else {
                // Phase 2: Stabilization - check CoV for stability
                try self.speed_measurements.append(self.allocator, interval_speed);

                // Maintain sliding window
                if (self.speed_measurements.items.len > self.criteria.sliding_window_size) {
                    _ = self.speed_measurements.orderedRemove(0);
                }

                // Check stability if we have enough measurements
                if (self.speed_measurements.items.len >= self.criteria.sliding_window_size) {
                    const cov = calculateCoV(self.speed_measurements.items);

                    if (cov <= self.criteria.stability_threshold_cov) {
                        self.consecutive_stable_checks += 1;
                        if (self.consecutive_stable_checks >= self.criteria.stable_checks_required) {
                            return true; // Stable, can stop
                        }
                    } else {
                        self.consecutive_stable_checks = 0; // Reset counter
                    }
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

/// Calculate Coefficient of Variation (standard deviation / mean) for stability detection
fn calculateCoV(speeds: []const f64) f64 {
    if (speeds.len < 2) return 1.0; // Not enough data, assume unstable

    // Calculate mean
    var sum: f64 = 0;
    for (speeds) |speed| {
        sum += speed;
    }
    const mean = sum / @as(f64, @floatFromInt(speeds.len));

    if (mean == 0) return 1.0; // Avoid division by zero

    // Calculate variance
    var variance: f64 = 0;
    for (speeds) |speed| {
        const diff = speed - mean;
        variance += diff * diff;
    }
    variance = variance / @as(f64, @floatFromInt(speeds.len));

    // Calculate CoV (coefficient of variation)
    const std_dev = @sqrt(variance);
    return std_dev / mean;
}

// Clean helper functions
pub fn createDurationStrategy(duration_seconds: u32, progress_update_interval_ms: u64) DurationStrategy {
    return DurationStrategy{
        .target_duration_ns = @as(u64, duration_seconds) * std.time.ns_per_s,
        .progress_update_interval_ms = progress_update_interval_ms,
    };
}

pub fn createStabilityStrategy(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
    return StabilityStrategy.init(allocator, criteria);
}
