const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const usage_api = @import("../api/usage.zig");
const me_api = @import("../api/me.zig");
const cpa_management = @import("../api/cpa_management.zig");
const auth_api = @import("../auth/auth.zig");
const live_flow = @import("live.zig");
const login_workflow = @import("login.zig");
const usage_refresh = @import("usage.zig");
const token_usage = @import("../token_usage.zig");

const reset_credits_refresh_concurrency: usize = 5;

pub fn handleGui(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiOptions) !void {
    switch (opts) {
        .state => |state_opts| try handleState(allocator, codex_home, state_opts, false),
        .refresh => |state_opts| try handleState(allocator, codex_home, state_opts, true),
        .stats => |stats_opts| try handleStats(allocator, codex_home, stats_opts),
        .switch_account => |account_key| try handleSwitch(allocator, codex_home, account_key),
        .login => |login_opts| try handleLogin(allocator, codex_home, login_opts),
        .import_auth => |import_opts| try handleImport(allocator, codex_home, import_opts),
        .remove_account => |account_key| try handleRemove(allocator, codex_home, account_key),
        .alias => |alias_opts| try handleAlias(allocator, codex_home, alias_opts),
        .smart_pool => |pool_opts| try handleSmartPool(allocator, codex_home, pool_opts),
        .cpa_sync => |sync_opts| try handleCpaSync(allocator, codex_home, sync_opts),
        .add_api_key => |add_opts| try handleAddApiKey(allocator, codex_home, add_opts),
    }
}

/// 从受保护环境变量创建 API Key 认证快照；不切换活动直连连接，也不自动加入 CPA。
fn handleAddApiKey(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiAddApiKeyOptions) !void {
    const api_key = try registry.getNonEmptyEnvVarOwned(allocator, "CODEX_AUTH_API_KEY");
    defer if (api_key) |value| allocator.free(value);
    const key = api_key orelse return error.MissingOpenAIAPIKey;
    const normalized_base_url = try normalizeApiKeyBaseURLAlloc(allocator, opts.provider, opts.base_url);
    defer allocator.free(normalized_base_url);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var record = switch (opts.provider) {
        .openai => blk: {
            const endpoint = try apiKeyMeEndpointAlloc(allocator, normalized_base_url);
            defer allocator.free(endpoint);
            var me = try me_api.fetchMeForApiKeyFromEndpoint(allocator, endpoint, key);
            defer me.deinit(allocator);
            break :blk try registry.accountFromApiKeyDetails(allocator, opts.alias, key, &me);
        },
        .relay => try registry.accountFromApiKeyConnection(allocator, opts.alias, key, normalized_base_url),
    };
    var record_owned = true;
    errdefer if (record_owned) registry.freeAccountRecord(allocator, &record);
    record.provider_kind = switch (opts.provider) {
        .openai => .openai,
        .relay => .relay,
    };
    record.base_url = try allocator.dupe(u8, normalized_base_url);
    record.smart_pool_enabled = false;

    var auth_json: std.Io.Writer.Allocating = .init(allocator);
    defer auth_json.deinit();
    try auth_json.writer.writeAll("{\"OPENAI_API_KEY\":");
    try std.json.Stringify.value(key, .{}, &auth_json.writer);
    try auth_json.writer.writeAll("}");
    const auth_path = try registry.accountAuthPath(allocator, codex_home, record.account_key);
    defer allocator.free(auth_path);
    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.writeFile(auth_path, auth_json.written());
    try registry.upsertAccount(allocator, &reg, record);
    record_owned = false;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

/// 规范化 Key provider 地址；远程中转站必须使用 HTTPS，本机开发地址允许 HTTP。
fn normalizeApiKeyBaseURLAlloc(
    allocator: std.mem.Allocator,
    provider: cli.types.ApiKeyProvider,
    raw_base_url: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_base_url, &std.ascii.whitespace);
    const without_trailing_slash = std.mem.trimEnd(u8, trimmed, "/");
    if (without_trailing_slash.len == 0) return error.InvalidBaseURL;
    if (provider == .openai) {
        if (!std.mem.eql(u8, without_trailing_slash, "https://api.openai.com/v1")) return error.InvalidBaseURL;
        return allocator.dupe(u8, without_trailing_slash);
    }

    const uri = std.Uri.parse(without_trailing_slash) catch return error.InvalidBaseURL;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBaseURL;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Uri.getHost(uri, &host_buffer) catch return error.InvalidBaseURL;
    const is_local = std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "::1");
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_local_http = is_local and std.ascii.eqlIgnoreCase(uri.scheme, "http");
    if (!is_https and !is_local_http) return error.InvalidBaseURL;
    return allocator.dupe(u8, without_trailing_slash);
}

