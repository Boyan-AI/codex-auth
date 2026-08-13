const std = @import("std");
const compat_fs = @import("codex_auth").core.compat_fs;
const token_usage = @import("codex_auth").token_usage;
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

// 验证全量扫描建立缓存后，增量扫描能复用未变文件并吸收变更文件贡献。
test "incremental scan reuses cache and updates changed rollout" {
    const allocator = std.testing.allocator;
    var tmp = compat_fs.tmpDir(.{});
    defer tmp.cleanup();
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("sessions/2026/07/30");

    const first_snapshot =
        "{\"timestamp\":\"2026-07-30T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":5,\"reasoning_output_tokens\":1,\"total_tokens\":15}}}}\n";
    try tmp.dir.writeFile(.{
        .sub_path = "sessions/2026/07/30/rollout-one.jsonl",
        .data = first_snapshot,
    });

    var full = try token_usage.scanFull(allocator, codex_home);
    defer full.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 15), full.totals.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), full.files_scanned);

    var unchanged = try token_usage.scan(allocator, codex_home);
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 15), unchanged.totals.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), unchanged.files_with_usage);

    const second_snapshot =
        "{\"timestamp\":\"2026-07-30T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":5,\"reasoning_output_tokens\":1,\"total_tokens\":15}}}}\n" ++
        "{\"timestamp\":\"2026-07-30T01:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":20,\"cached_input_tokens\":4,\"output_tokens\":8,\"reasoning_output_tokens\":2,\"total_tokens\":28}}}}\n";
    try tmp.dir.writeFile(.{
        .sub_path = "sessions/2026/07/30/rollout-one.jsonl",
        .data = second_snapshot,
    });

    var changed = try token_usage.scan(allocator, codex_home);
    defer changed.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 28), changed.totals.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), changed.days.items.len);
    try std.testing.expectEqual(@as(usize, 1), changed.days.items[0].sessions);
}

// 验证 UTC 时间戳按运行环境本地零点切分统计日，而不是直接截取 UTC 日期。
test "token usage groups events by local calendar day" {
    if (comptime !@hasDecl(c, "setenv") or !@hasDecl(c, "unsetenv") or !@hasDecl(c, "tzset")) return error.SkipZigTest;
    const original_timezone = if (c.getenv("TZ")) |value|
        try std.testing.allocator.dupeZ(u8, std.mem.span(value))
    else
        null;
    defer if (original_timezone) |value| std.testing.allocator.free(value);
    _ = c.setenv("TZ", "UTC-8", 1);
    c.tzset();
    defer {
        if (original_timezone) |value| {
            _ = c.setenv("TZ", value.ptr, 1);
        } else {
            _ = c.unsetenv("TZ");
        }
        c.tzset();
    }

    const allocator = std.testing.allocator;
    var tmp = compat_fs.tmpDir(.{});
    defer tmp.cleanup();
    const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(codex_home);
    try tmp.dir.makePath("sessions/2026/07/30");

    const snapshots =
        "{\"timestamp\":\"2026-07-30T15:59:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10}}}}\n" ++
        "{\"timestamp\":\"2026-07-30T16:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":25}}}}\n";
    try tmp.dir.writeFile(.{
        .sub_path = "sessions/2026/07/30/rollout-local-day.jsonl",
        .data = snapshots,
    });

    var report = try token_usage.scanFull(allocator, codex_home);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.days.items.len);
    try std.testing.expectEqualStrings("2026-07-30", report.days.items[0].date);
    try std.testing.expectEqual(@as(i64, 10), report.days.items[0].totals.total_tokens);
    try std.testing.expectEqualStrings("2026-07-31", report.days.items[1].date);
    try std.testing.expectEqual(@as(i64, 15), report.days.items[1].totals.total_tokens);
}
