const std = @import("std");
const clap = @import("clap");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

// ANSI formatting codes
const BOLD = "\x1b[1m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";

pub const duration_default_seconds: u32 = 30;
pub const duration_min_seconds: u32 = 7;
pub const duration_max_seconds: u32 = 30;

pub fn clampDurationSeconds(value: u32) u32 {
    return @min(duration_max_seconds, @max(value, duration_min_seconds));
}

pub const Args = struct {
    https: bool,
    upload: bool,
    json: bool,
    duration: u32,
    help: bool,

    allocator: Allocator,
    clap_result: ?clap.Result(clap.Help, &params, parsers) = null,

    pub fn deinit(self: *Args) void {
        if (self.clap_result) |*res| {
            res.deinit();
        }
    }
};

const params = clap.parseParamsComptime(std.fmt.comptimePrint(
    \\-h, --help              Display this help and exit.
    \\    --https             Use HTTPS when connecting to fast.com (default)
    \\    --no-https          Use HTTP instead of HTTPS
    \\-u, --upload            Check upload speed as well
    \\-j, --json              Output results in JSON format
    \\-d, --duration <usize>  Maximum test duration in seconds (effective range: {d}-{d}, default: {d})
    \\
, .{ duration_min_seconds, duration_max_seconds, duration_default_seconds }));

const parsers = .{
    .usize = clap.parsers.int(u32, 10),
};

pub fn parse(allocator: Allocator) !Args {
    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        try diag.report(stderr, err);
        return err;
    };

    return .{
        .https = if (res.args.@"no-https" != 0) false else true,
        .upload = res.args.upload != 0,
        .json = res.args.json != 0,
        .duration = res.args.duration orelse duration_default_seconds,
        .help = res.args.help != 0,
        .allocator = allocator,
        .clap_result = res,
    };
}

pub fn printHelp() !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print(BOLD ++ "fast-cli" ++ RESET ++ " v{s} - Estimate connection speed using fast.com\n\n", .{build_options.version});
    try stderr.writeAll(YELLOW ++ "USAGE:\n" ++ RESET);
    try stderr.writeAll("    fast-cli [OPTIONS]\n\n");
    try stderr.writeAll(YELLOW ++ "OPTIONS:\n" ++ RESET);
    try clap.help(stderr, clap.Help, &params, .{ .spacing_between_parameters = 0, .description_on_new_line = false });
    try stderr.flush();
}
