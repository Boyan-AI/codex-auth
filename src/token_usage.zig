const std = @import("std");
const app_runtime = @import("core/runtime.zig");
const builtin = @import("builtin");
const compat_fs = @import("core/compat_fs.zig");
const registry = @import("registry/root.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

const max_rollout_bytes: usize = 64 * 1024 * 1024;
const max_cache_bytes: usize = 16 * 1024 * 1024;
const cache_schema_version: u32 = 2;

const ScanMode = enum { incremental, full };

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

/// 保存单个 rollout 文件的独立贡献，使变更文件可以单独重算并安全替换。
const FileReport = struct {
    path: []u8,
    size: u64,
    mtime_ns: i128,
    totals: UsageTotals = .{},
    days: std.ArrayList(DayUsage) = .empty,
    has_usage: bool = false,
    repeated_snapshots: usize = 0,
    segmented_sessions: usize = 0,
    parse_errors: usize = 0,

    /// 释放缓存条目的路径与日期所有权。
    fn deinit(self: *FileReport, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.days.items) |*day| day.deinit(allocator);
        self.days.deinit(allocator);
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

const CachedDayJson = struct {
    date: []const u8,
    totals: UsageTotals,
    sessions: usize,
};

const CachedFileJson = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
    totals: UsageTotals,
    days: []const CachedDayJson,
    has_usage: bool,
    repeated_snapshots: usize,
    segmented_sessions: usize,
    parse_errors: usize,
};

const CacheDocumentJson = struct {
    schema_version: u32,
    files: []const CachedFileJson,
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

/// 输出 GUI 使用的稳定 JSON；事件日期与“今日”统一使用运行机器的本地自然日。
pub fn writeJson(report: *Report, out: *std.Io.Writer) !void {
    std.sort.insertion(DayUsage, report.days.items, {}, struct {
        fn lessThan(_: void, left: DayUsage, right: DayUsage) bool {
            return std.mem.order(u8, left.date, right.date) == .gt;
        }
    }.lessThan);

    try out.writeAll("{\"timezone\":\"local\",\"summary\":");
    try writeTotals(out, report.totals);
    try out.print(",\"today\":", .{});
    if (currentLocalDate()) |today| {
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

/// 返回当前本地日期；与 rollout 事件的本地日期转换保持同一口径。
fn currentLocalDate() ?[10]u8 {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    return localDateFromUnixSeconds(now);
}

/// 兼容 Windows 与 POSIX libc，把 Unix 秒转换为运行机器的本地日历时间。
fn localtimeCompat(timestamp: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var timestamp_64 = std.math.cast(c_time.__time64_t, timestamp) orelse return false;
            return c_time._localtime64_s(out_tm, &timestamp_64) == 0;
        }
        return false;
    }

    var time_value = std.math.cast(c_time.time_t, timestamp) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&time_value, out_tm) != null;
    }
    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&time_value) orelse return false;
        out_tm.* = tm_ptr.*;
        return true;
    }
    return false;
}

/// 将 Unix 秒格式化为本地 `yyyy-MM-dd`，让统计日在本地 00:00 切换。
fn localDateFromUnixSeconds(timestamp: i64) ?[10]u8 {
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(timestamp, &tm)) return null;
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

