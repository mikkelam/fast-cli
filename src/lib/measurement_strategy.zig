const std = @import("std");

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

pub fn createStabilityStrategy(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
    return StabilityStrategy.init(allocator, criteria);
}
