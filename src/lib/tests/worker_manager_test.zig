const std = @import("std");
const testing = std.testing;
const WorkerManager = @import("../workers/worker_manager.zig").WorkerManager;
const worker_manager = @import("../workers/worker_manager.zig");
const speed_worker = @import("../workers/speed_worker.zig");

test "calculateWorkerCount with more URLs than connections" {
    const urls = [_][]const u8{ "url1", "url2", "url3", "url4", "url5" };
    const concurrent_connections = 3;

    const result = worker_manager.calculateWorkerCount(&urls, concurrent_connections);
    try testing.expect(result == 3);
}

test "calculateWorkerCount with fewer URLs than connections" {
    const urls = [_][]const u8{ "url1", "url2" };
    const concurrent_connections = 5;

    const result = worker_manager.calculateWorkerCount(&urls, concurrent_connections);
    try testing.expect(result == 2);
}

test "calculateWorkerCount with equal URLs and connections" {
    const urls = [_][]const u8{ "url1", "url2", "url3" };
    const concurrent_connections = 3;

    const result = worker_manager.calculateWorkerCount(&urls, concurrent_connections);
    try testing.expect(result == 3);
}

test "calculateWorkerCount with zero connections" {
    const urls = [_][]const u8{ "url1", "url2" };
    const concurrent_connections = 0;

    const result = worker_manager.calculateWorkerCount(&urls, concurrent_connections);
    try testing.expect(result == 0);
}

test "calculateWorkerCount with empty URLs" {
    const urls: []const []const u8 = &[_][]const u8{};
    const concurrent_connections = 5;

    const result = worker_manager.calculateWorkerCount(urls, concurrent_connections);
    try testing.expect(result == 0);
}

test "createWorkerConfigs basic functionality" {
    const urls = [_][]const u8{ "url1", "url2", "url3" };
    const num_workers = 2;

    const configs = try worker_manager.createWorkerConfigs(testing.allocator, &urls, num_workers, false);
    defer testing.allocator.free(configs);

    try testing.expect(configs.len == 2);

    // Check worker ID assignment
    try testing.expect(configs[0].worker_id == 0);
    try testing.expect(configs[1].worker_id == 1);

    // Check URL assignment
    try testing.expect(std.mem.eql(u8, configs[0].url, "url1"));
    try testing.expect(std.mem.eql(u8, configs[1].url, "url2"));
}

test "createWorkerConfigs URL cycling behavior" {
    const urls = [_][]const u8{ "url1", "url2" };
    const num_workers = 5; // More workers than URLs

    const configs = try worker_manager.createWorkerConfigs(testing.allocator, &urls, num_workers, true);
    defer testing.allocator.free(configs);

    try testing.expect(configs.len == 5);

    // Check URL cycling
    try testing.expect(std.mem.eql(u8, configs[0].url, "url1"));
    try testing.expect(std.mem.eql(u8, configs[1].url, "url2"));
    try testing.expect(std.mem.eql(u8, configs[2].url, "url1")); // Cycles back
    try testing.expect(std.mem.eql(u8, configs[3].url, "url2"));
    try testing.expect(std.mem.eql(u8, configs[4].url, "url1"));

    // Check sequential worker IDs
    for (configs, 0..) |config, i| {
        try testing.expect(config.worker_id == @as(u32, @intCast(i)));
    }
}

test "createWorkerConfigs with zero workers" {
    const urls = [_][]const u8{ "url1", "url2" };
    const num_workers = 0;

    const configs = try worker_manager.createWorkerConfigs(testing.allocator, &urls, num_workers, false);
    defer testing.allocator.free(configs);

    try testing.expect(configs.len == 0);
}

test "WorkerManager basic initialization and cleanup" {
    var should_stop = std.atomic.Value(bool).init(false);
    var manager = try WorkerManager.init(testing.allocator, &should_stop, 3);
    defer manager.deinit();

    try testing.expect(manager.http_clients.len == 3);
    try testing.expect(manager.threads.len == 3);
    try testing.expect(manager.clients_initialized == false);
}

test "WorkerManager initialization with zero workers" {
    var should_stop = std.atomic.Value(bool).init(false);
    var manager = try WorkerManager.init(testing.allocator, &should_stop, 0);
    defer manager.deinit();

    try testing.expect(manager.http_clients.len == 0);
    try testing.expect(manager.threads.len == 0);
    try testing.expect(manager.clients_initialized == false);
}

test "WorkerManager calculate totals with empty workers" {
    var should_stop = std.atomic.Value(bool).init(false);
    var manager = try WorkerManager.init(testing.allocator, &should_stop, 0);
    defer manager.deinit();

    // Test with empty download workers
    const download_workers: []speed_worker.DownloadWorker = &[_]speed_worker.DownloadWorker{};
    const download_totals = manager.calculateDownloadTotals(download_workers);
    try testing.expect(download_totals.bytes == 0);
    try testing.expect(download_totals.errors == 0);

    // Test with empty upload workers
    const upload_workers: []speed_worker.UploadWorker = &[_]speed_worker.UploadWorker{};
    const upload_totals = manager.calculateUploadTotals(upload_workers);
    try testing.expect(upload_totals.bytes == 0);
    try testing.expect(upload_totals.errors == 0);
}

test "WorkerManager current bytes with empty workers" {
    var should_stop = std.atomic.Value(bool).init(false);
    var manager = try WorkerManager.init(testing.allocator, &should_stop, 0);
    defer manager.deinit();

    // Test with empty download workers
    const download_workers: []speed_worker.DownloadWorker = &[_]speed_worker.DownloadWorker{};
    const download_bytes = manager.getCurrentDownloadBytes(download_workers);
    try testing.expect(download_bytes == 0);

    // Test with empty upload workers
    const upload_workers: []speed_worker.UploadWorker = &[_]speed_worker.UploadWorker{};
    const upload_bytes = manager.getCurrentUploadBytes(upload_workers);
    try testing.expect(upload_bytes == 0);
}

test "WorkerManager clients_initialized flag behavior" {
    var should_stop = std.atomic.Value(bool).init(false);
    var manager = try WorkerManager.init(testing.allocator, &should_stop, 2);
    defer manager.deinit();

    // Should start as false
    try testing.expect(manager.clients_initialized == false);

    // The flag would be set to true by setupDownloadWorkers or setupUploadWorkers
    // but we don't test those here since they involve HTTP client initialization
}
