const std = @import("std");
const speed_worker = @import("workers/speed_worker.zig");
const BandwidthMeter = @import("bandwidth.zig").BandwidthMeter;
const SpeedMeasurement = @import("bandwidth.zig").SpeedMeasurement;
const WorkerManager = @import("workers/worker_manager.zig").WorkerManager;
const measurement_strategy = @import("measurement_strategy.zig");
const DurationStrategy = measurement_strategy.DurationStrategy;
const StabilityStrategy = measurement_strategy.StabilityStrategy;
pub const StabilityCriteria = measurement_strategy.StabilityCriteria;

const print = std.debug.print;

pub const SpeedTestResult = struct {
    speed: SpeedMeasurement,

    pub fn fromBytesPerSecond(bytes_per_second: f64) SpeedTestResult {
        return fromBitsPerSecond(bytes_per_second * 8.0);
    }

    pub fn fromBitsPerSecond(bits_per_second: f64) SpeedTestResult {
        return SpeedTestResult{ .speed = speedMeasurementFromBitsPerSecond(bits_per_second) };
    }
};

pub const TraceSample = struct {
    t_ms: u64,
    total_bytes: u64,
};

pub const TraceCapture = struct {
    samples: std.ArrayList(TraceSample),
    stop_at_ms: u64 = 0,
    stable: bool = false,
    final_speed_bits_per_sec: f64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TraceCapture {
        return .{
            .samples = std.ArrayList(TraceSample).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraceCapture) void {
        self.samples.deinit(self.allocator);
    }

    pub fn speedMbps(self: TraceCapture) f64 {
        return self.final_speed_bits_per_sec / 1_000_000;
    }
};

fn speedMeasurementFromBitsPerSecond(bits_per_second: f64) SpeedMeasurement {
    const abs_speed = @abs(bits_per_second);

    if (abs_speed >= 1_000_000_000) {
        return SpeedMeasurement{ .value = bits_per_second / 1_000_000_000, .unit = .gbps };
    }
    if (abs_speed >= 1_000_000) {
        return SpeedMeasurement{ .value = bits_per_second / 1_000_000, .unit = .mbps };
    }
    if (abs_speed >= 1_000) {
        return SpeedMeasurement{ .value = bits_per_second / 1_000, .unit = .kbps };
    }
    return SpeedMeasurement{ .value = bits_per_second, .unit = .bps };
}

pub const HTTPSpeedTester = struct {
    allocator: std.mem.Allocator,
    concurrent_connections: u32,
    progress_update_interval_ms: u32,

    pub fn init(allocator: std.mem.Allocator) HTTPSpeedTester {
        return .{
            .allocator = allocator,
            .concurrent_connections = 8,
            .progress_update_interval_ms = 100,
        };
    }

    pub fn deinit(self: *HTTPSpeedTester) void {
        _ = self;
    }

    pub fn measure_download_speed_stability_duration(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureDownloadSpeedWithStability(urls, &strategy, null, ProgressType, progress_callback);
    }

    pub fn measure_download_speed_stability(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria) !SpeedTestResult {
        return self.measure_download_speed_stability_duration(urls, criteria, null, {});
    }

    pub fn measure_upload_speed_stability_duration(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureUploadSpeedWithStability(urls, &strategy, upload_data, null, ProgressType, progress_callback);
    }

    pub fn measure_upload_speed_stability(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria) !SpeedTestResult {
        return self.measure_upload_speed_stability_duration(urls, criteria, null, {});
    }

    pub fn measure_download_speed_duration(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        const strategy = measurement_strategy.createDurationStrategy(duration_seconds, self.progress_update_interval_ms);
        return self.measureDownloadSpeedWithDuration(urls, strategy, ProgressType, progress_callback);
    }

    pub fn measureDownloadSpeed(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32) !SpeedTestResult {
        return self.measure_download_speed_duration(urls, duration_seconds, null, {});
    }

    pub fn measure_upload_speed_duration(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        const strategy = measurement_strategy.createDurationStrategy(duration_seconds, self.progress_update_interval_ms);
        return self.measureUploadSpeedWithDuration(urls, strategy, upload_data, ProgressType, progress_callback);
    }

    pub fn measureUploadSpeed(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32) !SpeedTestResult {
        return self.measure_upload_speed_duration(urls, duration_seconds, null, {});
    }

    pub fn measureDownloadSpeedWithStabilityProgress(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, progress_callback: anytype) !SpeedTestResult {
        return self.measure_download_speed_stability_duration(urls, criteria, @TypeOf(progress_callback), progress_callback);
    }

    pub fn measureUploadSpeedWithStabilityProgress(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, progress_callback: anytype) !SpeedTestResult {
        return self.measure_upload_speed_stability_duration(urls, criteria, @TypeOf(progress_callback), progress_callback);
    }

    pub fn measure_download_speed_stability_with_trace(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, trace_capture: *TraceCapture) !SpeedTestResult {
        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureDownloadSpeedWithStability(urls, &strategy, trace_capture, null, {});
    }

    pub fn measure_upload_speed_stability_with_trace(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, trace_capture: *TraceCapture) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureUploadSpeedWithStability(urls, &strategy, upload_data, trace_capture, null, {});
    }

    pub fn measureDownloadSpeedWithStabilityProgressTrace(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, trace_capture: *TraceCapture, progress_callback: anytype) !SpeedTestResult {
        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureDownloadSpeedWithStability(urls, &strategy, trace_capture, @TypeOf(progress_callback), progress_callback);
    }

    pub fn measureUploadSpeedWithStabilityProgressTrace(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria, trace_capture: *TraceCapture, progress_callback: anytype) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureUploadSpeedWithStability(urls, &strategy, upload_data, trace_capture, @TypeOf(progress_callback), progress_callback);
    }

    fn measureDownloadSpeedWithDuration(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: DurationStrategy,
        comptime ProgressType: ?type,
        progress_callback: if (ProgressType) |T| T else void,
    ) !SpeedTestResult {
        const has_progress = ProgressType != null;

        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);

        var bandwidth_meter = BandwidthMeter.init();
        if (has_progress) {
            try bandwidth_meter.start();
        }

        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        const workers = try worker_manager.setupDownloadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.target_duration_ns,
        );
        defer worker_manager.cleanupWorkers(workers);

        try worker_manager.startDownloadWorkers(workers);

        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.Thread.sleep(strategy.getSleepInterval());

            if (has_progress) {
                const current_bytes = worker_manager.getCurrentDownloadBytes(workers);
                bandwidth_meter.update_total(current_bytes);
                const measurement = bandwidth_meter.bandwidthWithUnits();
                progress_callback.call(measurement);
            }
        }

        worker_manager.stopAndJoinWorkers();

        const totals = worker_manager.calculateDownloadTotals(workers);
        if (totals.errors > 0) {
            print("Download completed with {} errors\n", .{totals.errors});
        }

        const actual_duration_ns = timer.timer_interface().read();
        const actual_duration_s = @as(f64, @floatFromInt(actual_duration_ns)) / std.time.ns_per_s;

        if (actual_duration_s == 0) return SpeedTestResult.fromBytesPerSecond(0);
        const speed_bytes_per_sec = @as(f64, @floatFromInt(totals.bytes)) / actual_duration_s;
        return SpeedTestResult.fromBytesPerSecond(speed_bytes_per_sec);
    }

    fn measureUploadSpeedWithDuration(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: DurationStrategy,
        upload_data: []const u8,
        comptime ProgressType: ?type,
        progress_callback: if (ProgressType) |T| T else void,
    ) !SpeedTestResult {
        const has_progress = ProgressType != null;

        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);

        var bandwidth_meter = BandwidthMeter.init();
        if (has_progress) {
            try bandwidth_meter.start();
        }

        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        const workers = try worker_manager.setupUploadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.target_duration_ns,
            upload_data,
        );
        defer worker_manager.cleanupWorkers(workers);

        try worker_manager.startUploadWorkers(workers);

        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.Thread.sleep(strategy.getSleepInterval());

            if (has_progress) {
                const current_bytes = worker_manager.getCurrentUploadBytes(workers);
                bandwidth_meter.update_total(current_bytes);
                const measurement = bandwidth_meter.bandwidthWithUnits();
                progress_callback.call(measurement);
            }
        }

        worker_manager.stopAndJoinWorkers();

        const totals = worker_manager.calculateUploadTotals(workers);
        if (totals.errors > 0) {
            print("Upload completed with {} errors\n", .{totals.errors});
        }

        const actual_duration_ns = timer.timer_interface().read();
        const actual_duration_s = @as(f64, @floatFromInt(actual_duration_ns)) / std.time.ns_per_s;

        if (actual_duration_s == 0) return SpeedTestResult.fromBytesPerSecond(0);
        const speed_bytes_per_sec = @as(f64, @floatFromInt(totals.bytes)) / actual_duration_s;
        return SpeedTestResult.fromBytesPerSecond(speed_bytes_per_sec);
    }

    fn effectiveMaxWorkers(self: *HTTPSpeedTester, urls_len: usize, criteria: StabilityCriteria) usize {
        if (urls_len == 0) return 0;
        const criteria_max: usize = @intCast(@max(criteria.connections_max, 1));
        const configured_max: usize = @intCast(@max(self.concurrent_connections, 1));
        return @min(urls_len, @min(criteria_max, configured_max));
    }

    fn initialActiveWorkers(max_workers: usize, criteria: StabilityCriteria) u32 {
        if (max_workers == 0) return 0;
        const min_connections = @max(criteria.connections_min, 1);
        return @intCast(@min(max_workers, min_connections));
    }

    fn applyConnectionRamp(active_worker_count: *std.atomic.Value(u32), desired: u32, max_workers: usize) void {
        if (max_workers == 0) return;
        const max_workers_u32: u32 = @intCast(max_workers);
        const bounded = @max(1, @min(desired, max_workers_u32));
        const current = active_worker_count.load(.monotonic);
        if (bounded > current) {
            active_worker_count.store(bounded, .monotonic);
        }
    }

    fn measureDownloadSpeedWithStability(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: *StabilityStrategy,
        trace_capture: ?*TraceCapture,
        comptime ProgressType: ?type,
        progress_callback: if (ProgressType) |T| T else void,
    ) !SpeedTestResult {
        const has_progress = ProgressType != null;
        if (urls.len == 0) return SpeedTestResult.fromBitsPerSecond(0);

        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);
        var last_emitted_progress_speed_bits_per_sec: ?f64 = null;

        const max_workers = self.effectiveMaxWorkers(urls.len, strategy.criteria);
        var active_worker_count = std.atomic.Value(u32).init(initialActiveWorkers(max_workers, strategy.criteria));

        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, max_workers);
        defer worker_manager.deinit();

        const workers = try worker_manager.setupDownloadWorkersWithControl(
            urls,
            max_workers,
            timer.timer_interface(),
            strategy.max_duration_ns,
            &active_worker_count,
            strategy.criteria.max_bytes_in_flight,
        );
        defer worker_manager.cleanupWorkers(workers);

        try worker_manager.startDownloadWorkers(workers);

        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.Thread.sleep(strategy.getSleepInterval());

            const current_time_ns = timer.timer_interface().read();
            const current_bytes = worker_manager.getCurrentDownloadBytes(workers);
            const decision = try strategy.handleProgress(current_time_ns, current_bytes);

            applyConnectionRamp(&active_worker_count, decision.desired_connections, max_workers);

            if (trace_capture) |trace| {
                if (decision.sampled) {
                    try trace.samples.append(trace.allocator, .{
                        .t_ms = current_time_ns / std.time.ns_per_ms,
                        .total_bytes = current_bytes,
                    });
                }
            }

            if (has_progress) {
                progress_callback.call(speedMeasurementFromBitsPerSecond(decision.display_speed_bits_per_sec));
                last_emitted_progress_speed_bits_per_sec = decision.display_speed_bits_per_sec;
            }

            if (decision.should_stop) {
                if (trace_capture) |trace| {
                    trace.stop_at_ms = current_time_ns / std.time.ns_per_ms;
                    trace.stable = current_time_ns < strategy.max_duration_ns;
                }
                break;
            }
        }

        worker_manager.stopAndJoinWorkers();

        const totals = worker_manager.calculateDownloadTotals(workers);
        if (totals.errors > 0) {
            print("Download completed with {} errors\n", .{totals.errors});
        }

        const actual_duration_ns = timer.timer_interface().read();
        const speed_bits_per_sec = if (has_progress and last_emitted_progress_speed_bits_per_sec != null)
            last_emitted_progress_speed_bits_per_sec.?
        else
            strategy.finalSpeedBitsPerSecond(totals.bytes, actual_duration_ns);

        if (trace_capture) |trace| {
            if (trace.stop_at_ms == 0) {
                trace.stop_at_ms = actual_duration_ns / std.time.ns_per_ms;
                trace.stable = false;
            }
            trace.final_speed_bits_per_sec = speed_bits_per_sec;
        }

        return SpeedTestResult.fromBitsPerSecond(speed_bits_per_sec);
    }

    fn measureUploadSpeedWithStability(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: *StabilityStrategy,
        upload_data: []const u8,
        trace_capture: ?*TraceCapture,
        comptime ProgressType: ?type,
        progress_callback: if (ProgressType) |T| T else void,
    ) !SpeedTestResult {
        const has_progress = ProgressType != null;
        if (urls.len == 0) return SpeedTestResult.fromBitsPerSecond(0);

        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);
        var last_emitted_progress_speed_bits_per_sec: ?f64 = null;

        const max_workers = self.effectiveMaxWorkers(urls.len, strategy.criteria);
        var active_worker_count = std.atomic.Value(u32).init(initialActiveWorkers(max_workers, strategy.criteria));

        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, max_workers);
        defer worker_manager.deinit();

        const workers = try worker_manager.setupUploadWorkersWithControl(
            urls,
            max_workers,
            timer.timer_interface(),
            strategy.max_duration_ns,
            upload_data,
            &active_worker_count,
            strategy.criteria.max_bytes_in_flight,
        );
        defer worker_manager.cleanupWorkers(workers);

        try worker_manager.startUploadWorkers(workers);

        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.Thread.sleep(strategy.getSleepInterval());

            const current_time_ns = timer.timer_interface().read();
            const current_bytes = worker_manager.getCurrentUploadBytes(workers);
            const decision = try strategy.handleProgress(current_time_ns, current_bytes);

            applyConnectionRamp(&active_worker_count, decision.desired_connections, max_workers);

            if (trace_capture) |trace| {
                if (decision.sampled) {
                    try trace.samples.append(trace.allocator, .{
                        .t_ms = current_time_ns / std.time.ns_per_ms,
                        .total_bytes = current_bytes,
                    });
                }
            }

            if (has_progress) {
                progress_callback.call(speedMeasurementFromBitsPerSecond(decision.display_speed_bits_per_sec));
                last_emitted_progress_speed_bits_per_sec = decision.display_speed_bits_per_sec;
            }

            if (decision.should_stop) {
                if (trace_capture) |trace| {
                    trace.stop_at_ms = current_time_ns / std.time.ns_per_ms;
                    trace.stable = current_time_ns < strategy.max_duration_ns;
                }
                break;
            }
        }

        worker_manager.stopAndJoinWorkers();

        const totals = worker_manager.calculateUploadTotals(workers);
        if (totals.errors > 0) {
            print("Upload completed with {} errors\n", .{totals.errors});
        }

        const actual_duration_ns = timer.timer_interface().read();
        const speed_bits_per_sec = if (has_progress and last_emitted_progress_speed_bits_per_sec != null)
            last_emitted_progress_speed_bits_per_sec.?
        else
            strategy.finalSpeedBitsPerSecond(totals.bytes, actual_duration_ns);

        if (trace_capture) |trace| {
            if (trace.stop_at_ms == 0) {
                trace.stop_at_ms = actual_duration_ns / std.time.ns_per_ms;
                trace.stable = false;
            }
            trace.final_speed_bits_per_sec = speed_bits_per_sec;
        }

        return SpeedTestResult.fromBitsPerSecond(speed_bits_per_sec);
    }
};
