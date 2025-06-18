const std = @import("std");
const zli = @import("zli");
const builtin = @import("builtin");
const build_options = @import("build_options");
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

const test_mode_flag = zli.Flag{
    .name = "mode",
    .description = "Test mode: 'duration' or 'stability'",
    .shortcut = "m",
    .type = .String,
    .default_value = .{ .String = "duration" },
};

const test_duration_flag = zli.Flag{
    .name = "duration",
    .description = "Duration in seconds for each test phase - download, then upload if enabled (duration mode only)",
    .shortcut = "d",
    .type = .Int,
    .default_value = .{ .Int = 5 },
};

const stability_min_samples_flag = zli.Flag{
    .name = "stability-min-samples",
    .description = "Minimum samples for stability test",
    .type = .Int,
    .default_value = .{ .Int = 5 },
};

const stability_max_variance_flag = zli.Flag{
    .name = "stability-max-variance",
    .description = "Maximum variance percentage for stability test",
    .type = .String,
    .default_value = .{ .String = "10.0" },
};

const stability_max_duration_flag = zli.Flag{
    .name = "stability-max-duration",
    .description = "Maximum duration in seconds for stability test",
    .type = .Int,
    .default_value = .{ .Int = 30 },
};

pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = "fast-cli",
        .description = "Estimate connection speed using fast.com",
        .version = std.SemanticVersion.parse(build_options.version) catch null,
    }, run);

    try root.addFlag(https_flag);
    try root.addFlag(check_upload_flag);
    try root.addFlag(json_output_flag);
    try root.addFlag(test_mode_flag);
    try root.addFlag(test_duration_flag);
    try root.addFlag(stability_min_samples_flag);
    try root.addFlag(stability_max_variance_flag);
    try root.addFlag(stability_max_duration_flag);

    return root;
}

fn run(ctx: zli.CommandContext) !void {
    const use_https = ctx.flag("https", bool);
    const check_upload = ctx.flag("upload", bool);
    const json_output = ctx.flag("json", bool);
    const test_mode = ctx.flag("mode", []const u8);
    const test_duration = ctx.flag("duration", i64);
    const stability_min_samples = ctx.flag("stability-min-samples", i64);
    const stability_max_variance_str = ctx.flag("stability-max-variance", []const u8);
    const stability_max_duration = ctx.flag("stability-max-duration", i64);

    const stability_max_variance = std.fmt.parseFloat(f64, stability_max_variance_str) catch 10.0;
    log.info("Config: https={}, upload={}, json={}, mode={s}, duration={}s", .{
        use_https, check_upload, json_output, test_mode, test_duration,
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

    // Determine test mode
    const use_stability = std.mem.eql(u8, test_mode, "stability");

    // Measure download speed

    const download_result = if (use_stability) blk: {
        const criteria = StabilityCriteria{
            .min_samples = @as(u32, @intCast(stability_min_samples)),
            .max_variance_percent = stability_max_variance,
            .max_duration_seconds = @as(u32, @intCast(stability_max_duration)),
        };
        break :blk speed_tester.measure_download_speed_stability(urls, criteria) catch |err| {
            if (!json_output) {
                try ctx.spinner.fail("Download test failed: {}", .{err});
            } else {
                log.err("Download test failed: {}", .{err});
                std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
            }
            return;
        };
    } else blk: {
        if (json_output) {
            // JSON mode: clean output only
            break :blk speed_tester.measureDownloadSpeed(urls, @as(u32, @intCast(@max(0, test_duration)))) catch |err| {
                log.err("Download test failed: {}", .{err});
                std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
                return;
            };
        } else {
            // Create progress callback with spinner context
            const progressCallback = progress.createCallback(ctx.spinner, updateSpinnerText);

            break :blk speed_tester.measureDownloadSpeedWithProgress(urls, @as(u32, @intCast(@max(0, test_duration))), progressCallback) catch |err| {
                try ctx.spinner.fail("Download test failed: {}", .{err});
                return;
            };
        }
    };

    var upload_result: ?SpeedTestResult = null;
    if (check_upload) {
        if (!json_output) {
            const upload_mode_str = if (use_stability) "stability" else "duration";
            try ctx.spinner.start(.{}, "Measuring upload speed ({s} mode)...", .{upload_mode_str});
        }

        upload_result = if (use_stability) blk: {
            const criteria = StabilityCriteria{
                .min_samples = @as(u32, @intCast(stability_min_samples)),
                .max_variance_percent = stability_max_variance,
                .max_duration_seconds = @as(u32, @intCast(stability_max_duration)),
            };
            break :blk speed_tester.measure_upload_speed_stability(urls, criteria) catch |err| {
                if (!json_output) {
                    try ctx.spinner.fail("Upload test failed: {}", .{err});
                }
                return;
            };
        } else blk: {
            if (json_output) {
                // JSON mode: clean output only
                break :blk speed_tester.measureUploadSpeed(urls, @as(u32, @intCast(@max(0, test_duration)))) catch |err| {
                    log.err("Upload test failed: {}", .{err});
                    std.debug.print("{{\"error\": \"{}\"}}\n", .{err});
                    return;
                };
            } else {
                // Create progress callback with spinner context
                const uploadProgressCallback = progress.createCallback(ctx.spinner, updateUploadSpinnerText);

                break :blk speed_tester.measureUploadSpeedWithProgress(urls, @as(u32, @intCast(@max(0, test_duration))), uploadProgressCallback) catch |err| {
                    try ctx.spinner.fail("Upload test failed: {}", .{err});
                    return;
                };
            }
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