/// 解析 Codex rollout 使用的 UTC ISO-8601 时间戳并返回 Unix 秒。
fn parseUtcTimestampSeconds(value: []const u8) ?i64 {
    if (value.len < 20) return null;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;

    const year = parseDecimal(value[0..4]) orelse return null;
    const month = parseDecimal(value[5..7]) orelse return null;
    const day = parseDecimal(value[8..10]) orelse return null;
    const hour = parseDecimal(value[11..13]) orelse return null;
    const minute = parseDecimal(value[14..16]) orelse return null;
    const second = parseDecimal(value[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;

    var suffix_index: usize = 19;
    if (value[suffix_index] == '.') {
        suffix_index += 1;
        const fraction_start = suffix_index;
        while (suffix_index < value.len and std.ascii.isDigit(value[suffix_index])) : (suffix_index += 1) {}
        if (suffix_index == fraction_start) return null;
    }
    if (suffix_index >= value.len or value[suffix_index] != 'Z' or suffix_index + 1 != value.len) return null;

    const days = daysFromCivil(year, month, day);
    return (((days * 24) + hour) * 60 + minute) * 60 + second;
}

/// 解析只包含十进制数字的时间字段。
fn parseDecimal(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    var result: i64 = 0;
    for (value) |character| {
        if (!std.ascii.isDigit(character)) return null;
        result = result * 10 + (character - '0');
    }
    return result;
}

/// 将公历日期转换为自 Unix epoch 起的天数。
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else 0);
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// 将 UTC 事件时间转换为本地统计日期。
fn localDateFromTimestamp(value: []const u8) ?[10]u8 {
    return localDateFromUnixSeconds(parseUtcTimestampSeconds(value) orelse return null);
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

/// 增量扫描 Codex rollout 文件，仅重新解析签名发生变化的文件。
pub fn scan(allocator: std.mem.Allocator, codex_home: []const u8) !Report {
    return scanWithMode(allocator, codex_home, .incremental);
}

/// 强制重新解析所有 rollout 文件，并刷新增量缓存。
pub fn scanFull(allocator: std.mem.Allocator, codex_home: []const u8) !Report {
    return scanWithMode(allocator, codex_home, .full);
}

/// 按扫描模式合并每个文件的独立贡献，并在成功后写回缓存。
fn scanWithMode(allocator: std.mem.Allocator, codex_home: []const u8, mode: ScanMode) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);
    var cached_files = if (mode == .incremental)
        loadCache(allocator, codex_home) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.ArrayList(FileReport).empty,
        }
    else
        std.ArrayList(FileReport).empty;
    defer deinitFileReports(allocator, &cached_files);
    var updated_files = std.ArrayList(FileReport).empty;
    defer deinitFileReports(allocator, &updated_files);

    const sessions_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "sessions" });
    defer allocator.free(sessions_root);
    scanRoot(allocator, sessions_root, cached_files.items, mode, &updated_files, &report) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    };

    const archived_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "archived_sessions" });
    defer allocator.free(archived_root);
    scanRoot(allocator, archived_root, cached_files.items, mode, &updated_files, &report) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    };
    saveCache(allocator, codex_home, updated_files.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    return report;
}

/// 扫描一个会话根目录，复用未变化文件的缓存贡献。
fn scanRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    cached_files: []const FileReport,
    mode: ScanMode,
    updated_files: *std.ArrayList(FileReport),
    report: *Report,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(app_runtime.io(), root, .{ .iterate = true });
    defer dir.close(app_runtime.io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(app_runtime.io())) |entry| {
        if (entry.kind != .file or !isRolloutFile(entry.path)) continue;
        const path = try std.fs.path.join(allocator, &[_][]const u8{ root, entry.path });
        defer allocator.free(path);
        report.files_scanned += 1;
        const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        var file_report = if (mode == .incremental) blk: {
            if (findCachedFile(cached_files, path, stat.size, stat.mtime.nanoseconds)) |cached| {
                break :blk try cloneFileReport(allocator, cached);
            }
            break :blk try scanFile(allocator, path, stat.size, stat.mtime.nanoseconds);
        } else try scanFile(allocator, path, stat.size, stat.mtime.nanoseconds);
        errdefer file_report.deinit(allocator);
        try mergeFileReport(allocator, report, &file_report);
        try updated_files.append(allocator, file_report);
    }
}

