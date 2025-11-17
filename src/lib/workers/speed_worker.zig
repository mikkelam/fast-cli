const std = @import("std");
const http = std.http;
const print = std.debug.print;

// Interfaces for dependency injection
pub const HttpClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        fetch: *const fn (ptr: *anyopaque, request: FetchRequest) anyerror!FetchResponse,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn fetch(self: HttpClient, request: FetchRequest) !FetchResponse {
        return self.vtable.fetch(self.ptr, request);
    }

    pub fn deinit(self: HttpClient) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const FetchRequest = struct {
    method: http.Method,
    url: []const u8,
    headers: ?[]const Header = null,
    payload: ?[]const u8 = null,

    max_response_size: usize = 2 * 1024 * 1024,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const FetchResponse = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchResponse) void {
        self.allocator.free(self.body);
    }
};

pub const Timer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        read: *const fn (ptr: *anyopaque) u64,
    };

    pub fn read(self: Timer) u64 {
        return self.vtable.read(self.ptr);
    }
};

// Worker configuration
pub const WorkerConfig = struct {
    worker_id: u32,
    url: []const u8,
    chunk_size: usize = 1024 * 1024, // 1MB
    delay_between_requests_ms: u64 = 10,
    max_retries: u32 = 3,
};

// Download worker
pub const DownloadWorker = struct {
    config: WorkerConfig,
    bytes_downloaded: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
    http_client: HttpClient,
    timer: Timer,
    target_duration_ns: u64,
    allocator: std.mem.Allocator,
    error_count: std.atomic.Value(u32),
    // Dynamic chunk sizing
    current_chunk_size: u32,
    min_chunk_size: u32,
    max_chunk_size: u32,

    const Self = @This();
    const MAX_FILE_SIZE: u64 = 26214400; // 25MB - fast.com file size limit
    const MIN_CHUNK_SIZE: u32 = 64 * 1024; // 64KB like fast.com start
    const MAX_CHUNK_SIZE: u32 = 4 * 1024 * 1024; // 4MB max

    pub fn init(
        config: WorkerConfig,
        should_stop: *std.atomic.Value(bool),
        http_client: HttpClient,
        timer: Timer,
        target_duration_ns: u64,
        allocator: std.mem.Allocator,
    ) Self {
        return Self{
            .config = config,
            .bytes_downloaded = std.atomic.Value(u64).init(0),
            .should_stop = should_stop,
            .http_client = http_client,
            .timer = timer,
            .target_duration_ns = target_duration_ns,
            .allocator = allocator,
            .error_count = std.atomic.Value(u32).init(0),
            .current_chunk_size = MIN_CHUNK_SIZE,
            .min_chunk_size = MIN_CHUNK_SIZE,
            .max_chunk_size = MAX_CHUNK_SIZE,
        };
    }

    pub fn run(self: *Self) void {
        self.downloadLoop() catch |err| {
            print("Download worker {} error: {}\n", .{ self.config.worker_id, err });
            _ = self.error_count.fetchAdd(1, .monotonic);
        };
    }

    pub fn downloadLoop(self: *Self) !void {
        var range_start: u64 = 0;
        var retry_count: u32 = 0;

        while (!self.should_stop.load(.monotonic)) {
            // Check if we've exceeded the target duration
            if (self.timer.read() >= self.target_duration_ns) {
                self.should_stop.store(true, .monotonic);
                break;
            }

            // Check if we've exceeded the file size - reset to beginning if so
            if (range_start >= MAX_FILE_SIZE) {
                range_start = 0;
            }

            // Use dynamic chunk size
            const chunk_size = self.current_chunk_size;
            const range_end = @min(range_start + chunk_size - 1, MAX_FILE_SIZE - 1);

            // Convert speedtest URL to range URL
            // From: https://...speedtest?params
            // To:   https://...speedtest/range/start-end?params
            var range_url_buf: [512]u8 = undefined;
            const range_url = if (std.mem.indexOf(u8, self.config.url, "/speedtest?")) |pos| blk: {
                const base_part = self.config.url[0..pos];
                const params_part = self.config.url[pos + 10 ..]; // Skip "/speedtest"
                break :blk std.fmt.bufPrint(&range_url_buf, "{s}/speedtest/range/{d}-{d}{s}", .{ base_part, range_start, range_end, params_part }) catch {
                    print("Worker {} failed to format range URL\n", .{self.config.worker_id});
                    break :blk self.config.url;
                };
            } else blk: {
                // TODO: This is very noisy
                // print("Worker {} URL doesn't contain /speedtest?, using original: {s}\n", .{ self.config.worker_id, self.config.url });
                break :blk self.config.url;
            };

            const request = FetchRequest{
                .method = .GET,
                .url = range_url,
                .headers = &[_]Header{},
                .max_response_size = chunk_size + (16 * 1024), // 16KB buffer for dynamic chunks
            };

            const request_start = self.timer.read();
            var response = self.http_client.fetch(request) catch |err| {
                retry_count += 1;
                if (retry_count >= self.config.max_retries) {
                    print("Worker {} max retries exceeded: {}\n", .{ self.config.worker_id, err });
                    _ = self.error_count.fetchAdd(1, .monotonic);
                    break;
                }
                std.Thread.sleep(std.time.ns_per_ms * 100);
                continue;
            };
            defer response.deinit();

            const request_end = self.timer.read();
            const request_duration_ns = request_end - request_start;

            // Reset retry count on success
            retry_count = 0;

            // Accept both 200 (full content) and 206 (partial content)
            if (response.status != .ok and response.status != .partial_content) {
                print("Worker {} HTTP error: {}\n", .{ self.config.worker_id, response.status });
                std.Thread.sleep(std.time.ns_per_ms * 100);
                continue;
            }

            // Update total bytes downloaded
            _ = self.bytes_downloaded.fetchAdd(response.body.len, .monotonic);

            // Dynamically adjust chunk size based on performance
            self.adjustChunkSize(request_duration_ns, response.body.len);
            range_start += chunk_size;

            // Small delay between requests
            if (self.config.delay_between_requests_ms > 0) {
                std.Thread.sleep(std.time.ns_per_ms * self.config.delay_between_requests_ms);
            }
        }
    }

    /// Dynamically adjust chunk size based on request performance
    /// Similar to Fast.com's adaptive sizing algorithm
    fn adjustChunkSize(self: *Self, request_duration_ns: u64, bytes_downloaded: usize) void {
        const request_duration_ms = request_duration_ns / std.time.ns_per_ms;

        // Target: ~300-1000ms per request like fast.com
        const target_duration_ms = 500;
        const tolerance_ms = 200;

        if (request_duration_ms < target_duration_ms - tolerance_ms) {
            // Request was fast, increase chunk size (but don't exceed max)
            const new_size = @min(self.current_chunk_size * 2, self.max_chunk_size);
            self.current_chunk_size = new_size;
        } else if (request_duration_ms > target_duration_ms + tolerance_ms) {
            // Request was slow, decrease chunk size (but don't go below min)
            const new_size = @max(self.current_chunk_size / 2, self.min_chunk_size);
            self.current_chunk_size = new_size;
        }
        // If within tolerance, keep current size

        _ = bytes_downloaded; // Suppress unused parameter warning
    }

    pub fn getBytesDownloaded(self: *const Self) u64 {
        return self.bytes_downloaded.load(.monotonic);
    }

    pub fn getErrorCount(self: *const Self) u32 {
        return self.error_count.load(.monotonic);
    }
};

