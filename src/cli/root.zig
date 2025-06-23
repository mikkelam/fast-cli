const std = @import("std");
const zli = @import("zli");
const builtin = @import("builtin");

const Fast = @import("../lib/fast.zig").Fast;
const HTTPSpeedTester = @import("../lib/http_speed_tester_v2.zig").HTTPSpeedTester;

const StabilityCriteria = @import("../lib/http_speed_tester_v2.zig").StabilityCriteria;
const SpeedTestResult = @import("../lib/http_speed_tester_v2.zig").SpeedTestResult;
const BandwidthMeter = @import("../lib/bandwidth.zig");
const SpeedMeasurement = @import("../lib/bandwidth.zig").SpeedMeasurement;
const progress = @import("../lib/progress.zig");
const HttpLatencyTester = @import("../lib/http_latency_tester.zig").HttpLatencyTester;
const log = std.log.scoped(.cli);

const https_flag = zli.Flag{
    .name = "https",
    .description = "Use https when connecting to fast.com",
    .type = .Bool,
    .default_value = .{ .Bool = true },
};

const check_upload_flag = zli.Flag{
    .name = "upload",
    .description = "Check upload speed as well",
    .shortcut = "u",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

const json_output_flag = zli.Flag{
    .name = "json",
    .description = "Output results in JSON format",
    .shortcut = "j",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

const max_duration_flag = zli.Flag{
    .name = "duration",
    .description = "Maximum test duration in seconds (uses CoV stability detection by default)",
    .shortcut = "d",
    .type = .Int,
    .default_value = .{ .Int = 30 },
};

pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = "fast-cli",
        .description = "Estimate connection speed using fast.com",
        .version = null,
    }, run);

    try root.addFlag(https_flag);
    try root.addFlag(check_upload_flag);
    try root.addFlag(json_output_flag);
    try root.addFlag(max_duration_flag);

    return root;
}

