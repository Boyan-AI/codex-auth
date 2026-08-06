const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const account_api = @import("../api/account.zig");
const me_api = @import("../api/me.zig");
const common = @import("common.zig");
const clean = @import("clean.zig");

const PlanType = common.PlanType;
const RateLimitWindow = common.RateLimitWindow;
const RateLimitSnapshot = common.RateLimitSnapshot;
const Registry = common.Registry;
const AccountRecord = common.AccountRecord;
const activeAuthPath = common.activeAuthPath;
const accountAuthPath = common.accountAuthPath;
const ensureAccountsDir = common.ensureAccountsDir;
const copyManagedFile = common.copyManagedFile;
const hardenSensitiveFile = common.hardenSensitiveFile;
const replaceFilePreservingPermissions = common.replaceFilePreservingPermissions;
const freeAccountRecord = common.freeAccountRecord;
const freeRateLimitSnapshot = common.freeRateLimitSnapshot;
const replaceOptionalStringAlloc = common.replaceOptionalStringAlloc;
const cloneOptionalStringAlloc = common.cloneOptionalStringAlloc;
const resolvePlan = common.resolvePlan;
const readFileIfExists = clean.readFileIfExists;
const fileEqualsBytes = clean.fileEqualsBytes;
const backupDir = clean.backupDir;
const backupAuthIfChanged = clean.backupAuthIfChanged;
const resolveStrictAccountAuthPath = clean.resolveStrictAccountAuthPath;

const codex_config_file_name = "config.toml";
const model_setting_key = "model";
const model_provider_setting_key = "model_provider";
const openai_base_url_setting_key = "openai_base_url";
const service_tier_setting_key = "service_tier";
const approvals_reviewer_setting_key = "approvals_reviewer";
const disable_response_storage_setting_key = "disable_response_storage";
const managed_custom_provider_section = "[model_providers.custom]";
const managed_cpa_provider_section = "[model_providers.codex_auth_cpa]";
const managed_cpa_auth_section = "[model_providers.codex_auth_cpa.auth]";
const cpa_credential_helper_name = "codex-auth-cpa-credential";
const managed_model = "gpt-5.6-sol";
const official_openai_base_url = "https://api.openai.com/v1";

/// 描述一次 Codex 全局路由补丁所需的非敏感输入。
const CodexRoutePreset = union(enum) {
    direct: ?[]const u8,
    cpa: CpaRoutePreset,
};

/// 保存 CPA provider 的回环地址与客户端凭据文件位置。
const CpaRoutePreset = struct {
    base_url: []const u8,
    client_config_path: []const u8,
};

pub fn apiKeyAccountKeyAlloc(allocator: std.mem.Allocator, user_id: []const u8, api_key: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(api_key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "apikey::{s}::{s}", .{ user_id, hex[0..] });
}

pub fn apiKeyAccountNameAlloc(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(api_key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sk-{s}***{s}", .{ hex[0..5], hex[hex.len - 4 ..] });
}

pub fn findAccountIndexByAccountKey(reg: *Registry, account_key: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.account_key, account_key)) return i;
    }
    return null;
}

pub fn setActiveAccountKey(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8) !void {
    if (reg.active_account_key) |k| {
        if (std.mem.eql(u8, k, account_key)) return;
    }
    const previous_active_account_key = if (reg.active_account_key) |k| blk: {
        if (findAccountIndexByAccountKey(reg, k) == null) break :blk null;
        break :blk try allocator.dupe(u8, k);
    } else null;
    errdefer if (previous_active_account_key) |k| allocator.free(k);
    const new_active_account_key = try allocator.dupe(u8, account_key);
    errdefer allocator.free(new_active_account_key);
    if (reg.previous_active_account_key) |k| {
        allocator.free(k);
    }
    reg.previous_active_account_key = previous_active_account_key;
    if (reg.active_account_key) |k| {
        allocator.free(k);
    }
    reg.active_account_key = new_active_account_key;
    reg.active_account_activated_at_ms = std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            rec.last_used_at = now;
            break;
        }
    }
}

pub fn setActiveAccountKeyPreservingPrevious(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8) !void {
    if (reg.active_account_key) |k| {
        if (std.mem.eql(u8, k, account_key)) return;
    }
    const new_active_account_key = try allocator.dupe(u8, account_key);
    if (reg.active_account_key) |k| {
        allocator.free(k);
    }
    reg.active_account_key = new_active_account_key;
    reg.active_account_activated_at_ms = std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            rec.last_used_at = now;
            break;
        }
    }
}