// Upload worker
pub const UploadWorker = struct {
    config: WorkerConfig,
    bytes_uploaded: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
    http_client: HttpClient,
    timer: Timer,
    target_duration_ns: u64,
    upload_data: []const u8,
    allocator: std.mem.Allocator,
    error_count: std.atomic.Value(u32),
    // Dynamic upload sizing
    current_upload_size: u32,
    min_upload_size: u32,
    max_upload_size: u32,

    const Self = @This();
    const MIN_UPLOAD_SIZE: u32 = 2048; // 2KB like fast.com
    const MAX_UPLOAD_SIZE: u32 = 4 * 1024 * 1024; // 4MB max

    pub fn init(
        config: WorkerConfig,
        should_stop: *std.atomic.Value(bool),
        http_client: HttpClient,
        timer: Timer,
        target_duration_ns: u64,
        upload_data: []const u8,
        allocator: std.mem.Allocator,
    ) Self {
        return Self{
            .config = config,
            .bytes_uploaded = std.atomic.Value(u64).init(0),
            .should_stop = should_stop,
            .http_client = http_client,
            .timer = timer,
            .target_duration_ns = target_duration_ns,
            .upload_data = upload_data,
            .allocator = allocator,
            .error_count = std.atomic.Value(u32).init(0),
            .current_upload_size = MIN_UPLOAD_SIZE,
            .min_upload_size = MIN_UPLOAD_SIZE,
            .max_upload_size = MAX_UPLOAD_SIZE,
        };
    }

    pub fn run(self: *Self) void {
        self.uploadLoop() catch |err| {
            print("Upload worker {} error: {}\n", .{ self.config.worker_id, err });
            _ = self.error_count.fetchAdd(1, .monotonic);
        };
    }

    pub fn uploadLoop(self: *Self) !void {
        var retry_count: u32 = 0;

        while (!self.should_stop.load(.monotonic)) {
            // Check if we've exceeded the target duration
            if (self.timer.read() >= self.target_duration_ns) {
                self.should_stop.store(true, .monotonic);
                break;
            }

            // Use dynamic upload size
            const upload_size = @min(self.current_upload_size, self.upload_data.len);
            const upload_chunk = self.upload_data[0..upload_size];

            const start_time = self.timer.read();

            const request = FetchRequest{
                .method = .POST,
                .url = self.config.url,
                .payload = upload_chunk,
                .headers = &[_]Header{
                    Header{ .name = "Content-Type", .value = "application/octet-stream" },
                },
                .max_response_size = 1024 * 1024, // 1MB response buffer
            };

            var response = self.http_client.fetch(request) catch |err| {
                retry_count += 1;
                if (retry_count >= self.config.max_retries) {
                    print("Upload worker {} max retries exceeded: {}\n", .{ self.config.worker_id, err });
                    _ = self.error_count.fetchAdd(1, .monotonic);
                    break;
                }
                std.Thread.sleep(std.time.ns_per_ms * 100);
                continue;
            };
            defer response.deinit();

            const end_time = self.timer.read();
            const request_duration_ns = end_time - start_time;

            // Reset retry count on success
            retry_count = 0;

            if (response.status != .ok) {
                print("Upload worker {} HTTP error: {}\n", .{ self.config.worker_id, response.status });
                std.Thread.sleep(std.time.ns_per_ms * 100);
                continue;
            }

            // Update total bytes uploaded
            _ = self.bytes_uploaded.fetchAdd(upload_chunk.len, .monotonic);

            // Dynamically adjust upload size based on performance
            self.adjustUploadSize(request_duration_ns, upload_size);

            // No delay between uploads for maximum throughput
        }
    }

    /// Dynamically adjust upload size based on request performance
    /// Similar to Fast.com's adaptive sizing algorithm
    fn adjustUploadSize(self: *Self, request_duration_ns: u64, bytes_uploaded: u32) void {
        const request_duration_ms = request_duration_ns / std.time.ns_per_ms;

        // Target: ~100-500ms per request for optimal throughput
        const target_duration_ms = 250;
        const tolerance_ms = 100;

        if (request_duration_ms < target_duration_ms - tolerance_ms) {
            // Request was fast, increase upload size (but don't exceed max)
            const new_size = @min(self.current_upload_size * 2, self.max_upload_size);
            self.current_upload_size = new_size;
        } else if (request_duration_ms > target_duration_ms + tolerance_ms) {
            // Request was slow, decrease upload size (but don't go below min)
            const new_size = @max(self.current_upload_size / 2, self.min_upload_size);
            self.current_upload_size = new_size;
        }
        // If within tolerance, keep current size

        _ = bytes_uploaded; // Suppress unused parameter warning
    }

    pub fn getBytesUploaded(self: *const Self) u64 {
        return self.bytes_uploaded.load(.monotonic);
    }

    pub fn getErrorCount(self: *const Self) u32 {
        return self.error_count.load(.monotonic);
    }
};

