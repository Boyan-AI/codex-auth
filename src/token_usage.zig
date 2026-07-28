const std = @import("std");
const app_runtime = @import("core/runtime.zig");
const registry = @import("registry/root.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

const max_rollout_bytes: usize = 64 * 1024 * 1024;

const UsageTotals = struct {
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    total_tokens: i64 = 0,

    fn add(self: *UsageTotals, value: UsageTotals) void {
        self.input_tokens += value.input_tokens;
        self.cached_input_tokens += value.cached_input_tokens;
        self.output_tokens += value.output_tokens;
        self.reasoning_output_tokens += value.reasoning_output_tokens;
        self.total_tokens += value.total_tokens;
    }

    fn subtract(current: UsageTotals, previous: UsageTotals) ?UsageTotals {
        const result = UsageTotals{
            .input_tokens = current.input_tokens - previous.input_tokens,
            .cached_input_tokens = current.cached_input_tokens - previous.cached_input_tokens,
            .output_tokens = current.output_tokens - previous.output_tokens,
            .reasoning_output_tokens = current.reasoning_output_tokens - previous.reasoning_output_tokens,
            .total_tokens = current.total_tokens - previous.total_tokens,
        };
        if (result.input_tokens < 0 or
            result.cached_input_tokens < 0 or
            result.output_tokens < 0 or
            result.reasoning_output_tokens < 0 or
            result.total_tokens < 0) return null;
        return result;
    }
};

const DayUsage = struct {
    date: []u8,
    totals: UsageTotals = .{},
    sessions: usize = 0,

    fn deinit(self: *DayUsage, allocator: std.mem.Allocator) void {
        allocator.free(self.date);
    }
};

const TokenUsageJson = struct {
    input_tokens: ?i64 = null,
    cached_input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    reasoning_output_tokens: ?i64 = null,
    total_tokens: ?i64 = null,
};

const TokenInfoJson = struct {
    total_token_usage: ?TokenUsageJson = null,
};

const TokenPayloadJson = struct {
    type: []const u8 = "",
    info: TokenInfoJson = .{},
};

const TokenLineJson = struct {
    timestamp: []const u8 = "",
    type: []const u8 = "",
    payload: TokenPayloadJson = .{},
};

pub const Report = struct {
    totals: UsageTotals = .{},
    days: std.ArrayList(DayUsage) = .empty,
    files_scanned: usize = 0,
    files_with_usage: usize = 0,
    repeated_snapshots: usize = 0,
    segmented_sessions: usize = 0,
    parse_errors: usize = 0,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.days.items) |*day| day.deinit(allocator);
        self.days.deinit(allocator);
    }
};

/// 输出 GUI 使用的稳定 JSON；事件日期与“今日”统一使用 UTC 自然日。
pub fn writeJson(report: *Report, out: *std.Io.Writer) !void {
    std.sort.insertion(DayUsage, report.days.items, {}, struct {
        fn lessThan(_: void, left: DayUsage, right: DayUsage) bool {
            return std.mem.order(u8, left.date, right.date) == .gt;
        }
    }.lessThan);

    try out.writeAll("{\"timezone\":\"UTC\",\"summary\":");
    try writeTotals(out, report.totals);
    try out.print(",\"today\":", .{});
    if (currentUtcDate()) |today| {
        var found = false;
        for (report.days.items) |day| {
            if (std.mem.eql(u8, day.date, today[0..])) {
                try writeDay(out, day);
                found = true;
                break;
            }
        }
        if (!found) try out.writeAll("null");
    } else {
        try out.writeAll("null");
    }
    try out.print(",\"latest_day\":", .{});
    if (report.days.items.len == 0) {
        try out.writeAll("null");
    } else {
        try writeDay(out, report.days.items[0]);
    }
    try out.writeAll(",\"days\":[");
    for (report.days.items, 0..) |day, idx| {
        if (idx != 0) try out.writeAll(",");
        try writeDay(out, day);
    }
    try out.print("],\"quality\":{{\"files_scanned\":{d},\"files_with_usage\":{d},\"repeated_snapshots\":{d},\"segmented_sessions\":{d},\"parse_errors\":{d}}}}}", .{
        report.files_scanned,
        report.files_with_usage,
        report.repeated_snapshots,
        report.segmented_sessions,
        report.parse_errors,
    });
}

/// 返回当前 UTC 日期；与 rollout 时间戳的日期字段保持同一口径。
fn currentUtcDate() ?[10]u8 {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var tm: c_time.struct_tm = undefined;
    var time_value = std.math.cast(c_time.time_t, now) orelse return null;
    if (comptime @hasDecl(c_time, "gmtime_r")) {
        if (c_time.gmtime_r(&time_value, &tm) == null) return null;
    } else if (comptime @hasDecl(c_time, "gmtime")) {
        const tm_ptr = c_time.gmtime(&time_value) orelse return null;
        tm = tm_ptr.*;
    } else {
        return null;
    }
    var date: [10]u8 = undefined;
    const year: i32 = @as(i32, tm.tm_year) + 1900;
    const month: i32 = @as(i32, tm.tm_mon) + 1;
    const day: i32 = @as(i32, tm.tm_mday);
    date[0] = @intCast(@divFloor(year, 1000) + '0');
    date[1] = @intCast(@mod(@divFloor(year, 100), 10) + '0');
    date[2] = @intCast(@mod(@divFloor(year, 10), 10) + '0');
    date[3] = @intCast(@mod(year, 10) + '0');
    date[4] = '-';
    date[5] = @intCast(@divFloor(month, 10) + '0');
    date[6] = @intCast(@mod(month, 10) + '0');
    date[7] = '-';
    date[8] = @intCast(@divFloor(day, 10) + '0');
    date[9] = @intCast(@mod(day, 10) + '0');
    return date;
}

