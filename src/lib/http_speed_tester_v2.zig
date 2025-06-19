const std = @import("std");
const speed_worker = @import("workers/speed_worker.zig");
const BandwidthMeter = @import("bandwidth.zig").BandwidthMeter;
const SpeedMeasurement = @import("bandwidth.zig").SpeedMeasurement;
const SpeedUnit = @import("bandwidth.zig").SpeedUnit;
const WorkerManager = @import("workers/worker_manager.zig").WorkerManager;
const measurement_strategy = @import("measurement_strategy.zig");
const DurationStrategy = measurement_strategy.DurationStrategy;
const StabilityStrategy = measurement_strategy.StabilityStrategy;
pub const StabilityCriteria = measurement_strategy.StabilityCriteria;

const print = std.debug.print;

pub const SpeedTestResult = struct {
    speed: SpeedMeasurement,

    /// Convert bytes per second to optimal unit for display (in bits per second)
    pub fn fromBytesPerSecond(speed_bytes_per_sec: f64) SpeedTestResult {
        // Convert bytes/s to bits/s
        const speed_bits_per_sec = speed_bytes_per_sec * 8.0;
        const abs_speed = @abs(speed_bits_per_sec);

        const speed_measurement = if (abs_speed >= 1_000_000_000)
            SpeedMeasurement{ .value = speed_bits_per_sec / 1_000_000_000, .unit = .gbps }
        else if (abs_speed >= 1_000_000)
            SpeedMeasurement{ .value = speed_bits_per_sec / 1_000_000, .unit = .mbps }
        else if (abs_speed >= 1_000)
            SpeedMeasurement{ .value = speed_bits_per_sec / 1_000, .unit = .kbps }
        else
            SpeedMeasurement{ .value = speed_bits_per_sec, .unit = .bps };

        return SpeedTestResult{ .speed = speed_measurement };
    }
};