// Real implementations
pub const RealHttpClient = struct {
    client: http.Client,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .client = http.Client{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn httpClient(self: *Self) HttpClient {
        return HttpClient{
            .ptr = self,
            .vtable = &.{
                .fetch = fetch,
                .deinit = deinit,
            },
        };
    }

    fn fetch(ptr: *anyopaque, request: FetchRequest) !FetchResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var response_body = std.Io.Writer.Allocating.init(self.allocator);
        errdefer response_body.deinit();

        const fetch_options = http.Client.FetchOptions{
            .method = request.method,
            .location = .{ .url = request.url },
            .payload = if (request.payload) |p| p else null,
            .response_writer = &response_body.writer,
        };

        const result = try self.client.fetch(fetch_options);

        return FetchResponse{
            .status = result.status,
            .body = try response_body.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.client.deinit();
    }
};

pub const RealTimer = struct {
    timer: std.time.Timer,

    const Self = @This();

    pub fn init() !Self {
        return Self{
            .timer = try std.time.Timer.start(),
        };
    }

    pub fn timer_interface(self: *Self) Timer {
        return Timer{
            .ptr = self,
            .vtable = &.{
                .read = read,
            },
        };
    }

    fn read(ptr: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.timer.read();
    }
};

// Mock implementations for testing
pub const MockHttpClient = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayList(FetchResponse),
    request_count: std.atomic.Value(u32),
    should_fail: bool = false,
    delay_ms: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .responses = std.ArrayList(FetchResponse).empty,
            .request_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.responses.items) |*response| {
            self.allocator.free(response.body);
        }
        self.responses.deinit(self.allocator);
    }

    pub fn addResponse(self: *Self, status: http.Status, body: []const u8) !void {
        const body_copy = try self.allocator.dupe(u8, body);
        try self.responses.append(self.allocator, FetchResponse{
            .status = status,
            .body = body_copy,
            .allocator = self.allocator,
        });
    }

    pub fn httpClient(self: *Self) HttpClient {
        return HttpClient{
            .ptr = self,
            .vtable = &.{
                .fetch = fetch,
                .deinit = mockDeinit,
            },
        };
    }

    fn fetch(ptr: *anyopaque, request: FetchRequest) !FetchResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = request;

        if (self.delay_ms > 0) {
            std.Thread.sleep(std.time.ns_per_ms * self.delay_ms);
        }

        if (self.should_fail) {
            return error.MockError;
        }

        const count = self.request_count.fetchAdd(1, .monotonic);
        const response_index = count % @as(u32, @intCast(self.responses.items.len));

        if (response_index >= self.responses.items.len) {
            return error.NoMoreResponses;
        }

        const response = self.responses.items[response_index];
        const body_copy = try self.allocator.dupe(u8, response.body);

        return FetchResponse{
            .status = response.status,
            .body = body_copy,
            .allocator = self.allocator,
        };
    }

    fn mockDeinit(ptr: *anyopaque) void {
        _ = ptr; // Mock doesn't need to do anything
    }

    pub fn getRequestCount(self: *const Self) u32 {
        return self.request_count.load(.monotonic);
    }
};