/// 由 provider base URL 构造身份端点，统一移除尾部斜杠。
fn apiKeyMeEndpointAlloc(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return error.InvalidBaseURL;
    return std.fmt.allocPrint(allocator, "{s}/me", .{trimmed});
}

/// 分发单账号 CPA 同步与专用认证目录全量对账。
fn handleCpaSync(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiCpaSyncOptions) !void {
    switch (opts) {
        .account => |account_opts| try handleCpaAccountSync(allocator, codex_home, account_opts),
        .reconcile => |auth_dir| try handleCpaReconcile(allocator, codex_home, auth_dir),
    }
}

/// 将单个账号复制到或移出独立 CPA 认证目录，不修改官方 Codex 活动凭据。
fn handleCpaAccountSync(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiCpaAccountSyncOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const idx = registry.findAccountIndexByAccountKey(&reg, opts.account_key) orelse return error.AccountNotFound;
    const record = &reg.accounts.items[idx];
    if (opts.enabled and !record.smart_pool_enabled) return error.AccountExcludedFromSmartPool;
    if (record.auth_mode != null and record.auth_mode.? == .apikey) {
        const management_url = try registry.getNonEmptyEnvVarOwned(allocator, "CODEX_AUTH_CPA_MANAGEMENT_URL");
        defer if (management_url) |value| allocator.free(value);
        const management_key = try registry.getNonEmptyEnvVarOwned(allocator, "CODEX_AUTH_CPA_MANAGEMENT_KEY");
        defer if (management_key) |value| allocator.free(value);
        const endpoint = management_url orelse return error.MissingCpaManagementURL;
        const key = management_key orelse return error.MissingCpaManagementKey;
        const auth_path = try registry.accountAuthPath(allocator, codex_home, record.account_key);
        defer allocator.free(auth_path);
        const info = try auth_api.parseAuthInfo(allocator, auth_path);
        defer info.deinit(allocator);
        const api_key = info.openai_api_key orelse return error.MissingOpenAIAPIKey;
        const base_url = record.base_url orelse return error.InvalidBaseURL;
        try cpa_management.syncCodexApiKey(allocator, endpoint, key, api_key, base_url, opts.enabled);
    } else {
        try registry.syncCpaAccount(allocator, codex_home, &reg, opts.account_key, opts.auth_dir, opts.enabled);
    }

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.writeAll("{\"account_key\":");
    try writeJsonString(out, opts.account_key);
    try out.print(",\"enabled\":{}}}\n", .{opts.enabled});
    try out.flush();
}

/// 依据注册表快照收敛 CPA 认证目录，并返回不含认证内容的计数摘要。
fn handleCpaReconcile(allocator: std.mem.Allocator, codex_home: []const u8, auth_dir: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const summary = try registry.reconcileCpaAccounts(allocator, codex_home, &reg, auth_dir);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("{{\"synced\":{d},\"removed\":{d}}}\n", .{ summary.synced, summary.removed });
    try out.flush();
}

/// 更新账号的智能池成员状态，并返回最新 GUI 状态。
fn handleSmartPool(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.types.GuiSmartPoolOptions,
) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const idx = registry.findAccountIndexByAccountKey(&reg, opts.account_key) orelse return error.AccountNotFound;
    reg.accounts.items[idx].smart_pool_enabled = opts.enabled;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

/// 根据 GUI 请求选择强制全量解析或基于文件签名的增量扫描。
fn handleStats(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiStatsOptions) !void {
    var report = if (opts.full)
        try token_usage.scanFull(allocator, codex_home)
    else
        try token_usage.scan(allocator, codex_home);
    defer report.deinit(allocator);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try token_usage.writeJson(&report, stdout.out());
    try stdout.out().writeAll("\n");
    try stdout.out().flush();
}

