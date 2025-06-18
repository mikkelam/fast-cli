const std = @import("std");
const speed_worker = @import("speed_worker.zig");

// Pure logic functions - easily testable
pub fn calculateWorkerCount(urls: []const []const u8, concurrent_connections: usize) usize {
    return @min(urls.len, concurrent_connections);
}

pub fn createWorkerConfigs(allocator: std.mem.Allocator, urls: []const []const u8, num_workers: usize, is_upload: bool) ![]speed_worker.WorkerConfig {
    const configs = try allocator.alloc(speed_worker.WorkerConfig, num_workers);

    for (configs, 0..) |*config, i| {
        config.* = speed_worker.WorkerConfig{
            .worker_id = @intCast(i),
            .url = urls[i % urls.len],
            .chunk_size = if (is_upload) 0 else 1024 * 1024, // 1MB chunks for download
            .delay_between_requests_ms = 0,
            .max_retries = 3,
        };
    }

    return configs;
}

pub const WorkerManager = struct {
    allocator: std.mem.Allocator,
    should_stop: *std.atomic.Value(bool),
    http_clients: []speed_worker.RealHttpClient,
    threads: []std.Thread,
    clients_initialized: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, should_stop: *std.atomic.Value(bool), num_workers: usize) !Self {
        const http_clients = try allocator.alloc(speed_worker.RealHttpClient, num_workers);
        errdefer allocator.free(http_clients);

        const threads = try allocator.alloc(std.Thread, num_workers);
        errdefer allocator.free(threads);

        return Self{
            .allocator = allocator,
            .should_stop = should_stop,
            .http_clients = http_clients,
            .threads = threads,
            .clients_initialized = false,
        };
    }

    pub fn deinit(self: *Self) void {
        // Only cleanup HTTP clients if they were initialized
        if (self.clients_initialized) {
            for (self.http_clients) |*client| {
                client.httpClient().deinit();
            }
        }

        self.allocator.free(self.http_clients);
        self.allocator.free(self.threads);
    }

    pub fn setupDownloadWorkers(
        self: *Self,
        urls: []const []const u8,
        concurrent_connections: usize,
        timer_interface: speed_worker.Timer,
        target_duration: u64,
    ) ![]speed_worker.DownloadWorker {
        const num_workers = calculateWorkerCount(urls, concurrent_connections);
        std.debug.assert(num_workers == self.http_clients.len);

        const workers = try self.allocator.alloc(speed_worker.DownloadWorker, num_workers);
        const configs = try createWorkerConfigs(self.allocator, urls, num_workers, false);
        defer self.allocator.free(configs);

        // Initialize HTTP clients and workers
        for (workers, configs, 0..) |*worker, config, i| {
            self.http_clients[i] = speed_worker.RealHttpClient.init(self.allocator);

            worker.* = speed_worker.DownloadWorker.init(
                config,
                self.should_stop,
                self.http_clients[i].httpClient(),
                timer_interface,
                target_duration,
                self.allocator,
            );
        }

        self.clients_initialized = true;
        return workers;
    }

    pub fn setupUploadWorkers(
        self: *Self,
        urls: []const []const u8,
        concurrent_connections: usize,
        timer_interface: speed_worker.Timer,
        target_duration: u64,
        upload_data: []const u8,
    ) ![]speed_worker.UploadWorker {
        const num_workers = calculateWorkerCount(urls, concurrent_connections);
        std.debug.assert(num_workers == self.http_clients.len);

        const workers = try self.allocator.alloc(speed_worker.UploadWorker, num_workers);
        const configs = try createWorkerConfigs(self.allocator, urls, num_workers, true);
        defer self.allocator.free(configs);

        // Initialize HTTP clients and workers
        for (workers, configs, 0..) |*worker, config, i| {
            self.http_clients[i] = speed_worker.RealHttpClient.init(self.allocator);

            worker.* = speed_worker.UploadWorker.init(
                config,
                self.should_stop,
                self.http_clients[i].httpClient(),
                timer_interface,
                target_duration,
                upload_data,
                self.allocator,
            );
        }

        self.clients_initialized = true;
        return workers;
    }

    pub fn startDownloadWorkers(self: *Self, workers: []speed_worker.DownloadWorker) !void {
        for (workers, 0..) |*worker, i| {
            self.threads[i] = try std.Thread.spawn(.{}, speed_worker.DownloadWorker.run, .{worker});
        }
    }

    pub fn startUploadWorkers(self: *Self, workers: []speed_worker.UploadWorker) !void {
        for (workers, 0..) |*worker, i| {
            self.threads[i] = try std.Thread.spawn(.{}, speed_worker.UploadWorker.run, .{worker});
        }
    }

    pub fn stopAndJoinWorkers(self: *Self) void {
        // Signal all workers to stop
        self.should_stop.store(true, .monotonic);

        // Wait for all threads to complete
        for (self.threads) |*thread| {
            thread.join();
        }
    }

    pub fn calculateDownloadTotals(_: *Self, workers: []speed_worker.DownloadWorker) struct { bytes: u64, errors: u32 } {
        var total_bytes: u64 = 0;
        var total_errors: u32 = 0;

        for (workers) |*worker| {
            total_bytes += worker.getBytesDownloaded();
            total_errors += worker.getErrorCount();
        }

        return .{ .bytes = total_bytes, .errors = total_errors };
    }

    pub fn calculateUploadTotals(_: *Self, workers: []speed_worker.UploadWorker) struct { bytes: u64, errors: u32 } {
        var total_bytes: u64 = 0;
        var total_errors: u32 = 0;

        for (workers) |*worker| {
            total_bytes += worker.getBytesUploaded();
            total_errors += worker.getErrorCount();
        }

        return .{ .bytes = total_bytes, .errors = total_errors };
    }

    pub fn getCurrentDownloadBytes(_: *Self, workers: []speed_worker.DownloadWorker) u64 {
        var current_total_bytes: u64 = 0;
        for (workers) |*worker| {
            current_total_bytes += worker.getBytesDownloaded();
        }
        return current_total_bytes;
    }

    pub fn getCurrentUploadBytes(_: *Self, workers: []speed_worker.UploadWorker) u64 {
        var current_total_bytes: u64 = 0;
        for (workers) |*worker| {
            current_total_bytes += worker.getBytesUploaded();
        }
        return current_total_bytes;
    }

    pub fn cleanupWorkers(self: *Self, workers: anytype) void {
        self.allocator.free(workers);
    }
};
