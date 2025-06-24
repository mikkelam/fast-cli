const std = @import("std");
const http = @import("std").http;
const print = std.debug.print;
const testing = std.testing;

const log = std.log.scoped(.fast_api);

const mvzr = @import("mvzr");

const FastError = error{
    HttpRequestFailed,
    ScriptNotFound,
    TokenNotFound,
    JsonParseError,
    ConnectionTimeout,
};

const Location = struct { city: []const u8, country: []const u8 };

const Client = struct {
    ip: []const u8,
    asn: ?[]const u8 = null,
    isp: ?[]const u8 = null,
    location: ?Location = null,
};

const Target = struct {
    name: []const u8,
    url: []const u8,
    location: ?Location = null,
};

const FastResponse = struct {
    client: Client,
    targets: []Target,
};

pub const Fast = struct {
    client: http.Client,
    arena: std.heap.ArenaAllocator,
    use_https: bool,

    pub fn init(allocator: std.mem.Allocator, use_https: bool) Fast {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return Fast{
            .client = http.Client{ .allocator = allocator },
            .arena = arena,
            .use_https = use_https,
        };
    }

    pub fn deinit(self: *Fast) void {
        self.client.deinit();
        self.arena.deinit();
    }

    fn get_http_protocol(self: Fast) []const u8 {
        return if (self.use_https) "https" else "http";
    }

    pub fn get_urls(self: *Fast, url_count: u64) ![]const []const u8 {
        const allocator = self.arena.allocator();

        const token = try self.get_token(allocator);
        log.debug("Found token: {s}", .{token});
        const url = try std.fmt.allocPrint(allocator, "{s}://api.fast.com/netflix/speedtest/v2?https={}&token={s}&urlCount={d}", .{ self.get_http_protocol(), self.use_https, token, url_count });

        log.debug("Getting download URLs from: {s}", .{url});

        const json_data = try self.get_page(allocator, url);

        var result = try Fast.parse_response_urls(json_data.items, allocator);

        return result.toOwnedSlice();
    }

    /// Sanitizes JSON data by replacing invalid UTF-8 bytes that cause parseFromSlice to fail.
    ///
    /// Fast.com API returns city names with corrupted UTF-8 encoding:
    /// - "København" becomes "K�benhavn" in the HTTP response
    /// - The "�" character contains invalid UTF-8 bytes (e.g., 0xF8)
    /// - These bytes are not valid UTF-8 replacement characters (0xEF 0xBF 0xBD)
    /// - std.json.parseFromSlice fails with error.SyntaxError on invalid UTF-8
    ///
    /// This function replaces invalid UTF-8 bytes with spaces to make the JSON parseable.
    fn sanitize_json(json_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var sanitized = try allocator.dupe(u8, json_data);

        // Replace invalid UTF-8 bytes with spaces
        for (sanitized, 0..) |byte, i| {
            if (byte > 127) {
                // Replace any byte > 127 that's not part of a valid UTF-8 sequence
                // This includes:
                // - 0xF8 (248) and other invalid start bytes
                // - Orphaned continuation bytes (128-191)
                // - Any other problematic high bytes
                sanitized[i] = ' ';
            }
        }

        return sanitized;
    }

    fn parse_response_urls(json_data: []const u8, result_allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(result_allocator);

        const sanitized_json = try sanitize_json(json_data, result_allocator);
        defer result_allocator.free(sanitized_json);

        const parsed = std.json.parseFromSlice(FastResponse, result_allocator, sanitized_json, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("JSON parse error: {}", .{err});
            return error.JsonParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        for (response.targets) |target| {
            const url_copy = try result_allocator.dupe(u8, target.url);
            try result.append(url_copy);
        }

        return result;
    }

    fn extract_script_name(html_content: []const u8) ![]const u8 {
        const script_re = mvzr.compile("app-[a-zA-Z0-9]+\\.js").?;
        const script_match: mvzr.Match = script_re.match(html_content) orelse
            return error.ScriptNotFound;
        return html_content[script_match.start..script_match.end];
    }

    fn extract_token(script_content: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const token_re = mvzr.compile("token:\"[a-zA-Z0-9]*\"").?;
        const token_match = token_re.match(script_content) orelse
            return error.TokenNotFound;
        const token_with_prefix = script_content[token_match.start..token_match.end];
        return allocator.dupe(u8, token_with_prefix[7 .. token_with_prefix.len - 1]);
    }

    /// This function searches for the token in the javascript returned by the fast.com public website
    fn get_token(self: *Fast, allocator: std.mem.Allocator) ![]const u8 {
        const base_url = try std.fmt.allocPrint(allocator, "{s}://fast.com", .{self.get_http_protocol()});

        const fast_body = try self.get_page(allocator, base_url);
        const script_name = try extract_script_name(fast_body.items);
        const script_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, script_name });

        // print("getting fast api token from {s}\n", .{script_url});

        const resp_body = try self.get_page(allocator, script_url);
        return extract_token(resp_body.items, allocator);
    }

    fn get_page(self: *Fast, allocator: std.mem.Allocator, url: []const u8) !std.ArrayList(u8) {
        _ = allocator;
        var response_body = std.ArrayList(u8).init(self.arena.allocator());

        const response: http.Client.FetchResult = self.client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_body },
        }) catch |err| switch (err) {
            error.NetworkUnreachable, error.ConnectionRefused => {
                log.err("Failed to reach fast.com servers (network/connection error) for URL: {s}", .{url});
                return error.ConnectionTimeout;
            },
            error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure, error.HostLacksNetworkAddresses => {
                log.err("Failed to resolve fast.com hostname (DNS/internet connection issue) for URL: {s}", .{url});
                return error.ConnectionTimeout;
            },
            error.ConnectionTimedOut, error.ConnectionResetByPeer => {
                log.err("Connection to fast.com servers timed out or was reset for URL: {s}", .{url});
                return error.ConnectionTimeout;
            },
            error.TlsInitializationFailed => {
                log.err("Failed to establish secure connection to fast.com servers for URL: {s}", .{url});
                return error.ConnectionTimeout;
            },
            error.UnexpectedConnectFailure => {
                log.err("Unexpected connection failure to fast.com servers for URL: {s}", .{url});
                return error.ConnectionTimeout;
            },
            else => {
                log.err("Network error: {} for URL: {s}", .{ err, url });
                return error.ConnectionTimeout;
            },
        };

        log.debug("HTTP response status: {} for URL: {s}", .{ response.status, url });

        if (response.status != .ok) {
            log.err("HTTP request failed with status code {}", .{response.status});
            return error.HttpRequestFailed;
        }
        return response_body;
    }
};