/// 重新解析一个 rollout 文件并返回可替换的独立统计贡献。
fn scanFile(allocator: std.mem.Allocator, path: []const u8, size: u64, mtime_ns: i128) !FileReport {
    var file_report = FileReport{
        .path = try allocator.dupe(u8, path),
        .size = size,
        .mtime_ns = mtime_ns,
    };
    errdefer file_report.deinit(allocator);
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return file_report,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const bytes = registry.readFileAlloc(file, allocator, max_rollout_bytes) catch |err| switch (err) {
        error.StreamTooLong => return file_report,
        else => return err,
    };
    defer allocator.free(bytes);

    var previous: ?UsageTotals = null;
    var has_usage = false;
    var touched_days = std.ArrayList([10]u8).empty;
    defer touched_days.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(TokenLineJson, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
            file_report.parse_errors += 1;
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
            file_report.segmented_sessions += 1;
            break :blk current;
        } else current;
        previous = current;
        if (delta.total_tokens == 0 and delta.input_tokens == 0 and delta.output_tokens == 0) {
            file_report.repeated_snapshots += 1;
            continue;
        }
        const date = localDateFromTimestamp(root.timestamp) orelse continue;
        var is_new_day_for_file = true;
        for (touched_days.items) |touched| {
            if (std.mem.eql(u8, touched[0..], date[0..])) {
                is_new_day_for_file = false;
                break;
            }
        }
        if (is_new_day_for_file) try touched_days.append(allocator, date);
        try addFileDay(allocator, &file_report, date[0..], delta, is_new_day_for_file);
        file_report.totals.add(delta);
        has_usage = true;
    }
    file_report.has_usage = has_usage;
    return file_report;
}

/// 释放文件缓存列表中的全部深层所有权。
fn deinitFileReports(allocator: std.mem.Allocator, reports: *std.ArrayList(FileReport)) void {
    for (reports.items) |*report| report.deinit(allocator);
    reports.deinit(allocator);
}

/// 查找路径、大小和修改时间均一致的缓存贡献。
fn findCachedFile(cached_files: []const FileReport, path: []const u8, size: u64, mtime_ns: i128) ?*const FileReport {
    for (cached_files) |*cached| {
        if (cached.size == size and
            cached.mtime_ns == mtime_ns and
            std.mem.eql(u8, cached.path, path)) return cached;
    }
    return null;
}

/// 深拷贝一个缓存贡献，避免 JSON 缓冲区或旧缓存列表释放后悬空。
fn cloneFileReport(allocator: std.mem.Allocator, source: *const FileReport) !FileReport {
    var cloned = FileReport{
        .path = try allocator.dupe(u8, source.path),
        .size = source.size,
        .mtime_ns = source.mtime_ns,
        .totals = source.totals,
        .has_usage = source.has_usage,
        .repeated_snapshots = source.repeated_snapshots,
        .segmented_sessions = source.segmented_sessions,
        .parse_errors = source.parse_errors,
    };
    errdefer cloned.deinit(allocator);
    for (source.days.items) |day| {
        try cloned.days.append(allocator, .{
            .date = try allocator.dupe(u8, day.date),
            .totals = day.totals,
            .sessions = day.sessions,
        });
    }
    return cloned;
}

/// 将单文件贡献合并到最终报告，同时保持原有质量指标语义。
fn mergeFileReport(allocator: std.mem.Allocator, report: *Report, file_report: *const FileReport) !void {
    report.totals.add(file_report.totals);
    if (file_report.has_usage) report.files_with_usage += 1;
    report.repeated_snapshots += file_report.repeated_snapshots;
    report.segmented_sessions += file_report.segmented_sessions;
    report.parse_errors += file_report.parse_errors;
    for (file_report.days.items) |day| {
        try addDaySessions(allocator, report, day.date, day.totals, day.sessions);
    }
}

/// 向单文件贡献中累加自然日数据，并按文件首次触达日期计算会话数。
fn addFileDay(
    allocator: std.mem.Allocator,
    report: *FileReport,
    date: []const u8,
    delta: UsageTotals,
    new_session: bool,
) !void {
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

/// 返回 Token 文件缓存路径；缓存仅保存统计贡献，不包含认证信息。
fn tokenUsageCachePath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "token-usage-cache.json" });
}

