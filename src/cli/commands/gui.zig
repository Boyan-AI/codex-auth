const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

const StateLikeKind = enum { state, refresh };
const AccountKeyKind = enum { switch_account, remove_account };

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) {
        return common.usageErrorResult(allocator, .gui, "`gui` requires a subcommand.", .{});
    }
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .gui } };
    }

    const subcommand = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, subcommand, "state")) return parseStateLike(allocator, .state, args[1..]);
    if (std.mem.eql(u8, subcommand, "refresh")) return parseStateLike(allocator, .refresh, args[1..]);
    if (std.mem.eql(u8, subcommand, "stats")) return parseStats(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "switch")) return parseAccountKeyCommand(allocator, "gui switch", .switch_account, args[1..]);
    if (std.mem.eql(u8, subcommand, "remove")) return parseAccountKeyCommand(allocator, "gui remove", .remove_account, args[1..]);
    if (std.mem.eql(u8, subcommand, "login")) return parseLogin(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "import")) return parseImport(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "alias")) return parseAlias(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "cpa-route")) return parseCpaRoute(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "newapi-route")) return parseNewApiRoute(allocator, args[1..]);
    if (std.mem.eql(u8, subcommand, "add-key")) return parseAddApiKey(allocator, args[1..]);

    if (common.isHelpFlag(subcommand)) {
        return common.usageErrorResult(allocator, .gui, "`--help` must be used by itself for `gui`.", .{});
    }
    if (std.mem.startsWith(u8, subcommand, "-")) {
        return common.usageErrorResult(allocator, .gui, "unknown flag `{s}` for `gui`.", .{subcommand});
    }
    return common.usageErrorResult(allocator, .gui, "unknown gui subcommand `{s}`.", .{subcommand});
}

/// 解析 NewAPI 全局路由启停参数；调用 Token 只由运行时凭据文件提供。
fn parseNewApiRoute(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "disable")) {
        return .{ .command = .{ .gui = .{ .newapi_route = .disable } } };
    }
    if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "enable")) {
        const base_url = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0));
        errdefer allocator.free(base_url);
        return .{ .command = .{ .gui = .{ .newapi_route = .{ .enable = .{
            .base_url = base_url,
            .client_config_path = try allocator.dupe(u8, std.mem.sliceTo(args[2], 0)),
        } } } } };
    }
    return common.usageErrorResult(
        allocator,
        .gui,
        "`gui newapi-route` requires `enable <base-url> <client-config-path>` or `disable`.",
        .{},
    );
}

/// 解析 CPA 全局路由启停参数；客户端密钥只由运行时凭据文件提供。
fn parseCpaRoute(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "disable")) {
        return .{ .command = .{ .gui = .{ .cpa_route = .disable } } };
    }
    if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "enable")) {
        const base_url = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0));
        errdefer allocator.free(base_url);
        return .{ .command = .{ .gui = .{ .cpa_route = .{ .enable = .{
            .base_url = base_url,
            .client_config_path = try allocator.dupe(u8, std.mem.sliceTo(args[2], 0)),
        } } } } };
    }
    return common.usageErrorResult(
        allocator,
        .gui,
        "`gui cpa-route` requires `enable <base-url> <client-config-path>` or `disable`.",
        .{},
    );
}

/// 解析 API Key 连接创建参数；密钥由调用方通过 CODEX_AUTH_API_KEY 环境变量传递。
fn parseAddApiKey(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len != 3) {
        return common.usageErrorResult(allocator, .gui, "`gui add-key` requires a name, `openai` or `relay`, and a base URL.", .{});
    }
    const provider_text = std.mem.sliceTo(args[1], 0);
    const provider: types.ApiKeyProvider = if (std.mem.eql(u8, provider_text, "openai"))
        .openai
    else if (std.mem.eql(u8, provider_text, "relay"))
        .relay
    else
        return common.usageErrorResult(allocator, .gui, "`gui add-key` provider must be `openai` or `relay`.", .{});
    return .{ .command = .{ .gui = .{ .add_api_key = .{
        .alias = try allocator.dupe(u8, std.mem.sliceTo(args[0], 0)),
        .provider = provider,
        .base_url = try allocator.dupe(u8, std.mem.sliceTo(args[2], 0)),
    } } } };
}

/// 解析 Token 统计扫描模式；默认增量复用缓存，菜单全量刷新使用 `--full`。
fn parseStats(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    var opts: types.GuiStatsOptions = .{};
    for (args) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--full")) {
            if (opts.full) return common.usageErrorResult(allocator, .gui, "duplicate `--full` for `gui stats`.", .{});
            opts.full = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .gui, "unknown flag `{s}` for `gui stats`.", .{arg});
        } else {
            return common.usageErrorResult(allocator, .gui, "unexpected argument `{s}` for `gui stats`.", .{arg});
        }
    }
    return .{ .command = .{ .gui = .{ .stats = opts } } };
}

