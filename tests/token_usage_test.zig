const std = @import("std");
const compat_fs = @import("codex_auth").core.compat_fs;
const token_usage = @import("codex_auth").token_usage;

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