fn handleState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.types.GuiStateOptions,
    force_refresh: bool,
) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    const attempted = force_refresh;
    var refresh_state: ?usage_refresh.ForegroundUsageRefreshState = null;
    defer if (refresh_state) |*state| state.deinit(allocator);
    var reset_credits_by_account: ?[]?usage_api.ResetCreditsInfo = null;
    defer if (reset_credits_by_account) |values| {
        for (values) |*value| {
            if (value.*) |*info| info.deinit(std.heap.smp_allocator);
        }
        allocator.free(values);
    };

    if (force_refresh) {
        const usage_api_enabled = apiModeUsesApi(reg.api.usage, opts.api_mode);
        refresh_state = try usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly(
            allocator,
            codex_home,
            &reg,
            usage_api_enabled,
            opts.active_only,
        );
        if (usage_api_enabled) {
            const auth_paths = try allocator.alloc([]u8, reg.accounts.items.len);
            var initialized_paths: usize = 0;
            defer {
                for (auth_paths[0..initialized_paths]) |auth_path| allocator.free(auth_path);
                allocator.free(auth_paths);
            }
            for (reg.accounts.items, 0..) |account, idx| {
                auth_paths[idx] = try registry.accountAuthPath(allocator, codex_home, account.account_key);
                initialized_paths += 1;
            }
            // 打开菜单时以有界并发查询全部账号，完成后仍由 GUI 一次性合并详情。
            reset_credits_by_account = try fetchResetCreditsConcurrently(
                allocator,
                auth_paths,
                reset_credits_refresh_concurrency,
            );
        }
    }
    var active_reset_credits: ?*const usage_api.ResetCreditsInfo = null;
    if (reset_credits_by_account) |values| {
        for (reg.accounts.items, 0..) |account, idx| {
            if (reg.active_account_key) |active_key| {
                if (std.mem.eql(u8, active_key, account.account_key)) {
                    if (values[idx]) |*value| active_reset_credits = value;
                    break;
                }
            }
        }
    }
    try writeStateJson(
        allocator,
        codex_home,
        &reg,
        attempted,
        if (attempted) "ok" else "skipped",
        null,
        active_reset_credits,
        reset_credits_by_account,
        if (refresh_state) |state| state.usage_overrides else null,
    );
}

// 保存 reset credit 并发任务的只读输入、独立结果槽位和原子游标。
const ResetCreditsWorkerQueue = struct {
    auth_paths: []const []const u8,
    values: []?usage_api.ResetCreditsInfo,
    next_index: std.atomic.Value(usize) = .init(0),

    // 每个工作线程仅写入独立索引；返回值统一使用线程安全分配器并由调用方释放。
    fn run(self: *ResetCreditsWorkerQueue) void {
        while (true) {
            const idx = self.next_index.fetchAdd(1, .monotonic);
            if (idx >= self.auth_paths.len) return;
            self.values[idx] = usage_api.fetchResetCreditsForAuthPath(
                std.heap.smp_allocator,
                self.auth_paths[idx],
            ) catch null;
        }
    }
};

// 使用当前线程和有限辅助线程共同消费账号队列，避免单账号超时按账号数累加。
fn fetchResetCreditsConcurrently(
    allocator: std.mem.Allocator,
    auth_paths: []const []const u8,
    max_concurrency: usize,
) ![]?usage_api.ResetCreditsInfo {
    const values = try allocator.alloc(?usage_api.ResetCreditsInfo, auth_paths.len);
    errdefer allocator.free(values);
    for (values) |*value| value.* = null;
    if (auth_paths.len == 0) return values;

    var queue: ResetCreditsWorkerQueue = .{
        .auth_paths = auth_paths,
        .values = values,
    };
    const worker_count = @min(auth_paths.len, @max(@as(usize, 1), max_concurrency));
    const helper_count = worker_count - 1;
    const threads = try allocator.alloc(std.Thread, helper_count);
    defer allocator.free(threads);

    var spawned_count: usize = 0;
    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, ResetCreditsWorkerQueue.run, .{&queue}) catch break;
        spawned_count += 1;
    }
    queue.run();
    for (threads[0..spawned_count]) |thread| thread.join();
    return values;
}