fn run(ctx: zli.CommandContext) !void {
    const use_https = ctx.flag("https", bool);
    const check_upload = ctx.flag("upload", bool);
    const json_output = ctx.flag("json", bool);
    const max_duration = ctx.flag("duration", i64);

    log.info("Config: https={}, upload={}, json={}, max_duration={}s", .{
        use_https, check_upload, json_output, max_duration,
    });

    var fast = Fast.init(std.heap.smp_allocator, use_https);
    defer fast.deinit();

    const urls = fast.get_urls(5) catch |err| {
        if (!json_output) {
            try ctx.spinner.fail("Failed to get URLs: {}", .{err});
        } else {
            const error_msg = switch (err) {
                error.ConnectionTimeout => "Failed to contact fast.com servers",
                else => "Failed to get URLs",
            };
            try outputJson(null, null, null, error_msg);
        }
        return;
    };

    log.info("Got {} URLs", .{urls.len});
    for (urls) |url| {
        log.debug("URL: {s}", .{url});
    }

    // Measure latency first
    var latency_tester = HttpLatencyTester.init(std.heap.smp_allocator);
    defer latency_tester.deinit();

    const latency_ms = if (!json_output) blk: {
        try ctx.spinner.start(.{}, "Measuring latency...", .{});
        const result = latency_tester.measureLatency(urls) catch |err| {
            log.err("Latency test failed: {}", .{err});
            break :blk null;
        };
        break :blk result;
    } else blk: {
        break :blk latency_tester.measureLatency(urls) catch null;
    };

    if (!json_output) {
        try ctx.spinner.start(.{}, "Measuring download speed...", .{});
    }

    // Initialize speed tester
    var speed_tester = HTTPSpeedTester.init(std.heap.smp_allocator);
    defer speed_tester.deinit();

    // Use Fast.com-style stability detection by default
    const criteria = StabilityCriteria{
        .ramp_up_duration_seconds = 4,
        .max_duration_seconds = @as(u32, @intCast(@max(25, max_duration))),
        .measurement_interval_ms = 750,
        .sliding_window_size = 6,
        .stability_threshold_cov = 0.15,
        .stable_checks_required = 2,
    };

    const download_result = if (json_output) blk: {
        // JSON mode: clean output only
        break :blk speed_tester.measure_download_speed_stability(urls, criteria) catch |err| {
            log.err("Download test failed: {}", .{err});
            try outputJson(null, null, null, "Download test failed");
            return;
        };
    } else blk: {
        // Interactive mode with spinner updates
        const progressCallback = progress.createCallback(ctx.spinner, updateSpinnerText);
        break :blk speed_tester.measureDownloadSpeedWithStabilityProgress(urls, criteria, progressCallback) catch |err| {
            try ctx.spinner.fail("Download test failed: {}", .{err});
            return;
        };
    };

    var upload_result: ?SpeedTestResult = null;
    if (check_upload) {
        if (!json_output) {
            try ctx.spinner.start(.{}, "Measuring upload speed...", .{});
        }

        upload_result = if (json_output) blk: {
            // JSON mode: clean output only
            break :blk speed_tester.measure_upload_speed_stability(urls, criteria) catch |err| {
                log.err("Upload test failed: {}", .{err});
                try outputJson(download_result.speed.value, latency_ms, null, "Upload test failed");
                return;
            };
        } else blk: {
            // Interactive mode with spinner updates
            const uploadProgressCallback = progress.createCallback(ctx.spinner, updateUploadSpinnerText);
            break :blk speed_tester.measureUploadSpeedWithStabilityProgress(urls, criteria, uploadProgressCallback) catch |err| {
                try ctx.spinner.fail("Upload test failed: {}", .{err});
                return;
            };
        };
    }

    // Output results
    if (!json_output) {
        if (latency_ms) |ping| {
            if (upload_result) |up| {
                try ctx.spinner.succeed("🏓 {d:.0}ms | ⬇️ Download: {d:.1} {s} | ⬆️ Upload: {d:.1} {s}", .{ ping, download_result.speed.value, download_result.speed.unit.toString(), up.speed.value, up.speed.unit.toString() });
            } else {
                try ctx.spinner.succeed("🏓 {d:.0}ms | ⬇️ Download: {d:.1} {s}", .{ ping, download_result.speed.value, download_result.speed.unit.toString() });
            }
        } else {
            if (upload_result) |up| {
                try ctx.spinner.succeed("⬇️ Download: {d:.1} {s} | ⬆️ Upload: {d:.1} {s}", .{ download_result.speed.value, download_result.speed.unit.toString(), up.speed.value, up.speed.unit.toString() });
            } else {
                try ctx.spinner.succeed("⬇️ Download: {d:.1} {s}", .{ download_result.speed.value, download_result.speed.unit.toString() });
            }
        }
    } else {
        const upload_speed = if (upload_result) |up| up.speed.value else null;
        try outputJson(download_result.speed.value, latency_ms, upload_speed, null);
    }
}

/// Update spinner text with current speed measurement
fn updateSpinnerText(spinner: anytype, measurement: SpeedMeasurement) void {
    spinner.updateText("⬇️ {d:.1} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

/// Update spinner text with current upload speed measurement
fn updateUploadSpinnerText(spinner: anytype, measurement: SpeedMeasurement) void {
    spinner.updateText("⬆️ {d:.1} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

fn outputJson(download_mbps: ?f64, ping_ms: ?f64, upload_mbps: ?f64, error_message: ?[]const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var download_buf: [32]u8 = undefined;
    var ping_buf: [32]u8 = undefined;
    var upload_buf: [32]u8 = undefined;
    var error_buf: [256]u8 = undefined;

    const download_str = if (download_mbps) |d| try std.fmt.bufPrint(&download_buf, "{d:.1}", .{d}) else "null";
    const ping_str = if (ping_ms) |p| try std.fmt.bufPrint(&ping_buf, "{d:.1}", .{p}) else "null";
    const upload_str = if (upload_mbps) |u| try std.fmt.bufPrint(&upload_buf, "{d:.1}", .{u}) else "null";
    const error_str = if (error_message) |e| try std.fmt.bufPrint(&error_buf, "\"{s}\"", .{e}) else "null";

    try stdout.print("{{\"download_mbps\": {s}, \"ping_ms\": {s}, \"upload_mbps\": {s}, \"error\": {s}}}\n", .{ download_str, ping_str, upload_str, error_str });
}
