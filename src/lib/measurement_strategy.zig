const std = @import("std");

pub const StabilityCriteria = struct {
    min_duration_seconds: u32 = 7,
    max_duration_seconds: u32 = 30,
    progress_frequency_ms: u64 = 150,
    moving_average_window_size: u32 = 5,
    stability_delta_percent: f64 = 2.0,
    min_stable_measurements: u32 = 6,
    connections_min: u32 = 1,
    connections_max: u32 = 8,
    max_bytes_in_flight: u64 = 78_643_200,
};

pub const ProgressSnapshot = struct {
    bytes: u64,
    time_ms: u64,
};

pub const ProgressMeasurement = struct {
    speed_bits_per_sec: f64,
};

pub const EstimationPhase = enum {
    ramp,
    steady,
};

pub const StabilityDecision = struct {
    should_stop: bool,
    desired_connections: u32,
    phase: EstimationPhase,
    display_speed_bits_per_sec: f64,
    authoritative_speed_bits_per_sec: f64,
    speed_bits_per_sec: f64,
    sampled: bool = false,
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

const StableMovingAverage = struct {
    window_size: usize,
    snapshot_reset_threshold: usize = 5,
    start_index: usize = 0,
    current_speed_bytes_per_ms: f64 = 0,
    fixed_start_index: bool = false,
    last_len: usize = 0,
    bytes_sum: u64 = 0,
    time_sum_ms: u64 = 0,

    fn init(window_size: usize) StableMovingAverage {
        return .{ .window_size = @max(window_size, 1) };
    }

    fn reset(self: *StableMovingAverage) void {
        self.start_index = 0;
        self.current_speed_bytes_per_ms = 0;
        self.fixed_start_index = false;
        self.last_len = 0;
        self.bytes_sum = 0;
        self.time_sum_ms = 0;
    }

    fn compute(self: *StableMovingAverage, snapshots: []const ProgressSnapshot) f64 {
        if (snapshots.len < self.snapshot_reset_threshold or snapshots.len < self.last_len) {
            self.reset();
        }
        self.last_len = snapshots.len;

        if (!self.fixed_start_index and snapshots.len > 0) {
            var sum_bytes: u64 = 0;
            var sum_time_ms: u64 = 0;

            const end = if (snapshots.len > self.window_size) snapshots.len - self.window_size else 0;
            var i = snapshots.len;
            while (i > end) {
                i -= 1;
                sum_bytes += snapshots[i].bytes;
                sum_time_ms += snapshots[i].time_ms;
            }

            const candidate_speed = if (sum_time_ms > 0)
                @as(f64, @floatFromInt(sum_bytes)) / @as(f64, @floatFromInt(sum_time_ms))
            else
                0;

            if (candidate_speed >= self.current_speed_bytes_per_ms) {
                self.start_index = snapshots.len;
                self.current_speed_bytes_per_ms = candidate_speed;
                self.bytes_sum = sum_bytes;
                self.time_sum_ms = sum_time_ms;
            } else {
                self.fixed_start_index = true;
            }
        }

        var j = self.start_index;
        while (j < snapshots.len) : (j += 1) {
            self.bytes_sum += snapshots[j].bytes;
            self.time_sum_ms += snapshots[j].time_ms;
        }
        self.start_index = snapshots.len;

        if (self.time_sum_ms == 0) return 0;
        return 1000.0 * @as(f64, @floatFromInt(self.bytes_sum)) * 8.0 / @as(f64, @floatFromInt(self.time_sum_ms));
    }
};

const StableDeltaStopper = struct {
    min_duration_ns: u64,
    max_duration_ns: u64,
    stability_delta_percent: f64,
    min_stable_measurements: usize,

    fn init(criteria: StabilityCriteria) StableDeltaStopper {
        return .{
            .min_duration_ns = @as(u64, criteria.min_duration_seconds) * std.time.ns_per_s,
            .max_duration_ns = @as(u64, criteria.max_duration_seconds) * std.time.ns_per_s,
            .stability_delta_percent = criteria.stability_delta_percent,
            .min_stable_measurements = @max(criteria.min_stable_measurements, 1),
        };
    }

    fn shouldStop(self: *const StableDeltaStopper, test_time_ns: u64, measurements: []const ProgressMeasurement, current_speed_bits_per_sec: f64) bool {
        if (test_time_ns >= self.max_duration_ns) return true;
        if (test_time_ns < self.min_duration_ns) return false;
        if (measurements.len < self.min_stable_measurements) return false;

        const half_window = (self.min_stable_measurements + 1) / 2;
        const max_index = lastWindowMaxIndex(measurements, half_window);
        if (measurements.len - max_index < half_window) return false;

        const start = measurements.len - self.min_stable_measurements;
        const delta = maxDeltaPercent(current_speed_bits_per_sec, measurements[start..]);
        return delta <= self.stability_delta_percent;
    }
};

fn lastWindowMaxIndex(measurements: []const ProgressMeasurement, window_size: usize) usize {
    if (measurements.len == 0) return 0;

    const start = if (measurements.len > window_size) measurements.len - window_size else 0;
    var max_index = start;
    var max_speed: f64 = 0;

    var i = measurements.len;
    while (i > start) {
        i -= 1;
        const speed = measurements[i].speed_bits_per_sec;
        if (speed >= max_speed) {
            max_speed = speed;
            max_index = i;
        }
    }

    return max_index;
}

fn maxDeltaPercent(reference_speed: f64, measurements: []const ProgressMeasurement) f64 {
    if (measurements.len == 0) return 100;
    if (reference_speed <= 0) return 100;

    var max_delta: f64 = 0;
    for (measurements) |measurement| {
        const delta = 100.0 * @abs(measurement.speed_bits_per_sec - reference_speed) / reference_speed;
        if (delta > max_delta) max_delta = delta;
    }
    return max_delta;
}

fn desiredConnections(criteria: StabilityCriteria, speed_bits_per_sec: f64) u32 {
    const max_connections = @max(criteria.connections_max, criteria.connections_min);

    const desired = if (speed_bits_per_sec >= 50_000_000)
        max_connections
    else if (speed_bits_per_sec >= 10_000_000)
        @min(max_connections, 5)
    else if (speed_bits_per_sec >= 1_000_000)
        @min(max_connections, 3)
    else if (speed_bits_per_sec >= 500_000)
        @min(max_connections, 2)
    else
        criteria.connections_min;

    return @max(desired, criteria.connections_min);
}

pub const StabilityStrategy = struct {
    criteria: StabilityCriteria,
    min_duration_ns: u64,
    max_duration_ns: u64,
    ramp_min_duration_ns: u64,
    measurement_interval_ns: u64,
    snapshots: std.ArrayList(ProgressSnapshot),
    progress_measurements: std.ArrayList(ProgressMeasurement),
    moving_average: StableMovingAverage,
    stopper: StableDeltaStopper,
    last_sample_time_ns: u64 = 0,
    last_total_bytes: u64 = 0,
    phase: EstimationPhase = .ramp,
    provisional_speed_bits_per_sec: f64 = 0,
    authoritative_speed_bits_per_sec: f64 = 0,
    steady_total_bytes: u64 = 0,
    steady_total_time_ns: u64 = 0,
    ramp_max_desired_connections: u32 = 1,
    ramp_ticks_without_increase: u32 = 0,
    locked_connections: u32 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
        const min_duration_ns = @as(u64, criteria.min_duration_seconds) * std.time.ns_per_s;
        const max_duration_ns = @as(u64, criteria.max_duration_seconds) * std.time.ns_per_s;
        const ramp_min_duration_ns = @min(2 * std.time.ns_per_s, min_duration_ns);
        const min_connections = @max(criteria.connections_min, 1);

        return .{
            .criteria = criteria,
            .min_duration_ns = min_duration_ns,
            .max_duration_ns = max_duration_ns,
            .ramp_min_duration_ns = @min(ramp_min_duration_ns, max_duration_ns),
            .measurement_interval_ns = criteria.progress_frequency_ms * std.time.ns_per_ms,
            .snapshots = std.ArrayList(ProgressSnapshot).empty,
            .progress_measurements = std.ArrayList(ProgressMeasurement).empty,
            .moving_average = StableMovingAverage.init(criteria.moving_average_window_size),
            .stopper = StableDeltaStopper.init(criteria),
            .ramp_max_desired_connections = min_connections,
            .locked_connections = min_connections,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StabilityStrategy) void {
        self.snapshots.deinit(self.allocator);
        self.progress_measurements.deinit(self.allocator);
    }

    pub fn shouldContinue(self: StabilityStrategy, current_time_ns: u64) bool {
        return current_time_ns < self.max_duration_ns;
    }

    pub fn getSleepInterval(self: StabilityStrategy) u64 {
        return self.measurement_interval_ns;
    }

    pub fn getCurrentSpeedBitsPerSec(self: StabilityStrategy) f64 {
        return if (self.phase == .steady and self.authoritative_speed_bits_per_sec > 0)
            self.authoritative_speed_bits_per_sec
        else
            self.provisional_speed_bits_per_sec;
    }

    fn updateRampState(self: *StabilityStrategy, desired_connections: u32) void {
        if (desired_connections > self.ramp_max_desired_connections) {
            self.ramp_max_desired_connections = desired_connections;
            self.ramp_ticks_without_increase = 0;
        } else {
            self.ramp_ticks_without_increase += 1;
        }
    }

    fn shouldEnterSteadyPhase(self: *const StabilityStrategy, current_time_ns: u64) bool {
        const ramp_lock_ticks_required: u32 = 3;
        if (self.ramp_ticks_without_increase < ramp_lock_ticks_required) return false;

        const max_connections = @max(self.criteria.connections_max, self.criteria.connections_min);
        const ramp_reached_max = self.ramp_max_desired_connections >= max_connections;
        const ramp_time_elapsed = current_time_ns >= self.ramp_min_duration_ns;
        return ramp_reached_max or ramp_time_elapsed;
    }

    fn updateSteadyEstimator(self: *StabilityStrategy, bytes_diff: u64, elapsed_ns: u64) void {
        self.steady_total_bytes += bytes_diff;
        self.steady_total_time_ns += elapsed_ns;
        if (self.steady_total_time_ns == 0) return;

        const duration_s = @as(f64, @floatFromInt(self.steady_total_time_ns)) / std.time.ns_per_s;
        if (duration_s == 0) return;
        self.authoritative_speed_bits_per_sec = @as(f64, @floatFromInt(self.steady_total_bytes)) * 8.0 / duration_s;
    }

    pub fn handleProgress(self: *StabilityStrategy, current_time_ns: u64, current_total_bytes: u64) !StabilityDecision {
        const initial_display_speed = self.getCurrentSpeedBitsPerSec();
        const initial_desired = if (self.phase == .steady) self.locked_connections else @max(self.criteria.connections_min, 1);
        var decision = StabilityDecision{
            .should_stop = false,
            .desired_connections = initial_desired,
            .phase = self.phase,
            .display_speed_bits_per_sec = initial_display_speed,
            .authoritative_speed_bits_per_sec = initial_display_speed,
            .speed_bits_per_sec = initial_display_speed,
            .sampled = false,
        };

        if (self.last_sample_time_ns == 0) {
            self.last_sample_time_ns = current_time_ns;
            self.last_total_bytes = current_total_bytes;
            decision.desired_connections = self.criteria.connections_min;
            return decision;
        }

        if (current_time_ns <= self.last_sample_time_ns) {
            return decision;
        }

        const elapsed_ns = current_time_ns - self.last_sample_time_ns;
        if (elapsed_ns < self.measurement_interval_ns) {
            return decision;
        }

        const bytes_diff = if (current_total_bytes >= self.last_total_bytes)
            current_total_bytes - self.last_total_bytes
        else
            0;

        const time_ms = @max(elapsed_ns / std.time.ns_per_ms, 1);

        try self.snapshots.append(self.allocator, .{
            .bytes = bytes_diff,
            .time_ms = time_ms,
        });

        self.provisional_speed_bits_per_sec = self.moving_average.compute(self.snapshots.items);
        const provisional_desired = desiredConnections(self.criteria, self.provisional_speed_bits_per_sec);

        if (self.phase == .ramp) {
            self.updateRampState(provisional_desired);
            if (self.shouldEnterSteadyPhase(current_time_ns)) {
                self.phase = .steady;
                self.locked_connections = self.ramp_max_desired_connections;
                self.steady_total_bytes = 0;
                self.steady_total_time_ns = 0;
                self.authoritative_speed_bits_per_sec = 0;
            }
        }

        if (self.phase == .steady) {
            self.updateSteadyEstimator(bytes_diff, elapsed_ns);
            try self.progress_measurements.append(self.allocator, .{
                .speed_bits_per_sec = self.authoritative_speed_bits_per_sec,
            });
        }

        const display_speed = if (self.phase == .steady and self.authoritative_speed_bits_per_sec > 0)
            self.authoritative_speed_bits_per_sec
        else
            self.provisional_speed_bits_per_sec;
        const authoritative_speed = if (self.authoritative_speed_bits_per_sec > 0)
            self.authoritative_speed_bits_per_sec
        else
            self.provisional_speed_bits_per_sec;
        const desired_connections = if (self.phase == .steady) self.locked_connections else provisional_desired;

        decision.phase = self.phase;
        decision.display_speed_bits_per_sec = display_speed;
        decision.authoritative_speed_bits_per_sec = authoritative_speed;
        decision.speed_bits_per_sec = display_speed;
        decision.desired_connections = desired_connections;
        decision.should_stop = self.stopper.shouldStop(
            current_time_ns,
            self.progress_measurements.items,
            authoritative_speed,
        );
        decision.sampled = true;

        self.last_sample_time_ns = current_time_ns;
        self.last_total_bytes = current_total_bytes;

        return decision;
    }

    pub fn finalSpeedBitsPerSecond(self: *const StabilityStrategy, total_bytes: u64, duration_ns: u64) f64 {
        if (self.authoritative_speed_bits_per_sec > 0) {
            return self.authoritative_speed_bits_per_sec;
        }
        if (self.provisional_speed_bits_per_sec > 0) {
            return self.provisional_speed_bits_per_sec;
        }
        if (duration_ns == 0) return 0;
        const duration_s = @as(f64, @floatFromInt(duration_ns)) / std.time.ns_per_s;
        if (duration_s == 0) return 0;
        return @as(f64, @floatFromInt(total_bytes)) * 8.0 / duration_s;
    }
};

pub fn createDurationStrategy(duration_seconds: u32, progress_update_interval_ms: u64) DurationStrategy {
    return .{
        .target_duration_ns = @as(u64, duration_seconds) * std.time.ns_per_s,
        .progress_update_interval_ms = progress_update_interval_ms,
    };
}

pub fn createStabilityStrategy(allocator: std.mem.Allocator, criteria: StabilityCriteria) StabilityStrategy {
    return StabilityStrategy.init(allocator, criteria);
}