fn handleSwitch(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    try registry.activateAccountByKey(allocator, codex_home, &reg, account_key);
    try registry.saveRegistry(allocator, codex_home, &reg);
    // 切换账号只更新本地活动账号，reset 数据由打开菜单时的后台刷新补齐。
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LoginOptions) !void {
    var before = try registry.loadRegistry(allocator, codex_home);
    defer before.deinit(allocator);
    var known_keys = std.StringHashMap(void).init(allocator);
    defer known_keys.deinit();
    for (before.accounts.items) |account| try known_keys.put(account.account_key, {});

    try login_workflow.handleLogin(allocator, codex_home, opts);
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (reg.active_account_key) |logged_in_key| {
        if (!known_keys.contains(logged_in_key)) {
            const idx = registry.findAccountIndexByAccountKey(&reg, logged_in_key) orelse return error.AccountNotFound;
            reg.accounts.items[idx].smart_pool_enabled = false;
        }
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

fn handleImport(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiImportOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    var report = try registry.importAuthPath(allocator, codex_home, &reg, opts.auth_path, opts.alias);
    defer report.deinit(allocator);
    if (report.appliedCount() > 0) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    if (report.failure != null) return error.ImportFailed;
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

fn handleRemove(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const idx = registry.findAccountIndexByAccountKey(&reg, account_key) orelse return error.AccountNotFound;
    var selected = [_]usize{idx};
    try live_flow.removeSelectedAccountsAndPersist(allocator, codex_home, &reg, selected[0..], false);
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

fn handleAlias(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.GuiAliasOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    switch (opts) {
        .set => |set_opts| {
            const idx = registry.findAccountIndexByAccountKey(&reg, set_opts.account_key) orelse return error.AccountNotFound;
            try validateAlias(&reg, set_opts.alias, idx);
            try replaceAlias(allocator, &reg.accounts.items[idx], set_opts.alias);
        },
        .clear => |clear_opts| {
            const idx = registry.findAccountIndexByAccountKey(&reg, clear_opts.account_key) orelse return error.AccountNotFound;
            try replaceAlias(allocator, &reg.accounts.items[idx], "");
        },
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    try writeStateJson(allocator, codex_home, &reg, false, "skipped", null, null, null, null);
}

// 输出 macOS GUI 使用的状态 JSON，并把本轮刷新失败状态合并到展示层用量字段中。
fn writeStateJson(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
    refresh_attempted: bool,
    refresh_status: []const u8,
    refresh_message: ?[]const u8,
    reset_credits: ?*const usage_api.ResetCreditsInfo,
    reset_credits_by_account: ?[]const ?usage_api.ResetCreditsInfo,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    _ = allocator;
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try out.writeAll("{");
    try out.print("\"schema_version\":{d},", .{reg.schema_version});
    try out.writeAll("\"codex_home\":");
    try writeJsonString(out, codex_home);
    try out.writeAll(",\"active_account_key\":");
    try writeOptionalJsonString(out, reg.active_account_key);
    try out.print(",\"generated_at\":{d},", .{now});
    try out.writeAll("\"reset_credits\":");
    if (reset_credits) |value| {
        try out.print("{{\"available_count\":{d},\"expires_at\":", .{value.available_count});
        try writeOptionalJsonString(out, value.earliest_expires_at);
        try out.writeAll("},");
    } else {
        try out.writeAll("null,");
    }
    try out.print("\"refresh\":{{\"attempted\":{},\"status\":", .{refresh_attempted});
    try writeJsonString(out, refresh_status);
    try out.writeAll(",\"message\":");
    try writeOptionalJsonString(out, refresh_message);
    try out.writeAll("},\"warnings\":[],\"accounts\":[");
    for (reg.accounts.items, 0..) |rec, idx| {
        if (idx != 0) try out.writeAll(",");
        const account_reset_credits = if (reset_credits_by_account) |values|
            if (values[idx]) |*value| value else null
        else
            null;
        try writeAccountJson(out, reg, &rec, now, usageOverrideForAccount(usage_overrides, idx), account_reset_credits);
    }
    try out.writeAll("]}\n");
    try out.flush();
}

// 输出单个账号的 GUI JSON；usage_override 非空时优先展示刷新失败原因。
fn writeAccountJson(
    out: *std.Io.Writer,
    reg: *const registry.Registry,
    rec: *const registry.AccountRecord,
    now: i64,
    usage_override: ?[]const u8,
    reset_credits: ?*const usage_api.ResetCreditsInfo,
) !void {
    try out.writeAll("{\"account_key\":");
    try writeJsonString(out, rec.account_key);
    try out.writeAll(",\"display_name\":");
    try writeJsonString(out, displayName(rec));
    try out.writeAll(",\"alias\":");
    try writeOptionalNonEmptyJsonString(out, rec.alias);
    try out.writeAll(",\"email\":");
    try writeOptionalNonEmptyJsonString(out, rec.email);
    try out.writeAll(",\"account_name\":");
    try writeOptionalJsonString(out, rec.account_name);
    try out.writeAll(",\"plan\":");
    if (registry.resolveDisplayPlan(rec)) |plan| {
        try writeJsonString(out, @tagName(plan));
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"reset_credits\":");
    try writeOptionalResetCreditsJson(out, reset_credits);
    try out.writeAll(",\"auth_mode\":");
    if (rec.auth_mode) |mode| {
        try writeJsonString(out, @tagName(mode));
    } else {
        try out.writeAll("null");
    }
    try out.print(",\"smart_pool_enabled\":{}", .{rec.smart_pool_enabled});
    try out.writeAll(",\"provider_kind\":");
    if (rec.provider_kind) |kind| try writeJsonString(out, @tagName(kind)) else try out.writeAll("null");
    try out.writeAll(",\"base_url\":");
    try writeOptionalJsonString(out, rec.base_url);
    try out.writeAll(",\"balance\":");
    if (rec.balance_snapshot) |snapshot| {
        try out.writeAll("{\"amount\":");
        try writeJsonString(out, snapshot.amount);
        try out.writeAll(",\"currency\":");
        try writeJsonString(out, snapshot.currency);
        try out.print(",\"updated_at\":{d}}}", .{snapshot.updated_at});
    } else try out.writeAll("null");
    const is_active = if (reg.active_account_key) |key| std.mem.eql(u8, key, rec.account_key) else false;
    try out.print(",\"is_active\":{},", .{is_active});
    try out.writeAll("\"usage\":{");
    try out.writeAll("\"five_hour\":");
    try writeOptionalUsageWindowJson(out, registry.resolveRateWindow(rec.last_usage, 300, true), now, usage_override);
    try out.writeAll(",\"seven_day\":");
    try writeUsageWindowJson(out, registry.resolveRateWindow(rec.last_usage, 10080, false), now, usage_override);
    try out.writeAll("},\"last_usage_at\":");
    try writeOptionalInt(out, rec.last_usage_at);
    try out.writeAll(",\"last_refresh_at\":");
    try writeOptionalInt(out, rec.last_usage_at);
    try out.writeAll("}");
}

// 输出单个账号可直接使用的 Codex reset 机会。
fn writeOptionalResetCreditsJson(out: *std.Io.Writer, reset_credits: ?*const usage_api.ResetCreditsInfo) !void {
    if (reset_credits) |value| {
        try out.print("{{\"available_count\":{d},\"expires_at\":", .{value.available_count});
        try writeOptionalJsonString(out, value.earliest_expires_at);
        try out.writeAll("}");
    } else {
        try out.writeAll("null");
    }
}

// 输出可选用量窗口；接口没有明确返回该窗口时使用 null，避免展示猜测数据。
fn writeOptionalUsageWindowJson(
    out: *std.Io.Writer,
    window: ?registry.RateLimitWindow,
    now: i64,
    usage_override: ?[]const u8,
) !void {
    if (window == null) {
        try out.writeAll("null");
        return;
    }
    try writeUsageWindowJson(out, window, now, usage_override);
}

// 输出单个用量窗口；临时超时保留历史值，其他刷新失败用 status 承载可见错误。
fn writeUsageWindowJson(
    out: *std.Io.Writer,
    window: ?registry.RateLimitWindow,
    now: i64,
    usage_override: ?[]const u8,
) !void {
    try out.writeAll("{\"status\":");
    if (usage_override) |value| {
        const should_keep_stale_usage = window != null and std.mem.eql(u8, value, "TimedOut");
        if (!should_keep_stale_usage) {
            try writeJsonString(out, value);
            try out.writeAll(",\"remaining_percent\":null,\"total\":null,\"used\":null,\"reset_at\":null}");
            return;
        }
    }
    if (window == null) {
        try writeJsonString(out, "unknown");
        try out.writeAll(",\"remaining_percent\":null,\"total\":null,\"used\":null,\"reset_at\":null}");
        return;
    }
    const value = window.?;
    try writeJsonString(out, "ok");
    try out.writeAll(",\"remaining_percent\":");
    try writeOptionalInt(out, registry.remainingPercentAt(window, now));
    try out.writeAll(",\"total\":100,\"used\":");
    try out.print("{d}", .{@as(i64, @intFromFloat(value.used_percent))});
    try out.writeAll(",\"reset_at\":");
    try writeOptionalInt(out, value.resets_at);
    try out.writeAll("}");
}

// 读取指定账号的本轮刷新失败状态，越界或未刷新失败时返回 null。
fn usageOverrideForAccount(
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
) ?[]const u8 {
    const overrides = usage_overrides orelse return null;
    if (account_idx >= overrides.len) return null;
    return overrides[account_idx];
}

fn displayName(rec: *const registry.AccountRecord) []const u8 {
    if (rec.alias.len != 0) return rec.alias;
    if (rec.account_name) |account_name| {
        if (account_name.len != 0) return account_name;
    }
    return rec.email;
}

fn writeOptionalInt(out: *std.Io.Writer, value: ?i64) !void {
    if (value) |actual| {
        try out.print("{d}", .{actual});
    } else {
        try out.writeAll("null");
    }
}

fn writeOptionalJsonString(out: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |actual| {
        try writeJsonString(out, actual);
    } else {
        try out.writeAll("null");
    }
}

fn writeOptionalNonEmptyJsonString(out: *std.Io.Writer, value: []const u8) !void {
    if (value.len == 0) {
        try out.writeAll("null");
    } else {
        try writeJsonString(out, value);
    }
}

fn writeJsonString(out: *std.Io.Writer, value: []const u8) !void {
    try out.writeAll("\"");
    for (value) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    var escaped = [_]u8{ '\\', 'u', '0', '0', hex[(ch >> 4) & 0xf], hex[ch & 0xf] };
                    try out.writeAll(&escaped);
                } else {
                    var buf = [_]u8{ch};
                    try out.writeAll(&buf);
                }
            },
        }
    }
    try out.writeAll("\"");
}

fn replaceAlias(allocator: std.mem.Allocator, rec: *registry.AccountRecord, alias_value: []const u8) !void {
    const owned_alias = try allocator.dupe(u8, alias_value);
    allocator.free(rec.alias);
    rec.alias = owned_alias;
}

fn validateAlias(reg: *const registry.Registry, alias_value: []const u8, selected_idx: usize) !void {
    if (alias_value.len == 0) return error.InvalidAlias;
    for (alias_value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidAlias;
    }
    for (reg.accounts.items, 0..) |rec, idx| {
        if (idx == selected_idx) continue;
        if (rec.alias.len != 0 and std.ascii.eqlIgnoreCase(rec.alias, alias_value)) {
            return error.DuplicateAlias;
        }
    }
}

fn apiModeUsesApi(default_enabled: bool, mode: cli.types.ApiMode) bool {
    return switch (mode) {
        .default => default_enabled,
        .force_api => true,
        .skip_api => false,
    };
}

// 验证确定性错误会覆盖历史用量，防止继续展示已失效账号的旧数据。
test "writeUsageWindowJson uses non-timeout override instead of stale usage" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeUsageWindowJson(
        &writer,
        .{
            .used_percent = 34,
            .window_minutes = 300,
            .resets_at = 4_102_444_800,
        },
        1_800_000_000,
        "401 token_invalidated",
    );

    try std.testing.expectEqualStrings(
        "{\"status\":\"401 token_invalidated\",\"remaining_percent\":null,\"total\":null,\"used\":null,\"reset_at\":null}",
        writer.buffered(),
    );
}