fn parseStateLike(
    allocator: std.mem.Allocator,
    comptime kind: StateLikeKind,
    args: []const [:0]const u8,
) !types.ParseResult {
    var opts: types.GuiStateOptions = .{};
    for (args) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (common.isHelpFlag(arg)) {
            return common.usageErrorResult(allocator, .gui, "`--help` must be used by itself for `gui`.", .{});
        } else if (std.mem.eql(u8, arg, "--api")) {
            opts.api_mode = .force_api;
        } else if (std.mem.eql(u8, arg, "--skip-api")) {
            opts.api_mode = .skip_api;
        } else if (std.mem.eql(u8, arg, "--active")) {
            opts.active_only = true;
        } else if (std.mem.eql(u8, arg, "--skip-reset-credits")) {
            opts.skip_reset_credits = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .gui, "unknown flag `{s}` for `gui {s}`.", .{ arg, @tagName(kind) });
        } else {
            return common.usageErrorResult(allocator, .gui, "unexpected argument `{s}` for `gui {s}`.", .{ arg, @tagName(kind) });
        }
    }
    if (kind == .state) return .{ .command = .{ .gui = .{ .state = opts } } };
    return .{ .command = .{ .gui = .{ .refresh = opts } } };
}

fn parseAccountKeyCommand(
    allocator: std.mem.Allocator,
    command_name: []const u8,
    comptime kind: AccountKeyKind,
    args: []const [:0]const u8,
) !types.ParseResult {
    if (args.len < 1) return common.usageErrorResult(allocator, .gui, "`{s}` requires an account key.", .{command_name});
    if (args.len > 1) return common.usageErrorResult(allocator, .gui, "unexpected extra argument `{s}` for `{s}`.", .{ std.mem.sliceTo(args[1], 0), command_name });
    const account_key = try allocator.dupe(u8, std.mem.sliceTo(args[0], 0));
    if (kind == .switch_account) return .{ .command = .{ .gui = .{ .switch_account = account_key } } };
    return .{ .command = .{ .gui = .{ .remove_account = account_key } } };
}

fn parseLogin(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    var opts: types.LoginOptions = .{};
    for (args) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--device-auth")) {
            opts.device_auth = true;
        } else {
            return common.usageErrorResult(allocator, .gui, "unexpected argument `{s}` for `gui login`.", .{arg});
        }
    }
    return .{ .command = .{ .gui = .{ .login = opts } } };
}

fn parseImport(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return common.usageErrorResult(allocator, .gui, "`gui import` requires a path.", .{});
    var path: ?[]u8 = null;
    var alias: ?[]u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--alias")) {
            if (i + 1 >= args.len) return common.usageErrorResult(allocator, .gui, "`--alias` requires a value.", .{});
            i += 1;
            alias = try allocator.dupe(u8, std.mem.sliceTo(args[i], 0));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return common.usageErrorResult(allocator, .gui, "unknown flag `{s}` for `gui import`.", .{arg});
        }
        if (path != null) {
            return common.usageErrorResult(allocator, .gui, "unexpected extra argument `{s}` for `gui import`.", .{arg});
        }
        path = try allocator.dupe(u8, arg);
    }
    return .{ .command = .{ .gui = .{ .import_auth = .{ .auth_path = path orelse return common.usageErrorResult(allocator, .gui, "`gui import` requires a path.", .{}), .alias = alias } } } };
}

fn parseAlias(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return common.usageErrorResult(allocator, .gui, "`gui alias` requires `set` or `clear`.", .{});
    const action = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, action, "set")) {
        if (args.len < 3) return common.usageErrorResult(allocator, .gui, "`gui alias set` requires an account key and alias.", .{});
        if (args.len > 3) return common.usageErrorResult(allocator, .gui, "unexpected extra argument `{s}` for `gui alias set`.", .{std.mem.sliceTo(args[3], 0)});
        return .{ .command = .{ .gui = .{ .alias = .{ .set = .{
            .account_key = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0)),
            .alias = try allocator.dupe(u8, std.mem.sliceTo(args[2], 0)),
        } } } } };
    }
    if (std.mem.eql(u8, action, "clear")) {
        if (args.len < 2) return common.usageErrorResult(allocator, .gui, "`gui alias clear` requires an account key.", .{});
        if (args.len > 2) return common.usageErrorResult(allocator, .gui, "unexpected extra argument `{s}` for `gui alias clear`.", .{std.mem.sliceTo(args[2], 0)});
        return .{ .command = .{ .gui = .{ .alias = .{ .clear = .{
            .account_key = try allocator.dupe(u8, std.mem.sliceTo(args[1], 0)),
        } } } } };
    }
    return common.usageErrorResult(allocator, .gui, "unknown gui alias subcommand `{s}`.", .{action});
}
