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
const HttpLatencyTester = @import("../lib/latency.zig").HttpLatencyTester;
const log = std.log.scoped(.cli);

/// Update spinner text with current speed measurement
fn updateSpinnerText(spinner: anytype, measurement: SpeedMeasurement) void {
    spinner.updateText("⬇️ {d:.1} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

/// Update spinner text with current upload speed measurement
fn updateUploadSpinnerText(spinner: anytype, measurement: SpeedMeasurement) void {
    spinner.updateText("⬆️ {d:.1} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

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
    .description = "Maximum test duration in seconds (uses Fast.com-style stability detection by default)",
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

    var fast = Fast.init(std.heap.page_allocator, use_https);
    defer fast.deinit();

    const urls = fast.get_urls(5) catch |err| {
        if (!json_output) {
            try ctx.spinner.fail("Failed to get URLs: {}", .{err});
        } else {
            std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
        }
        return;
    };

    log.info("Got {} URLs", .{urls.len});
    for (urls) |url| {
        log.debug("URL: {s}", .{url});
    }

    // Measure latency first
    var latency_tester = HttpLatencyTester.init(std.heap.page_allocator);
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
    var speed_tester = HTTPSpeedTester.init(std.heap.page_allocator);
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
        break :blk speed_tester.measure_download_speed_fast_stability(urls, criteria) catch |err| {
            log.err("Download test failed: {}", .{err});
            std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
            return;
        };
    } else blk: {
        // Interactive mode with spinner updates
        const progressCallback = progress.createCallback(ctx.spinner, updateSpinnerText);
        break :blk speed_tester.measureDownloadSpeedWithFastStabilityProgress(urls, criteria, progressCallback) catch |err| {
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
            break :blk speed_tester.measure_upload_speed_fast_stability(urls, criteria) catch |err| {
                log.err("Upload test failed: {}", .{err});
                std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
                return;
            };
        } else blk: {
            // Interactive mode with spinner updates
            const uploadProgressCallback = progress.createCallback(ctx.spinner, updateUploadSpinnerText);
            break :blk speed_tester.measureUploadSpeedWithFastStabilityProgress(urls, criteria, uploadProgressCallback) catch |err| {
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
        std.debug.print("{{\"download_mbps\": {d:.1}", .{download_result.speed.value});
        if (latency_ms) |ping| {
            std.debug.print(", \"ping_ms\": {d:.1}", .{ping});
        }
        if (upload_result) |up| {
            std.debug.print(", \"upload_mbps\": {d:.1}", .{up.speed.value});
        }
        std.debug.print("}}\n", .{});
    }
}
