const std = @import("std");
const Args = @import("args.zig");
const Spinner = @import("../lib/spinner/spinner.zig");

const log = std.log.scoped(.cli);

const Fast = @import("../lib/fast.zig").Fast;
const HTTPSpeedTester = @import("../lib/http_speed_tester_v2.zig").HTTPSpeedTester;
const StabilityCriteria = @import("../lib/http_speed_tester_v2.zig").StabilityCriteria;
const SpeedTestResult = @import("../lib/http_speed_tester_v2.zig").SpeedTestResult;
const Speed = @import("../lib/bandwidth.zig").Speed;
const progress = @import("../lib/progress.zig");
const HttpLatencyTester = @import("../lib/http_latency_tester.zig").HttpLatencyTester;

const certificate_bundle_error_message = "Failed to load system CA certificates (on Linux, install ca-certificates)";

pub fn run(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) !void {
    var args = try Args.parse(allocator, io, process_args);
    defer args.deinit();

    if (args.help) {
        try Args.printHelp(io);
        return;
    }

    log.info("Config: https={}, upload={}, json={}, max_duration={}s", .{
        args.https,
        args.upload,
        args.json,
        args.duration,
    });

    var spinner = Spinner.init(allocator, io, .{});
    defer spinner.deinit();

    var fast = Fast.init(allocator, io, args.https);
    defer fast.deinit();

    const urls = fast.get_urls(5) catch |err| {
        if (!args.json) {
            switch (err) {
                error.CertificateBundleLoadFailure => try spinner.fail("{s}", .{certificate_bundle_error_message}),
                else => try spinner.fail("Failed to get URLs: {}", .{err}),
            }
        } else {
            const error_msg = switch (err) {
                error.ConnectionTimeout => "Failed to contact fast.com servers",
                error.CertificateBundleLoadFailure => certificate_bundle_error_message,
                else => "Failed to get URLs",
            };
            try outputJson(io, null, null, null, error_msg);
        }
        return;
    };

    log.info("Got {} URLs", .{urls.len});
    for (urls) |url| {
        log.info("URL: {s}", .{url});
    }

    // Measure latency
    var latency_tester = HttpLatencyTester.init(allocator, io);
    defer latency_tester.deinit();

    const latency_ms = if (!args.json) blk: {
        try spinner.start("Measuring latency...", .{});
        const result = latency_tester.measureLatency(urls) catch |err| {
            try spinner.fail("Latency test failed: {}", .{err});
            break :blk null;
        };
        spinner.stop();
        break :blk result;
    } else blk: {
        break :blk latency_tester.measureLatency(urls) catch null;
    };

    if (!args.json) {
        log.info("Measuring download speed...", .{});
        try spinner.start("⬇️ 0 Mbps", .{});
    }

    // Initialize speed tester
    var speed_tester = HTTPSpeedTester.init(allocator, io);
    defer speed_tester.deinit();

    const criteria = StabilityCriteria{
        .min_duration_seconds = Args.duration_min_seconds,
        .max_duration_seconds = Args.clampDurationSeconds(args.duration),
        .progress_frequency_ms = 150,
        .moving_average_window_size = 5,
        .stability_delta_percent = 2.0,
        .min_stable_measurements = 6,
        .connections_min = 1,
        .max_bytes_in_flight = 78_643_200,
    };

    const download_result = if (args.json) blk: {
        break :blk speed_tester.measure_download_speed_stability(urls, criteria) catch {
            try outputJson(io, null, null, null, "Download test failed");
            return;
        };
    } else blk: {
        const progressCallback = progress.createCallback(&spinner, updateSpinnerText);
        const result = speed_tester.measureDownloadSpeedWithStabilityProgress(urls, criteria, progressCallback) catch |err| {
            try spinner.fail("Download test failed: {}", .{err});
            return;
        };
        break :blk result;
    };

    var upload_result: ?SpeedTestResult = null;
    if (args.upload) {
        if (!args.json) {
            log.info("Measuring upload speed...", .{});
            try spinner.updateMessage("⬆️ 0 Mbps", .{});
        }

        upload_result = if (args.json) blk: {
            break :blk speed_tester.measure_upload_speed_stability(urls, criteria) catch {
                try outputJson(io, download_result.speed.valueIn(.mbps), latency_ms, null, "Upload test failed");
                return;
            };
        } else blk: {
            const uploadProgressCallback = progress.createCallback(&spinner, updateUploadSpinnerText);
            const result = speed_tester.measureUploadSpeedWithStabilityProgress(urls, criteria, uploadProgressCallback) catch |err| {
                try spinner.fail("Upload test failed: {}", .{err});
                return;
            };
            break :blk result;
        };
    }

    // Output results
    if (!args.json) {
        const download = download_result.speed.forDisplay();
        if (latency_ms) |ping| {
            if (upload_result) |up| {
                const upload = up.speed.forDisplay();
                try spinner.succeed("🏓 {d:.0}ms | ⬇️ Download: {d:.0} {s} | ⬆️ Upload: {d:.0} {s}", .{ ping, download.value, download.unit.toString(), upload.value, upload.unit.toString() });
            } else {
                try spinner.succeed("🏓 {d:.0}ms | ⬇️ Download: {d:.0} {s}", .{ ping, download.value, download.unit.toString() });
            }
        } else {
            if (upload_result) |up| {
                const upload = up.speed.forDisplay();
                try spinner.succeed("⬇️ Download: {d:.0} {s} | ⬆️ Upload: {d:.0} {s}", .{ download.value, download.unit.toString(), upload.value, upload.unit.toString() });
            } else {
                try spinner.succeed("⬇️ Download: {d:.0} {s}", .{ download.value, download.unit.toString() });
            }
        }
    } else {
        const upload_mbps = if (upload_result) |up| up.speed.valueIn(.mbps) else null;
        try outputJson(io, download_result.speed.valueIn(.mbps), latency_ms, upload_mbps, null);
    }
}

fn updateSpinnerText(spinner: *Spinner, speed: Speed) void {
    const measurement = speed.forDisplay();
    spinner.updateMessage("⬇️ {d:.0} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

fn updateUploadSpinnerText(spinner: *Spinner, speed: Speed) void {
    const measurement = speed.forDisplay();
    spinner.updateMessage("⬆️ {d:.0} {s}", .{ measurement.value, measurement.unit.toString() }) catch {};
}

fn outputJson(io: std.Io, download_mbps: ?f64, ping_ms: ?f64, upload_mbps: ?f64, error_message: ?[]const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var download_buf: [32]u8 = undefined;
    var ping_buf: [32]u8 = undefined;
    var upload_buf: [32]u8 = undefined;
    var error_buf: [256]u8 = undefined;

    const download_str = if (download_mbps) |d| try std.fmt.bufPrint(&download_buf, "{d:.0}", .{d}) else "null";
    const ping_str = if (ping_ms) |p| try std.fmt.bufPrint(&ping_buf, "{d:.1}", .{p}) else "null";
    const upload_str = if (upload_mbps) |u| try std.fmt.bufPrint(&upload_buf, "{d:.0}", .{u}) else "null";
    const error_str = if (error_message) |e| try std.fmt.bufPrint(&error_buf, "\"{s}\"", .{e}) else "null";

    try stdout.print("{{\"download_mbps\": {s}, \"ping_ms\": {s}, \"upload_mbps\": {s}, \"error\": {s}}}\n", .{ download_str, ping_str, upload_str, error_str });
    try stdout.flush();
}