fn clearPreviousActiveAccountKey(allocator: std.mem.Allocator, reg: *Registry) void {
    if (reg.previous_active_account_key) |key| {
        allocator.free(key);
        reg.previous_active_account_key = null;
    }
}

pub fn updateUsage(allocator: std.mem.Allocator, reg: *Registry, account_key: []const u8, snapshot: RateLimitSnapshot) void {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, account_key)) {
            if (rec.last_usage) |*u| {
                if (u.credits) |*c| {
                    if (c.balance) |b| allocator.free(b);
                }
            }
            rec.last_usage = snapshot;
            rec.last_usage_at = now;
            break;
        }
    }
}

pub fn syncActiveAccountFromAuthWithImporter(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry, auto_importer: anytype) !bool {
    if (reg.accounts.items.len == 0) {
        return try auto_importer(allocator, codex_home, reg);
    }

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const auth_bytes_opt = try readFileIfExists(allocator, auth_path);
    if (auth_bytes_opt == null) return false;
    const auth_bytes = auth_bytes_opt.?;
    defer allocator.free(auth_bytes);

    const info = @import("../auth/auth.zig").parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("auth.json sync skipped: {s}", .{@errorName(err)});
            return false;
        },
    };
    defer info.deinit(allocator);

    if (info.auth_mode == .apikey) {
        return try syncActiveApiKeyAccountFromAuth(allocator, codex_home, reg, auth_path, auth_bytes, &info);
    }

    const email = info.email orelse {
        std.log.warn("auth.json missing email; skipping sync", .{});
        return false;
    };
    const record_key = info.record_key orelse {
        std.log.warn("auth.json missing record_key; skipping sync", .{});
        return false;
    };

    const matched_index = findAccountIndexByAccountKey(reg, record_key);
    if (matched_index == null) {
        const dest = try accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try ensureAccountsDir(allocator, codex_home);
        try copyManagedFile(auth_path, dest);

        var record = try accountFromAuth(allocator, "", &info);
        var record_owned = true;
        errdefer if (record_owned) freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
        record_owned = false;
        try setActiveAccountKeyPreservingPrevious(allocator, reg, record_key);
        return true;
    }

    const idx = matched_index.?;
    const rec_account_key = reg.accounts.items[idx].account_key;
    var changed = false;
    if (reg.active_account_key) |k| {
        if (!std.mem.eql(u8, k, rec_account_key)) changed = true;
    } else {
        changed = true;
    }

    if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
        const new_email = try allocator.dupe(u8, email);
        allocator.free(reg.accounts.items[idx].email);
        reg.accounts.items[idx].email = new_email;
        changed = true;
    }
    if (reg.accounts.items[idx].plan != info.plan) {
        changed = true;
    }
    reg.accounts.items[idx].plan = info.plan;
    if (reg.accounts.items[idx].auth_mode != info.auth_mode) {
        changed = true;
    }
    reg.accounts.items[idx].auth_mode = info.auth_mode;

    const dest = try accountAuthPath(allocator, codex_home, rec_account_key);
    defer allocator.free(dest);
    if (!(try fileEqualsBytes(allocator, dest, auth_bytes))) {
        try copyManagedFile(auth_path, dest);
        changed = true;
    } else {
        try hardenSensitiveFile(dest);
    }

    try setActiveAccountKeyPreservingPrevious(allocator, reg, rec_account_key);
    return changed;
}

fn syncActiveApiKeyAccountFromAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: []const u8,
    auth_bytes: []const u8,
    info: *const @import("../auth/auth.zig").AuthInfo,
) !bool {
    const api_key = info.openai_api_key orelse {
        std.log.warn("auth.json missing OPENAI_API_KEY; skipping sync", .{});
        return false;
    };
    var me = me_api.fetchMeForApiKey(allocator, api_key) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("auth.json API key sync skipped: {s}", .{@errorName(err)});
            return false;
        },
    };
    defer me.deinit(allocator);

    const record_key = try apiKeyAccountKeyAlloc(allocator, me.user_id, api_key);
    defer allocator.free(record_key);

    const matched_index = findAccountIndexByAccountKey(reg, record_key);
    if (matched_index == null) {
        const dest = try accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try ensureAccountsDir(allocator, codex_home);
        try copyManagedFile(auth_path, dest);

        var record = try accountFromApiKeyMe(allocator, "", info, &me);
        var record_owned = true;
        errdefer if (record_owned) freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
        record_owned = false;
        try setActiveAccountKeyPreservingPrevious(allocator, reg, record_key);
        return true;
    }

    const idx = matched_index.?;
    const rec_account_key = reg.accounts.items[idx].account_key;
    var changed = false;
    if (reg.active_account_key) |k| {
        if (!std.mem.eql(u8, k, rec_account_key)) changed = true;
    } else {
        changed = true;
    }

    if (!std.mem.eql(u8, reg.accounts.items[idx].email, me.email)) {
        const new_email = try allocator.dupe(u8, me.email);
        allocator.free(reg.accounts.items[idx].email);
        reg.accounts.items[idx].email = new_email;
        changed = true;
    }
    {
        const account_name = try apiKeyAccountNameAlloc(allocator, api_key);
        if (try replaceOptionalStringAlloc(allocator, &reg.accounts.items[idx].account_name, account_name)) {
            changed = true;
        }
        allocator.free(account_name);
    }
    if (reg.accounts.items[idx].auth_mode != .apikey) {
        reg.accounts.items[idx].auth_mode = .apikey;
        changed = true;
    }

    const dest = try accountAuthPath(allocator, codex_home, rec_account_key);
    defer allocator.free(dest);
    if (!(try fileEqualsBytes(allocator, dest, auth_bytes))) {
        try copyManagedFile(auth_path, dest);
        changed = true;
    } else {
        try hardenSensitiveFile(dest);
    }

    try setActiveAccountKeyPreservingPrevious(allocator, reg, rec_account_key);
    return changed;
}