fn writeTotals(out: *std.Io.Writer, totals: UsageTotals) !void {
    try out.print("{{\"input_tokens\":{d},\"cached_input_tokens\":{d},\"output_tokens\":{d},\"reasoning_output_tokens\":{d},\"total_tokens\":{d}}}", .{
        totals.input_tokens,
        totals.cached_input_tokens,
        totals.output_tokens,
        totals.reasoning_output_tokens,
        totals.total_tokens,
    });
}

fn writeDay(out: *std.Io.Writer, day: DayUsage) !void {
    try out.writeAll("{\"date\":\"");
    try out.writeAll(day.date);
    try out.print("\",\"sessions\":{d},\"totals\":", .{day.sessions});
    try writeTotals(out, day.totals);
    try out.writeAll("}");
}

/// 扫描 Codex rollout 文件，并通过累计 token 快照差分恢复真实增量。
pub fn scan(allocator: std.mem.Allocator, codex_home: []const u8) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);

    const sessions_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "sessions" });
    defer allocator.free(sessions_root);
    scanRoot(allocator, sessions_root, &report) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    };

    const archived_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "archived_sessions" });
    defer allocator.free(archived_root);
    scanRoot(allocator, archived_root, &report) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    };
    return report;
}

fn scanRoot(allocator: std.mem.Allocator, root: []const u8, report: *Report) !void {
    var dir = try std.Io.Dir.cwd().openDir(app_runtime.io(), root, .{ .iterate = true });
    defer dir.close(app_runtime.io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(app_runtime.io())) |entry| {
        if (entry.kind != .file or !isRolloutFile(entry.path)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ root, entry.path });
        defer allocator.free(path);
        report.files_scanned += 1;
        try scanFile(allocator, path, report);
    }
}

fn scanFile(allocator: std.mem.Allocator, path: []const u8, report: *Report) !void {
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const bytes = registry.readFileAlloc(file, allocator, max_rollout_bytes) catch |err| switch (err) {
        error.StreamTooLong => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var previous: ?UsageTotals = null;
    var has_usage = false;
    var touched_days = std.ArrayList([]const u8).empty;
    defer touched_days.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(TokenLineJson, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
            report.parse_errors += 1;
            continue;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (!std.mem.eql(u8, root.type, "event_msg") or
            !std.mem.eql(u8, root.payload.type, "token_count")) continue;
        const raw = root.payload.info.total_token_usage orelse continue;
        const current = totalsFromJson(raw);
        const delta = if (previous) |old| blk: {
            if (UsageTotals.subtract(current, old)) |value| break :blk value;
            report.segmented_sessions += 1;
            break :blk current;
        } else current;
        previous = current;
        if (delta.total_tokens == 0 and delta.input_tokens == 0 and delta.output_tokens == 0) {
            report.repeated_snapshots += 1;
            continue;
        }
        const date = if (root.timestamp.len >= 10) root.timestamp[0..10] else continue;
        var is_new_day_for_file = true;
        for (touched_days.items) |touched| {
            if (std.mem.eql(u8, touched, date)) {
                is_new_day_for_file = false;
                break;
            }
        }
        if (is_new_day_for_file) try touched_days.append(allocator, date);
        try addDay(allocator, report, date, delta, is_new_day_for_file);
        report.totals.add(delta);
        has_usage = true;
    }
    if (has_usage) report.files_with_usage += 1;
}

fn totalsFromJson(value: TokenUsageJson) UsageTotals {
    return .{
        .input_tokens = value.input_tokens orelse 0,
        .cached_input_tokens = value.cached_input_tokens orelse 0,
        .output_tokens = value.output_tokens orelse 0,
        .reasoning_output_tokens = value.reasoning_output_tokens orelse 0,
        .total_tokens = value.total_tokens orelse 0,
    };
}

fn addDay(allocator: std.mem.Allocator, report: *Report, date: []const u8, delta: UsageTotals, new_session: bool) !void {
    for (report.days.items) |*day| {
        if (std.mem.eql(u8, day.date, date)) {
            day.totals.add(delta);
            if (new_session) day.sessions += 1;
            return;
        }
    }
    try report.days.append(allocator, .{
        .date = try allocator.dupe(u8, date),
        .totals = delta,
        .sessions = 1,
    });
}

fn isRolloutFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
    return std.mem.startsWith(u8, std.fs.path.basename(path), "rollout-");
}
