const std = @import("std");
const http = @import("http.zig");

const child_timeout_ms = http.child_process_timeout_ms_value;

/// 同步 CPA 的 codex-api-key 列表，并保留 CPA 中已有的高级字段。
pub fn syncCodexApiKey(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    management_key: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    enabled: bool,
) !void {
    try validateManagementEndpoint(endpoint);
    const get_body = try runManagementRequest(allocator, endpoint, management_key, null, null);
    defer allocator.free(get_body);

    const payload = try buildCodexApiKeyPayloadAlloc(allocator, get_body, api_key, base_url, enabled);
    defer allocator.free(payload);
    const unused_response = try runManagementRequest(allocator, endpoint, management_key, "PUT", payload);
    allocator.free(unused_response);
}

/// 生成 CPA PUT 数组，保留未知配置字段并移除只读 auth-index。
pub fn buildCodexApiKeyPayloadAlloc(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    enabled: bool,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, response_body, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |*object| object,
        else => return error.InvalidCpaKeyResponse,
    };
    const list_value = root_object.getPtr("codex-api-key") orelse return error.InvalidCpaKeyResponse;
    if (list_value.* == .null) {
        list_value.* = .{ .array = std.json.Array.init(arena) };
    }
    const list = switch (list_value.*) {
        .array => |*array| array,
        else => return error.InvalidCpaKeyResponse,
    };

    var matched = false;
    var index: usize = 0;
    while (index < list.items.len) {
        const entry_value = &list.items[index];
        const entry = switch (entry_value.*) {
            .object => |*object| object,
            else => return error.InvalidCpaKeyResponse,
        };
        _ = entry.orderedRemove("auth-index");
        const same_entry = entryStringEquals(entry.*, "api-key", api_key) and
            entryStringEquals(entry.*, "base-url", base_url);
        if (!same_entry) {
            index += 1;
            continue;
        }
        matched = true;
        if (enabled) {
            index += 1;
        } else {
            _ = list.orderedRemove(index);
        }
    }

    if (enabled and !matched) {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "api-key", .{ .string = try arena.dupe(u8, api_key) });
        try entry.put(arena, "base-url", .{ .string = try arena.dupe(u8, base_url) });
        try list.append(.{ .object = entry });
    }

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try std.json.Stringify.value(list.items, .{}, &body.writer);
    return try allocator.dupe(u8, body.written());
}

/// 限制 CPA 管理端点为本机固定路径，避免管理密钥被转发到远端。
fn validateManagementEndpoint(endpoint: []const u8) !void {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidCpaManagementURL;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidCpaManagementURL;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Uri.getHost(uri, &host_buffer) catch return error.InvalidCpaManagementURL;
    const is_local = std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "::1");
    const valid_scheme = std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const path = uri.path.percent_encoded;
    if (!is_local or !valid_scheme or !std.mem.endsWith(u8, path, "/v0/management/codex-api-key")) {
        return error.InvalidCpaManagementURL;
    }
}

/// 执行 CPA 管理请求；认证头和 JSON 正文只存在 curl stdin 配置中。
fn runManagementRequest(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    management_key: []const u8,
    method: ?[]const u8,
    body: ?[]const u8,
) ![]u8 {
    const curl_executable = try http.resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl_executable);
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{management_key});
    defer allocator.free(authorization);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        curl_executable,
        "--disable",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        http.request_timeout_secs,
        "--output",
        "-",
        "--write-out",
        "\n%{http_code}",
        "--config",
        "-",
    });

    var config: std.ArrayList(u8) = .empty;
    defer config.deinit(allocator);
    try appendConfigLine(allocator, &config, "url", endpoint);
    try appendConfigLine(allocator, &config, "header", "User-Agent: " ++ http.user_agent);
    try appendConfigLine(allocator, &config, "header", "Accept: application/json");
    try appendConfigLine(allocator, &config, "header", authorization);
    if (method) |value| {
        try appendConfigLine(allocator, &config, "request", value);
        try appendConfigLine(allocator, &config, "header", "Content-Type: application/json");
    }
    if (body) |value| try appendConfigLine(allocator, &config, "data", value);

    const result = try http.runChildCaptureWithInputAndOutputLimit(
        allocator,
        argv.items,
        config.items,
        child_timeout_ms,
        null,
        http.default_max_output_bytes,
    );
    defer result.deinit(allocator);
    if (result.timed_out) return error.CpaManagementRequestTimedOut;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CpaManagementRequestFailed,
        else => return error.CpaManagementRequestFailed,
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    const status_index = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return error.CpaManagementRequestFailed;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, trimmed[status_index + 1 ..], " \r\t"), 10) catch return error.CpaManagementRequestFailed;
    if (status < 200 or status > 299) return error.CpaManagementRequestFailed;
    return try allocator.dupe(u8, trimmed[0..status_index]);
}

/// 判断 CPA 条目的指定字符串字段是否精确匹配。
fn entryStringEquals(entry: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const value = entry.get(field) orelse return false;
    return switch (value) {
        .string => |actual| std.mem.eql(u8, actual, expected),
        else => false,
    };
}

/// 写入 curl 配置行并转义密钥、URL和 JSON 中的特殊字符。
fn appendConfigLine(allocator: std.mem.Allocator, config: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try config.appendSlice(allocator, key);
    try config.appendSlice(allocator, " = \"");
    for (value) |byte| switch (byte) {
        '\\' => try config.appendSlice(allocator, "\\\\"),
        '"' => try config.appendSlice(allocator, "\\\""),
        '\n' => try config.appendSlice(allocator, "\\n"),
        '\r' => try config.appendSlice(allocator, "\\r"),
        '\t' => try config.appendSlice(allocator, "\\t"),
        else => try config.append(allocator, byte),
    };
    try config.appendSlice(allocator, "\"\n");
}