// 验证临时超时时继续输出上一次成功用量和原重置时间。
test "writeUsageWindowJson keeps stale usage on timeout" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeUsageWindowJson(
        &writer,
        .{
            .used_percent = 34,
            .window_minutes = 300,
            .resets_at = 4_102_444_800,
        },
        1_800_000_000,
        "TimedOut",
    );

    try std.testing.expectEqualStrings(
        "{\"status\":\"ok\",\"remaining_percent\":66,\"total\":100,\"used\":34,\"reset_at\":4102444800}",
        writer.buffered(),
    );
}

// 验证从未成功获取用量时不会把超时伪装成有效数据。
test "writeUsageWindowJson exposes timeout without stale usage" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeUsageWindowJson(&writer, null, 1_800_000_000, "TimedOut");

    try std.testing.expectEqualStrings(
        "{\"status\":\"TimedOut\",\"remaining_percent\":null,\"total\":null,\"used\":null,\"reset_at\":null}",
        writer.buffered(),
    );
}

// 验证接口未返回 300 分钟窗口时 GUI 使用 null，并忽略账号级错误覆盖。
test "writeOptionalUsageWindowJson omits missing window" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeOptionalUsageWindowJson(&writer, null, 1_800_000_000, "401 token_invalidated");

    try std.testing.expectEqualStrings("null", writer.buffered());
}