pub fn removeAccounts(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry, indices: []const usize) !void {
    if (indices.len == 0 or reg.accounts.items.len == 0) return;

    var removed = try allocator.alloc(bool, reg.accounts.items.len);
    defer allocator.free(removed);
    @memset(removed, false);
    for (indices) |idx| {
        if (idx < removed.len) removed[idx] = true;
    }

    try deleteRemovedAccountBackups(allocator, codex_home, reg, removed);

    if (reg.active_account_key) |key| {
        var active_removed = false;
        for (reg.accounts.items, 0..) |rec, i| {
            if (removed[i] and std.mem.eql(u8, rec.account_key, key)) {
                active_removed = true;
                break;
            }
        }
        if (active_removed) {
            allocator.free(key);
            reg.active_account_key = null;
            reg.active_account_activated_at_ms = null;
        }
    }

    if (reg.previous_active_account_key) |key| {
        var previous_removed = false;
        for (reg.accounts.items, 0..) |rec, i| {
            if (removed[i] and std.mem.eql(u8, rec.account_key, key)) {
                previous_removed = true;
                break;
            }
        }
        if (previous_removed) {
            clearPreviousActiveAccountKey(allocator, reg);
        }
    }

    var write_idx: usize = 0;
    for (reg.accounts.items, 0..) |*rec, i| {
        if (removed[i]) {
            const preferred_path = try accountAuthPath(allocator, codex_home, rec.account_key);
            defer allocator.free(preferred_path);
            std.Io.Dir.cwd().deleteFile(app_runtime.io(), preferred_path) catch {};
            freeAccountRecord(allocator, rec);
            continue;
        }
        if (write_idx != i) {
            reg.accounts.items[write_idx] = rec.*;
        }
        write_idx += 1;
    }
    reg.accounts.items.len = write_idx;
}

pub fn deleteRemovedAccountBackups(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    removed: []const bool,
) !void {
    const dir_path = try backupDir(allocator, codex_home);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(app_runtime.io());

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "auth.json.bak.")) continue;

        const path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(path);

        var info = @import("../auth/auth.zig").parseAuthInfo(allocator, path) catch continue;
        defer info.deinit(allocator);

        const record_key = info.record_key orelse continue;
        if (!isRemovedAccountKey(reg, removed, record_key)) continue;

        dir.deleteFile(app_runtime.io(), entry.name) catch {};
    }
}

pub fn isRemovedAccountKey(reg: *const Registry, removed: []const bool, record_key: []const u8) bool {
    for (reg.accounts.items, 0..) |rec, i| {
        if (!removed[i]) continue;
        if (std.mem.eql(u8, rec.account_key, record_key)) return true;
    }
    return false;
}

pub fn selectBestAccountIndexByUsage(reg: *Registry) ?usize {
    if (reg.accounts.items.len == 0) return null;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var best_idx: ?usize = null;
    var best_score: i64 = -2;
    var best_seen: i64 = -1;
    for (reg.accounts.items, 0..) |rec, i| {
        const score = usageScoreAt(rec.last_usage, now) orelse -1;
        const seen = rec.last_usage_at orelse -1;
        if (score > best_score) {
            best_score = score;
            best_seen = seen;
            best_idx = i;
        } else if (score == best_score and seen > best_seen) {
            best_seen = seen;
            best_idx = i;
        }
    }
    return best_idx;
}