/// 读取并深拷贝缓存文档；损坏或不兼容缓存由调用方降级为全量解析。
fn loadCache(allocator: std.mem.Allocator, codex_home: []const u8) !std.ArrayList(FileReport) {
    const path = try tokenUsageCachePath(allocator, codex_home);
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{});
    defer file.close(app_runtime.io());
    const bytes = try registry.readFileAlloc(file, allocator, max_cache_bytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(CacheDocumentJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.schema_version != cache_schema_version) return error.UnsupportedTokenUsageCacheVersion;

    var files = std.ArrayList(FileReport).empty;
    errdefer deinitFileReports(allocator, &files);
    for (parsed.value.files) |cached| {
        var report = FileReport{
            .path = try allocator.dupe(u8, cached.path),
            .size = cached.size,
            .mtime_ns = cached.mtime_ns,
            .totals = cached.totals,
            .has_usage = cached.has_usage,
            .repeated_snapshots = cached.repeated_snapshots,
            .segmented_sessions = cached.segmented_sessions,
            .parse_errors = cached.parse_errors,
        };
        errdefer report.deinit(allocator);
        for (cached.days) |day| {
            try report.days.append(allocator, .{
                .date = try allocator.dupe(u8, day.date),
                .totals = day.totals,
                .sessions = day.sessions,
            });
        }
        try files.append(allocator, report);
    }
    return files;
}

/// 以私有权限写回最新的逐文件贡献，供下一次增量扫描复用。
fn saveCache(allocator: std.mem.Allocator, codex_home: []const u8, files: []const FileReport) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const out = &aw.writer;
    try out.print("{{\"schema_version\":{d},\"files\":[", .{cache_schema_version});
    for (files, 0..) |file, file_idx| {
        if (file_idx != 0) try out.writeAll(",");
        try out.writeAll("{\"path\":");
        try std.json.Stringify.value(file.path, .{}, out);
        try out.print(",\"size\":{d},\"mtime_ns\":{d},\"totals\":", .{ file.size, file.mtime_ns });
        try writeTotals(out, file.totals);
        try out.writeAll(",\"days\":[");
        for (file.days.items, 0..) |day, day_idx| {
            if (day_idx != 0) try out.writeAll(",");
            try out.writeAll("{\"date\":");
            try std.json.Stringify.value(day.date, .{}, out);
            try out.writeAll(",\"totals\":");
            try writeTotals(out, day.totals);
            try out.print(",\"sessions\":{d}}}", .{day.sessions});
        }
        try out.print("],\"has_usage\":{},\"repeated_snapshots\":{d},\"segmented_sessions\":{d},\"parse_errors\":{d}}}", .{
            file.has_usage,
            file.repeated_snapshots,
            file.segmented_sessions,
            file.parse_errors,
        });
    }
    try out.writeAll("]}");
    try registry.ensureAccountsDir(allocator, codex_home);
    const path = try tokenUsageCachePath(allocator, codex_home);
    defer allocator.free(path);
    try registry.writeFile(path, aw.written());
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

/// 合并已经聚合好的自然日贡献，支持从文件缓存恢复会话计数。
fn addDaySessions(allocator: std.mem.Allocator, report: *Report, date: []const u8, delta: UsageTotals, sessions: usize) !void {
    for (report.days.items) |*day| {
        if (std.mem.eql(u8, day.date, date)) {
            day.totals.add(delta);
            day.sessions += sessions;
            return;
        }
    }
    try report.days.append(allocator, .{
        .date = try allocator.dupe(u8, date),
        .totals = delta,
        .sessions = sessions,
    });
}

fn isRolloutFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
    return std.mem.startsWith(u8, std.fs.path.basename(path), "rollout-");
}