pub const MockTimer = struct {
    current_time: std.atomic.Value(u64),

    const Self = @This();

    pub fn init() Self {
        return Self{
            .current_time = std.atomic.Value(u64).init(0),
        };
    }

    pub fn timer_interface(self: *Self) Timer {
        return Timer{
            .ptr = self,
            .vtable = &.{
                .read = read,
            },
        };
    }

    pub fn setTime(self: *Self, time_ns: u64) void {
        self.current_time.store(time_ns, .monotonic);
    }

    pub fn advance(self: *Self, duration_ns: u64) void {
        _ = self.current_time.fetchAdd(duration_ns, .monotonic);
    }

    fn read(ptr: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.current_time.load(.monotonic);
    }
};

// Tests
const testing = std.testing;

test "DownloadWorker basic functionality" {
    const allocator = testing.allocator;

    var mock_client = MockHttpClient.init(allocator);
    defer mock_client.deinit();

    // Add mock responses
    try mock_client.addResponse(.partial_content, "A" ** 1024); // 1KB response
    try mock_client.addResponse(.partial_content, "B" ** 1024);

    var mock_timer = MockTimer.init();
    var should_stop = std.atomic.Value(bool).init(false);

    const config = WorkerConfig{
        .worker_id = 1,
        .url = "https://example.com/test",
        .chunk_size = 1024,
        .delay_between_requests_ms = 0,
    };

    var worker = DownloadWorker.init(
        config,
        &should_stop,
        mock_client.httpClient(),
        mock_timer.timer_interface(),
        std.time.ns_per_s * 2, // 2 second target
        allocator,
    );

    // Simulate time progression
    mock_timer.setTime(0);

    // Start worker in a separate thread
    const thread = try std.Thread.spawn(.{}, DownloadWorker.run, .{&worker});

    // Let it run for a bit
    std.Thread.sleep(std.time.ns_per_ms * 100);

    // Advance timer to trigger stop
    mock_timer.setTime(std.time.ns_per_s * 3); // 3 seconds

    thread.join();

    // Verify results
    try testing.expect(worker.getBytesDownloaded() > 0);
    try testing.expect(mock_client.getRequestCount() > 0);
    try testing.expect(worker.getErrorCount() == 0);
}

test "DownloadWorker handles errors gracefully" {
    const allocator = testing.allocator;

    var mock_client = MockHttpClient.init(allocator);
    defer mock_client.deinit();

    mock_client.should_fail = true;

    var mock_timer = MockTimer.init();
    var should_stop = std.atomic.Value(bool).init(false);

    const config = WorkerConfig{
        .worker_id = 1,
        .url = "https://example.com/test",
        .max_retries = 2,
    };

    var worker = DownloadWorker.init(
        config,
        &should_stop,
        mock_client.httpClient(),
        mock_timer.timer_interface(),
        std.time.ns_per_s, // 1 second target
        allocator,
    );

    // Run worker
    worker.run();

    // Should have some errors due to mock failure
    try testing.expect(worker.getErrorCount() > 0);
    try testing.expect(worker.getBytesDownloaded() == 0);
}

test "MockTimer functionality" {
    var timer = MockTimer.init();
    var timer_interface = timer.timer_interface();

    try testing.expectEqual(@as(u64, 0), timer_interface.read());

    timer.setTime(1000);
    try testing.expectEqual(@as(u64, 1000), timer_interface.read());

    timer.advance(500);
    try testing.expectEqual(@as(u64, 1500), timer_interface.read());
}