pub fn usageScoreAt(usage: ?RateLimitSnapshot, now: i64) ?i64 {
    const rate_5h = resolveRateWindow(usage, 300, true);
    const rate_week = resolveRateWindow(usage, 10080, false);
    const rem_5h = remainingPercentAt(rate_5h, now);
    const rem_week = remainingPercentAt(rate_week, now);
    if (rem_5h != null and rem_week != null) return @min(rem_5h.?, rem_week.?);
    if (rem_5h != null) return rem_5h.?;
    if (rem_week != null) return rem_week.?;
    return null;
}

pub fn remainingPercentAt(window: ?RateLimitWindow, now: i64) ?i64 {
    if (window == null) return null;
    if (window.?.resets_at) |resets_at| {
        if (resets_at <= now) return 100;
    }
    const remaining = 100.0 - window.?.used_percent;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

// 按接口明确返回的窗口分钟数解析用量，不再依据 primary/secondary 位置猜测窗口类型。
pub fn resolveRateWindow(usage: ?RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?RateLimitWindow {
    _ = fallback_primary;
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return null;
}

pub fn hasStoredAccountName(rec: *const AccountRecord) bool {
    const account_name = rec.account_name orelse return false;
    return account_name.len != 0;
}

pub fn isTeamAccount(rec: *const AccountRecord) bool {
    const plan = resolvePlan(rec) orelse return false;
    return plan == .team;
}

pub fn inAccountNameRefreshScope(reg: *const Registry, chatgpt_user_id: []const u8, rec: *const AccountRecord) bool {
    _ = reg;
    return std.mem.eql(u8, rec.chatgpt_user_id, chatgpt_user_id);
}

pub fn hasMissingAccountNameForUser(reg: *const Registry, chatgpt_user_id: []const u8) bool {
    for (reg.accounts.items) |rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, &rec)) continue;
        if (isTeamAccount(&rec) and !hasStoredAccountName(&rec)) return true;
    }
    return false;
}

pub fn shouldFetchTeamAccountNamesForUser(reg: *const Registry, chatgpt_user_id: []const u8) bool {
    var account_count: usize = 0;
    var has_team_account = false;
    var has_missing_team_account_name = false;

    for (reg.accounts.items) |rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, &rec)) continue;

        account_count += 1;
        if (!isTeamAccount(&rec)) continue;

        has_team_account = true;
        if (!hasStoredAccountName(&rec)) {
            has_missing_team_account_name = true;
        }
    }

    if (!has_team_account or !has_missing_team_account_name) return false;
    return account_count > 1;
}

pub fn activeChatgptUserId(reg: *Registry) ?[]const u8 {
    const active_account_key = reg.active_account_key orelse return null;
    const idx = findAccountIndexByAccountKey(reg, active_account_key) orelse return null;
    return reg.accounts.items[idx].chatgpt_user_id;
}

pub fn applyAccountNamesForUser(
    allocator: std.mem.Allocator,
    reg: *Registry,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var changed = false;
    for (reg.accounts.items) |*rec| {
        if (!inAccountNameRefreshScope(reg, chatgpt_user_id, rec)) continue;

        var account_name: ?[]const u8 = null;
        var matched = false;
        for (entries) |entry| {
            if (!std.mem.eql(u8, rec.chatgpt_account_id, entry.account_id)) continue;
            account_name = entry.account_name;
            matched = true;
            break;
        }

        if (!matched and !isTeamAccount(rec) and !hasStoredAccountName(rec)) continue;
        if (try replaceOptionalStringAlloc(allocator, &rec.account_name, account_name)) {
            changed = true;
        }
    }
    return changed;
}

pub fn activateAccountByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    const account_index = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try backupAuthIfChanged(allocator, codex_home, dest, src);
    try replaceFilePreservingPermissions(src, dest);
    if (reg.global_route == .direct) {
        try syncCodexConfigForAccount(allocator, codex_home, &reg.accounts.items[account_index]);
    }
    try setActiveAccountKey(allocator, reg, account_key);
}

/// 按当前活动连接同步 Codex 全局预设；API Key 写入自定义 provider，ChatGPT 账号恢复账号预设。
pub fn syncActiveCodexConfig(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
) !void {
    if (reg.global_route == .cpa) return;
    try syncDirectCodexConfig(allocator, codex_home, reg);
}

