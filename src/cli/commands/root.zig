const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

const app = @import("app.zig");
const alias = @import("alias.zig");
const clean = @import("clean.zig");
const config = @import("config.zig");
const export_auth = @import("export.zig");
const import_auth = @import("import.zig");
const gui = @import("gui.zig");
const list = @import("list.zig");
const login = @import("login.zig");
const remove = @import("remove.zig");
const switch_account = @import("switch.zig");

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len < 2) return .{ .command = .{ .help = .top_level } };
    const cmd = std.mem.sliceTo(args[1], 0);

    if (common.isHelpFlag(cmd)) {
        if (args.len > 2) {
            return common.usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .help = .top_level } };
    }

    if (std.mem.eql(u8, cmd, "help")) return parseHelpArgs(allocator, args[2..]);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (args.len > 2) {
            return common.usageErrorResult(allocator, .top_level, "unexpected argument after `{s}`: `{s}`.", .{
                cmd,
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .version = {} } };
    }

    if (std.mem.eql(u8, cmd, "-")) {
        if (args.len > 2) {
            return common.usageErrorResult(allocator, .top_level, "unexpected argument after `-`: `{s}`.", .{
                std.mem.sliceTo(args[2], 0),
            });
        }
        return .{ .command = .{ .switch_account = .{ .target = .previous } } };
    }

    if (std.mem.eql(u8, cmd, "list")) return list.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "login")) return login.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "import")) return import_auth.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "export")) return export_auth.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "switch")) return switch_account.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "remove")) return remove.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "alias")) return alias.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "clean")) return clean.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "config")) return config.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "app")) return app.parse(allocator, args[2..]);
    if (std.mem.eql(u8, cmd, "gui")) return gui.parse(allocator, args[2..]);

    return common.usageErrorResult(allocator, .top_level, "unknown command `{s}`.", .{cmd});
}

pub fn freeParseResult(allocator: std.mem.Allocator, result: *types.ParseResult) void {
    switch (result.*) {
        .command => |*cmd| freeCommand(allocator, cmd),
        .usage_error => |usage_err| allocator.free(usage_err.message),
    }
    result.* = undefined;
}

fn freeCommand(allocator: std.mem.Allocator, cmd: *types.Command) void {
    switch (cmd.*) {
        .import_auth => |opts| common.freeImportOptions(allocator, opts.auth_path, opts.alias),
        .export_auth => |opts| {
            if (opts.dest_path) |path| allocator.free(path);
        },
        .switch_account => |opts| switch (opts.target) {
            .query => |query| allocator.free(query),
            else => {},
        },
        .remove_account => |opts| {
            common.freeOwnedStringList(allocator, opts.selectors);
            allocator.free(opts.selectors);
        },
        .alias => |opts| switch (opts) {
            .set => |set_opts| {
                allocator.free(set_opts.selector);
                allocator.free(set_opts.alias);
            },
            .clear => |clear_opts| allocator.free(clear_opts.selector),
        },
        .gui => |opts| switch (opts) {
            .switch_account => |account_key| allocator.free(account_key),
            .remove_account => |account_key| allocator.free(account_key),
            .smart_pool => |pool_opts| allocator.free(pool_opts.account_key),
            .cpa_sync => |sync_opts| {
                allocator.free(sync_opts.account_key);
                allocator.free(sync_opts.auth_dir);
            },
            .import_auth => |import_opts| {
                allocator.free(import_opts.auth_path);
                if (import_opts.alias) |alias_value| allocator.free(alias_value);
            },
            .alias => |alias_opts| switch (alias_opts) {
                .set => |set_opts| {
                    allocator.free(set_opts.account_key);
                    allocator.free(set_opts.alias);
                },
                .clear => |clear_opts| allocator.free(clear_opts.account_key),
            },
            else => {},
        },
        else => {},
    }
    cmd.* = undefined;
}

fn parseHelpArgs(allocator: std.mem.Allocator, rest: []const [:0]const u8) !types.ParseResult {
    if (rest.len == 0) return .{ .command = .{ .help = .top_level } };
    if (rest.len > 1) {
        return common.usageErrorResult(allocator, .top_level, "unexpected argument after `help`: `{s}`.", .{
            std.mem.sliceTo(rest[1], 0),
        });
    }
    const topic_name = std.mem.sliceTo(rest[0], 0);
    const topic = helpTopicForName(topic_name) orelse
        return common.usageErrorResult(allocator, .top_level, "unknown help topic `{s}`.", .{topic_name});
    return .{ .command = .{ .help = topic } };
}

fn helpTopicForName(name: []const u8) ?types.HelpTopic {
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "login")) return .login;
    if (std.mem.eql(u8, name, "import")) return .import_auth;
    if (std.mem.eql(u8, name, "export")) return .export_auth;
    if (std.mem.eql(u8, name, "switch")) return .switch_account;
    if (std.mem.eql(u8, name, "remove")) return .remove_account;
    if (std.mem.eql(u8, name, "alias")) return .alias;
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "config")) return .config;
    if (std.mem.eql(u8, name, "app")) return .app;
    if (std.mem.eql(u8, name, "gui")) return .gui;
    return null;
}