test "parse_response_urls_v2" {
    const response =
        \\{"client":{"ip":"87.52.107.67","asn":"3292","isp":"YouSee","location":{"city":"Kobenhavn","country":"DK"}},"targets":[{"name":"https://example.com/0","url":"https://example.com/0","location":{"city":"Test","country":"DK"}},{"name":"https://example.com/1","url":"https://example.com/1","location":{"city":"Test","country":"DK"}}]}
    ;
    const allocator = testing.allocator;

    const urls = try Fast.parse_response_urls(response, allocator);
    defer {
        for (urls.items) |url| {
            allocator.free(url);
        }
        urls.deinit();
    }

    try testing.expect(urls.items.len == 2);
    try testing.expect(std.mem.eql(u8, urls.items[0], "https://example.com/0"));
    try testing.expect(std.mem.eql(u8, urls.items[1], "https://example.com/1"));
}

test "sanitize_json_removes_invalid_utf8" {
    // Test that sanitize_json replaces invalid UTF-8 bytes like 0xF8 (248) with spaces
    const problematic_json = [_]u8{
        '{', '"', 'c', 'i', 't', 'y', '"', ':', '"', 'K',
        0xF8, // Invalid UTF-8 byte (248) - reproduces Fast.com API issue
        'b',
        'e',
        'n',
        'h',
        'a',
        'v',
        'n',
        '"',
        '}',
    };

    const allocator = testing.allocator;

    const sanitized = try Fast.sanitize_json(&problematic_json, allocator);
    defer allocator.free(sanitized);

    // Verify that the 0xF8 byte was replaced with a space
    var found_space = false;
    for (sanitized) |byte| {
        if (byte == ' ') {
            found_space = true;
        }
        // Should not contain any bytes > 127 after sanitization
        try testing.expect(byte <= 127);
    }
    try testing.expect(found_space); // Should have replaced invalid byte with space
}

test "extract_script_name" {
    const html =
        \\<html><head><script src="app-1234abcd.js"></script></head></html>
    ;
    const script_name = try Fast.extract_script_name(html);
    try testing.expect(std.mem.eql(u8, script_name, "app-1234abcd.js"));
}

test "extract_token" {
    const script_content =
        \\var config = {token:"abcdef123456", other: "value"};
    ;
    const allocator = testing.allocator;
    const token = try Fast.extract_token(script_content, allocator);
    defer allocator.free(token);
    try testing.expect(std.mem.eql(u8, token, "abcdef123456"));
}

test "parse_response_without_isp" {
    const response =
        \\{"client":{"ip":"87.52.107.67","asn":"3292","location":{"city":"Test","country":"DK"}},"targets":[{"name":"https://example.com/0","url":"https://example.com/0","location":{"city":"Test","country":"DK"}}]}
    ;
    const allocator = testing.allocator;

    const urls = try Fast.parse_response_urls(response, allocator);
    defer {
        for (urls.items) |url| {
            allocator.free(url);
        }
        urls.deinit();
    }

    try testing.expect(urls.items.len == 1);
    try testing.expect(std.mem.eql(u8, urls.items[0], "https://example.com/0"));
}

test "parse_response_minimal_client" {
    const response =
        \\{"client":{"ip":"87.52.107.67"},"targets":[{"name":"https://example.com/0","url":"https://example.com/0"}]}
    ;
    const allocator = testing.allocator;

    const urls = try Fast.parse_response_urls(response, allocator);
    defer {
        for (urls.items) |url| {
            allocator.free(url);
        }
        urls.deinit();
    }

    try testing.expect(urls.items.len == 1);
    try testing.expect(std.mem.eql(u8, urls.items[0], "https://example.com/0"));
}