/// 强制按当前备用直连连接恢复 Codex 预设，不受注册表当前路由状态影响。
fn syncDirectCodexConfig(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
) !void {
    const account_key = reg.active_account_key orelse return;
    var account_index: ?usize = null;
    for (reg.accounts.items, 0..) |account, index| {
        if (std.mem.eql(u8, account.account_key, account_key)) {
            account_index = index;
            break;
        }
    }
    const resolved_index = account_index orelse return error.AccountNotFound;
    try syncCodexConfigForAccount(allocator, codex_home, &reg.accounts.items[resolved_index]);
}

/// 写入 CPA 全局 provider，成功后才切换注册表路由状态。
pub fn enableCpaCodexRoute(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    base_url: []const u8,
    client_config_path: []const u8,
) !void {
    try validateCpaRouteInputs(base_url, client_config_path);
    try syncCodexRoutePreset(allocator, codex_home, .{ .cpa = .{
        .base_url = base_url,
        .client_config_path = client_config_path,
    } });
    reg.global_route = .cpa;
}

/// 恢复当前备用直连连接，成功后才把注册表路由标记为直连。
pub fn disableCpaCodexRoute(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !void {
    if (reg.active_account_key == null) {
        try syncCodexRoutePreset(allocator, codex_home, .{ .direct = null });
    } else {
        try syncDirectCodexConfig(allocator, codex_home, reg);
    }
    reg.global_route = .direct;
}

/// 将指定连接映射到 Codex 全局配置预设，避免账号与 API Key 继承彼此的专属设置。
fn syncCodexConfigForAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account: *const AccountRecord,
) !void {
    const base_url = try codexRoutingBaseURLForAccount(account);
    try syncCodexRoutePreset(allocator, codex_home, .{ .direct = base_url });
}

/// 补丁式更新 Codex 配置并保留原文件权限与非托管内容。
fn syncCodexRoutePreset(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    preset: CodexRoutePreset,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ codex_home, codex_config_file_name });
    defer allocator.free(config_path);

    const existing_permissions = try common.existingFilePermissions(config_path);
    try std.Io.Dir.cwd().createDirPath(app_runtime.io(), codex_home);

    const data = blk: {
        var file = std.Io.Dir.cwd().openFile(app_runtime.io(), config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, ""),
            else => return err,
        };
        defer file.close(app_runtime.io());
        break :blk try common.readFileAlloc(file, allocator, 1024 * 1024);
    };
    defer allocator.free(data);

    const updated = try updateCodexPresetSettingsAlloc(allocator, data, preset);
    defer allocator.free(updated);
    if (std.mem.eql(u8, data, updated)) return;

    var buffer: [4096]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(app_runtime.io(), config_path, .{
        .replace = true,
        .permissions = existing_permissions orelse common.private_file_permissions,
    });
    defer atomic_file.deinit(app_runtime.io());
    var writer = atomic_file.file.writer(app_runtime.io(), &buffer);
    try writer.interface.writeAll(updated);
    try writer.interface.flush();
    try atomic_file.replace(app_runtime.io());
    if (existing_permissions == null) try hardenSensitiveFile(config_path);
}

/// 校验 CPA 路由只能指向本机回环服务，且凭据文件使用绝对路径。
fn validateCpaRouteInputs(base_url: []const u8, client_config_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(client_config_path)) return error.InvalidCpaClientConfigPath;
    const uri = std.Uri.parse(base_url) catch return error.InvalidCpaBaseURL;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidCpaBaseURL;
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidCpaBaseURL;
    }
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Uri.getHost(uri, &host_buffer) catch return error.InvalidCpaBaseURL;
    const is_loopback = std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "::1");
    if (!is_loopback) return error.NonLocalCpaBaseURL;
}

/// 只让 API Key 连接改写 Codex provider；账号订阅模式返回 null 以清理托管路由键。
fn codexRoutingBaseURLForAccount(account: *const AccountRecord) !?[]const u8 {
    if (account.auth_mode == null or account.auth_mode.? != .apikey) return null;
    if (account.provider_kind == .relay) {
        const relay_base_url = account.base_url orelse return error.InvalidBaseURL;
        if (relay_base_url.len == 0) return error.InvalidBaseURL;
        return relay_base_url;
    }
    return official_openai_base_url;
}