pub const HTTPSpeedTester = struct {
    allocator: std.mem.Allocator,
    concurrent_connections: u32,
    progress_update_interval_ms: u32,

    pub fn init(allocator: std.mem.Allocator) HTTPSpeedTester {
        return HTTPSpeedTester{
            .allocator = allocator,
            .concurrent_connections = 8, // Default 8 concurrent connections
            .progress_update_interval_ms = 100, // Default 100ms updates
        };
    }

    pub fn deinit(self: *HTTPSpeedTester) void {
        _ = self;
    }

    pub fn set_concurrent_connections(self: *HTTPSpeedTester, count: u32) void {
        self.concurrent_connections = @min(count, 8); // Max 8 connections
    }

    pub fn set_progress_update_interval_ms(self: *HTTPSpeedTester, interval_ms: u32) void {
        self.progress_update_interval_ms = interval_ms;
    }

    // Clean duration-based download with optional progress callback
    pub fn measure_download_speed_duration(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        const strategy = measurement_strategy.createDurationStrategy(duration_seconds, self.progress_update_interval_ms);
        return self.measureDownloadSpeedWithDuration(urls, strategy, ProgressType, progress_callback);
    }

    // Clean stability-based download
    pub fn measure_download_speed_stability(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria) !SpeedTestResult {
        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureDownloadSpeedWithStability(urls, &strategy);
    }

    // Clean duration-based upload with optional progress callback
    pub fn measure_upload_speed_duration(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, comptime ProgressType: ?type, progress_callback: if (ProgressType) |T| T else void) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        const strategy = measurement_strategy.createDurationStrategy(duration_seconds, self.progress_update_interval_ms);
        return self.measureUploadSpeedWithDuration(urls, strategy, upload_data, ProgressType, progress_callback);
    }

    // Clean stability-based upload
    pub fn measure_upload_speed_stability(self: *HTTPSpeedTester, urls: []const []const u8, criteria: StabilityCriteria) !SpeedTestResult {
        const upload_data = try self.allocator.alloc(u8, 4 * 1024 * 1024);
        defer self.allocator.free(upload_data);
        @memset(upload_data, 'A');

        var strategy = measurement_strategy.createStabilityStrategy(self.allocator, criteria);
        defer strategy.deinit();
        return self.measureUploadSpeedWithStability(urls, &strategy, upload_data);
    }

    // Convenience helpers for cleaner API usage

    /// Simple download speed measurement without progress callback
    pub fn measureDownloadSpeed(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32) !SpeedTestResult {
        return self.measure_download_speed_duration(urls, duration_seconds, null, {});
    }

    /// Download speed measurement with progress callback (type inferred)
    pub fn measureDownloadSpeedWithProgress(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, progress_callback: anytype) !SpeedTestResult {
        return self.measure_download_speed_duration(urls, duration_seconds, @TypeOf(progress_callback), progress_callback);
    }

    /// Simple upload speed measurement without progress callback
    pub fn measureUploadSpeed(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32) !SpeedTestResult {
        return self.measure_upload_speed_duration(urls, duration_seconds, null, {});
    }

    /// Upload speed measurement with progress callback (type inferred)
    pub fn measureUploadSpeedWithProgress(self: *HTTPSpeedTester, urls: []const []const u8, duration_seconds: u32, progress_callback: anytype) !SpeedTestResult {
        return self.measure_upload_speed_duration(urls, duration_seconds, @TypeOf(progress_callback), progress_callback);
    }

    // Private implementation for duration-based download
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

        // Initialize bandwidth meter for progress tracking
        var bandwidth_meter = BandwidthMeter.init();
        if (has_progress) {
            try bandwidth_meter.start();
        }

        // Setup worker manager
        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        // Setup download workers
        const workers = try worker_manager.setupDownloadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.target_duration_ns,
        );
        defer worker_manager.cleanupWorkers(workers);

        // Start workers
        try worker_manager.startDownloadWorkers(workers);

        // Main measurement loop
        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.time.sleep(strategy.getSleepInterval());

            if (has_progress) {
                const current_bytes = worker_manager.getCurrentDownloadBytes(workers);
                bandwidth_meter.update_total(current_bytes);
                const measurement = bandwidth_meter.bandwidthWithUnits();
                progress_callback.call(measurement);
            }
        }

        // Stop and wait for workers
        worker_manager.stopAndJoinWorkers();

        // Calculate results
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

    // Private implementation for stability-based download
    fn measureDownloadSpeedWithStability(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: *StabilityStrategy,
    ) !SpeedTestResult {
        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);

        // Setup worker manager
        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        // Setup download workers
        const workers = try worker_manager.setupDownloadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.max_duration_ns,
        );
        defer worker_manager.cleanupWorkers(workers);

        // Start workers
        try worker_manager.startDownloadWorkers(workers);

        // Main measurement loop
        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.time.sleep(strategy.getSleepInterval());

            const current_bytes = worker_manager.getCurrentDownloadBytes(workers);
            const should_stop_early = try strategy.handleProgress(
                timer.timer_interface().read(),
                current_bytes,
            );

            if (should_stop_early) break;
        }

        // Stop and wait for workers
        worker_manager.stopAndJoinWorkers();

        // Calculate results
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

    // Private implementation for duration-based upload
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

        // Initialize bandwidth meter for progress tracking
        var bandwidth_meter = BandwidthMeter.init();
        if (has_progress) {
            try bandwidth_meter.start();
        }

        // Setup worker manager
        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        // Setup upload workers
        const workers = try worker_manager.setupUploadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.target_duration_ns,
            upload_data,
        );
        defer worker_manager.cleanupWorkers(workers);

        // Start workers
        try worker_manager.startUploadWorkers(workers);

        // Main measurement loop
        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.time.sleep(strategy.getSleepInterval());

            if (has_progress) {
                const current_bytes = worker_manager.getCurrentUploadBytes(workers);
                bandwidth_meter.update_total(current_bytes);
                const measurement = bandwidth_meter.bandwidthWithUnits();
                progress_callback.call(measurement);
            }
        }

        // Stop and wait for workers
        worker_manager.stopAndJoinWorkers();

        // Calculate results
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

    // Private implementation for stability-based upload
    fn measureUploadSpeedWithStability(
        self: *HTTPSpeedTester,
        urls: []const []const u8,
        strategy: *StabilityStrategy,
        upload_data: []const u8,
    ) !SpeedTestResult {
        var timer = try speed_worker.RealTimer.init();
        var should_stop = std.atomic.Value(bool).init(false);

        // Setup worker manager
        const num_workers = @min(urls.len, self.concurrent_connections);
        var worker_manager = try WorkerManager.init(self.allocator, &should_stop, num_workers);
        defer worker_manager.deinit();

        // Setup upload workers
        const workers = try worker_manager.setupUploadWorkers(
            urls,
            self.concurrent_connections,
            timer.timer_interface(),
            strategy.max_duration_ns,
            upload_data,
        );
        defer worker_manager.cleanupWorkers(workers);

        // Start workers
        try worker_manager.startUploadWorkers(workers);

        // Main measurement loop
        while (strategy.shouldContinue(timer.timer_interface().read())) {
            std.time.sleep(strategy.getSleepInterval());

            const current_bytes = worker_manager.getCurrentUploadBytes(workers);
            const should_stop_early = try strategy.handleProgress(
                timer.timer_interface().read(),
                current_bytes,
            );

            if (should_stop_early) break;
        }

        // Stop and wait for workers
        worker_manager.stopAndJoinWorkers();

        // Calculate results
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
};