/// 同步 TOML 根级预设与 custom provider 表，传入 null 时写入 ChatGPT 账号预设。
fn updateCodexPresetSettingsAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
    preset: CodexRoutePreset,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    var root_settings_closed = false;
    var skipping_custom_provider = false;
    var pending_root_blank_start: ?usize = null;
    var pending_root_blank_end: usize = 0;

    while (offset < data.len) {
        const line_start = offset;
        const newline = std.mem.indexOfScalarPos(u8, data, offset, '\n') orelse data.len;
        const line_end = if (newline < data.len) newline + 1 else newline;
        const line = std.mem.trim(u8, data[line_start..newline], " \t\r");

        if (skipping_custom_provider) {
            if (!isTomlSection(line)) {
                offset = line_end;
                continue;
            }
            skipping_custom_provider = false;
        }
        if (shouldRemoveManagedProviderSection(line, preset)) {
            pending_root_blank_start = null;
            skipping_custom_provider = true;
            offset = line_end;
            continue;
        }
        if (!root_settings_closed and line.len == 0) {
            if (pending_root_blank_start == null) pending_root_blank_start = line_start;
            pending_root_blank_end = line_end;
            offset = line_end;
            continue;
        }
        if (!root_settings_closed and isTomlSection(line)) {
            pending_root_blank_start = null;
            try appendCodexPresetSettings(allocator, &out, preset);
            root_settings_closed = true;
        }
        if (!root_settings_closed and isManagedRootSetting(line)) {
            pending_root_blank_start = null;
            offset = line_end;
            continue;
        }
        if (!root_settings_closed) {
            if (pending_root_blank_start) |blank_start| {
                try out.appendSlice(allocator, data[blank_start..pending_root_blank_end]);
                pending_root_blank_start = null;
            }
        }
        try out.appendSlice(allocator, data[line_start..line_end]);
        offset = line_end;
    }

    if (!root_settings_closed) {
        try appendCodexPresetSettings(allocator, &out, preset);
    }
    return try out.toOwnedSlice(allocator);
}

/// 判断当前行是否开始 TOML 表；根级设置必须插入到首个表之前。
fn isTomlSection(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "[");
}

/// 识别由连接切换统一管理的 TOML 根级键，不接管用户的 reasoning effort。
fn isManagedRootSetting(line: []const u8) bool {
    if (line.len == 0 or line[0] == '#') return false;
    const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const key = std.mem.trim(u8, line[0..equals_index], " \t\r");
    return std.mem.eql(u8, key, model_setting_key) or
        std.mem.eql(u8, key, model_provider_setting_key) or
        std.mem.eql(u8, key, openai_base_url_setting_key) or
        std.mem.eql(u8, key, service_tier_setting_key) or
        std.mem.eql(u8, key, approvals_reviewer_setting_key) or
        std.mem.eql(u8, key, disable_response_storage_setting_key);
}

/// 判断当前 TOML 表是否为 Codex Auth 按 CC Switch 格式托管的 custom provider。
fn isManagedCustomProviderSection(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, managed_custom_provider_section)) return false;
    const suffix = line[managed_custom_provider_section.len..];
    return suffix.len == 0 or suffix[0] == '#' or suffix[0] == ' ' or suffix[0] == '\t';
}

/// 根据目标路由清理 Codex Auth 自己拥有的 provider 表。
fn shouldRemoveManagedProviderSection(line: []const u8, preset: CodexRoutePreset) bool {
    if (isManagedCpaProviderSection(line)) return true;
    return switch (preset) {
        .direct => isManagedCustomProviderSection(line),
        .cpa => false,
    };
}

/// 识别 CPA provider 主表与命令认证子表。
fn isManagedCpaProviderSection(line: []const u8) bool {
    return isExactTomlSection(line, managed_cpa_provider_section) or
        isExactTomlSection(line, managed_cpa_auth_section);
}

/// 匹配允许尾随空白或注释的托管 TOML 表头。
fn isExactTomlSection(line: []const u8, section: []const u8) bool {
    if (!std.mem.startsWith(u8, line, section)) return false;
    const suffix = line[section.len..];
    return suffix.len == 0 or suffix[0] == '#' or suffix[0] == ' ' or suffix[0] == '\t';
}

/// 追加账号或 API Key 对应的 Codex Auth 托管配置，保留 reasoning effort 的默认行为。
fn appendCodexPresetSettings(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    preset: CodexRoutePreset,
) !void {
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
    switch (preset) {
        .direct => |base_url| {
            if (base_url) |url| {
                try out.appendSlice(allocator, model_provider_setting_key ++ " = \"custom\"\n");
                try out.appendSlice(allocator, model_setting_key ++ " = \"" ++ managed_model ++ "\"\n");
                try out.appendSlice(allocator, disable_response_storage_setting_key ++ " = true\n\n");
                try out.appendSlice(allocator, managed_custom_provider_section ++ "\n");
                try out.appendSlice(allocator, "name = \"Sub2API\"\nbase_url = \"");
                try appendTomlBasicStringContent(allocator, out, url);
                try out.appendSlice(allocator, "\"\nwire_api = \"responses\"\nrequires_openai_auth = true\n\n");
                return;
            }
            try out.appendSlice(allocator, model_setting_key ++ " = \"" ++ managed_model ++ "\"\n");
            try out.appendSlice(allocator, service_tier_setting_key ++ " = \"default\"\n");
            try out.appendSlice(allocator, approvals_reviewer_setting_key ++ " = \"auto_review\"\n\n");
        },
        .cpa => |cpa| try appendCpaPresetSettings(allocator, out, cpa),
    }
}

/// 追加 CPA provider 与从 client.json 动态读取 bearer token 的认证命令。
fn appendCpaPresetSettings(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cpa: CpaRoutePreset,
) !void {
    const runtime_dir = std.fs.path.dirname(cpa.client_config_path) orelse return error.InvalidCpaClientConfigPath;
    const credential_helper_path = try std.fs.path.join(
        allocator,
        &.{ runtime_dir, "bin", cpa_credential_helper_name },
    );
    defer allocator.free(credential_helper_path);

    try out.appendSlice(allocator, model_provider_setting_key ++ " = \"codex_auth_cpa\"\n");
    try out.appendSlice(allocator, model_setting_key ++ " = \"" ++ managed_model ++ "\"\n");
    try out.appendSlice(allocator, disable_response_storage_setting_key ++ " = true\n\n");
    try out.appendSlice(allocator, managed_cpa_provider_section ++ "\n");
    try out.appendSlice(allocator, "name = \"Codex Auth CPA\"\nbase_url = \"");
    try appendTomlBasicStringContent(allocator, out, cpa.base_url);
    try out.appendSlice(allocator, "\"\nwire_api = \"responses\"\n\n");
    try out.appendSlice(allocator, managed_cpa_auth_section ++ "\n");
    try out.appendSlice(allocator, "command = \"");
    try appendTomlBasicStringContent(allocator, out, credential_helper_path);
    try out.appendSlice(allocator, "\"\nargs = [\"");
    try appendTomlBasicStringContent(allocator, out, cpa.base_url);
    try out.appendSlice(allocator, "\", \"");
    try appendTomlBasicStringContent(allocator, out, cpa.client_config_path);
    try out.appendSlice(allocator, "\"]\ntimeout_ms = 5000\nrefresh_interval_ms = 0\n\n");
}

/// 转义 TOML 基本字符串内容，避免 Base URL 破坏全局配置语法。
fn appendTomlBasicStringContent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f, 0x7f => return error.InvalidBaseURL,
            else => try out.append(allocator, byte),
        }
    }
}

pub fn replaceActiveAuthWithAccountByKey(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    const account_index = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try replaceFilePreservingPermissions(src, dest);
    if (reg.global_route == .direct) {
        try syncCodexConfigForAccount(allocator, codex_home, &reg.accounts.items[account_index]);
    }
    try setActiveAccountKey(allocator, reg, account_key);
}

pub fn replaceActiveAuthWithAccountByKeyPreservingPrevious(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    account_key: []const u8,
) !void {
    const account_index = findAccountIndexByAccountKey(reg, account_key) orelse return error.AccountNotFound;
    const src = try resolveStrictAccountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);

    const dest = try activeAuthPath(allocator, codex_home);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try replaceFilePreservingPermissions(src, dest);
    if (reg.global_route == .direct) {
        try syncCodexConfigForAccount(allocator, codex_home, &reg.accounts.items[account_index]);
    }
    try setActiveAccountKeyPreservingPrevious(allocator, reg, account_key);
}

pub fn accountFromAuth(
    allocator: std.mem.Allocator,
    alias: []const u8,
    info: *const @import("../auth/auth.zig").AuthInfo,
) !AccountRecord {
    const email = info.email orelse return error.MissingEmail;
    const chatgpt_account_id = info.chatgpt_account_id orelse return error.MissingAccountId;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const chatgpt_user_id = info.chatgpt_user_id orelse return error.MissingChatgptUserId;
    const owned_record_key = try allocator.dupe(u8, record_key);
    errdefer allocator.free(owned_record_key);
    const owned_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
    errdefer allocator.free(owned_chatgpt_account_id);
    const owned_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
    errdefer allocator.free(owned_chatgpt_user_id);
    const owned_email = try allocator.dupe(u8, email);
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    return AccountRecord{
        .account_key = owned_record_key,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_chatgpt_user_id,
        .email = owned_email,
        .alias = owned_alias,
        .account_name = null,
        .plan = info.plan,
        .auth_mode = info.auth_mode,
        .created_at = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
}

pub fn accountFromApiKeyMe(
    allocator: std.mem.Allocator,
    alias: []const u8,
    info: *const @import("../auth/auth.zig").AuthInfo,
    me: *const me_api.MeResult,
) !AccountRecord {
    const api_key = info.openai_api_key orelse return error.MissingOpenAIAPIKey;
    return accountFromApiKeyDetails(allocator, alias, api_key, me);
}

/// 根据已验证的 API Key 身份创建连接记录，调用方负责单独保存密钥快照。
pub fn accountFromApiKeyDetails(
    allocator: std.mem.Allocator,
    alias: []const u8,
    api_key: []const u8,
    me: *const me_api.MeResult,
) !AccountRecord {
    const owned_record_key = try apiKeyAccountKeyAlloc(allocator, me.user_id, api_key);
    errdefer allocator.free(owned_record_key);
    const owned_user_id = try allocator.dupe(u8, me.user_id);
    errdefer allocator.free(owned_user_id);
    const owned_email = try allocator.dupe(u8, me.email);
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    const owned_account_name = try apiKeyAccountNameAlloc(allocator, api_key);
    errdefer allocator.free(owned_account_name);
    const owned_chatgpt_account_id = try allocator.dupe(u8, "");
    errdefer allocator.free(owned_chatgpt_account_id);

    return AccountRecord{
        .account_key = owned_record_key,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_user_id,
        .email = owned_email,
        .alias = owned_alias,
        .account_name = owned_account_name,
        .plan = null,
        .auth_mode = .apikey,
        .created_at = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
}

/// 为不支持身份端点的兼容中转站创建稳定连接记录，密钥和地址共同决定连接标识。
pub fn accountFromApiKeyConnection(
    allocator: std.mem.Allocator,
    alias: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) !AccountRecord {
    var provider_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(base_url, &provider_digest, .{});
    const provider_hex = std.fmt.bytesToHex(provider_digest, .lower);
    const provider_id = try std.fmt.allocPrint(allocator, "relay-{s}", .{provider_hex[0..16]});
    defer allocator.free(provider_id);

    const owned_record_key = try apiKeyAccountKeyAlloc(allocator, provider_id, api_key);
    errdefer allocator.free(owned_record_key);
    const owned_provider_id = try allocator.dupe(u8, provider_id);
    errdefer allocator.free(owned_provider_id);
    const owned_email = try allocator.dupe(u8, "");
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    const owned_account_name = try apiKeyAccountNameAlloc(allocator, api_key);
    errdefer allocator.free(owned_account_name);
    const owned_chatgpt_account_id = try allocator.dupe(u8, "");
    errdefer allocator.free(owned_chatgpt_account_id);

    return .{
        .account_key = owned_record_key,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_provider_id,
        .email = owned_email,
        .alias = owned_alias,
        .account_name = owned_account_name,
        .plan = null,
        .auth_mode = .apikey,
        .created_at = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
}

pub fn recordFreshness(rec: *const AccountRecord) i64 {
    var best = rec.created_at;
    if (rec.last_used_at) |t| {
        if (t > best) best = t;
    }
    if (rec.last_usage_at) |t| {
        if (t > best) best = t;
    }
    return best;
}

pub fn mergeAccountRecord(allocator: std.mem.Allocator, dest: *AccountRecord, incoming: AccountRecord) void {
    var merged_incoming = incoming;
    if (recordFreshness(&merged_incoming) > recordFreshness(dest)) {
        if (merged_incoming.account_name == null and dest.account_name != null) {
            merged_incoming.account_name = cloneOptionalStringAlloc(allocator, dest.account_name) catch unreachable;
        }
        freeAccountRecord(allocator, dest);
        dest.* = merged_incoming;
        return;
    }
    if (merged_incoming.alias.len != 0 and dest.alias.len == 0) {
        const replacement = allocator.dupe(u8, merged_incoming.alias) catch allocator.dupe(u8, "") catch unreachable;
        allocator.free(dest.alias);
        dest.alias = replacement;
    }
    if (dest.account_name == null and merged_incoming.account_name != null) {
        dest.account_name = cloneOptionalStringAlloc(allocator, merged_incoming.account_name) catch unreachable;
    }
    if (dest.plan == null) dest.plan = merged_incoming.plan;
    if (dest.auth_mode == null) dest.auth_mode = merged_incoming.auth_mode;
    freeAccountRecord(allocator, &merged_incoming);
}

pub fn upsertAccount(allocator: std.mem.Allocator, reg: *Registry, record: AccountRecord) !void {
    for (reg.accounts.items) |*rec| {
        if (std.mem.eql(u8, rec.account_key, record.account_key)) {
            mergeAccountRecord(allocator, rec, record);
            return;
        }
    }
    try reg.accounts.append(allocator, record);
}
