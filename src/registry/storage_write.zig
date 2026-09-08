const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const clean = @import("clean.zig");
const common = @import("common.zig");

const AccountRecord = common.AccountRecord;
const Registry = common.Registry;
const current_schema_version = common.current_schema_version;
const ensureAccountsDir = common.ensureAccountsDir;
const hardenSensitiveFile = common.hardenSensitiveFile;
const private_file_permissions = common.private_file_permissions;
const registryPath = common.registryPath;
const registryLockPath = common.registryLockPath;
const backupRegistryIfChanged = clean.backupRegistryIfChanged;
const fileEqualsBytes = clean.fileEqualsBytes;

pub fn saveRegistry(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    try ensureAccountsDir(allocator, codex_home);
    var lock_file = try openRegistryLock(allocator, codex_home);
    defer lock_file.close(app_runtime.io());
    try saveRegistryLocked(allocator, codex_home, reg);
}

/// 保存刷新结果时合并当前磁盘路由，避免旧快照覆盖刚完成的路由切换。
pub fn saveRegistryPreservingRoute(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    try ensureAccountsDir(allocator, codex_home);
    var lock_file = try openRegistryLock(allocator, codex_home);
    defer lock_file.close(app_runtime.io());

    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);
    if (try readPersistedGlobalRoute(allocator, path)) |route| {
        reg.global_route = route;
    }
    try saveRegistryLocked(allocator, codex_home, reg);
}

/// 在已持有进程锁时序列化并原子替换注册表文件。
fn saveRegistryLocked(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !void {
    reg.schema_version = current_schema_version;
    const path = try registryPath(allocator, codex_home);
    defer allocator.free(path);

    const out = RegistryOut{
        .schema_version = current_schema_version,
        .global_route = reg.global_route,
        .active_account_key = reg.active_account_key,
        .previous_active_account_key = reg.previous_active_account_key,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .interval_seconds = reg.live.interval_seconds,
        .accounts = reg.accounts.items,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, writer);
    const data = aw.written();

    if (try fileEqualsBytes(allocator, path, data)) {
        try hardenSensitiveFile(path);
        return;
    }

    try backupRegistryIfChanged(allocator, codex_home, path, data);
    try writeRegistryFileAtomic(path, data);
}

/// 创建并独占打开稳定的锁文件；锁文件本身不参与注册表原子替换。
fn openRegistryLock(allocator: std.mem.Allocator, codex_home: []const u8) !std.Io.File {
    const path = try registryLockPath(allocator, codex_home);
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), path, .{
        .read = true,
        .truncate = false,
        .permissions = private_file_permissions,
        .lock = .exclusive,
    });
    errdefer file.close(app_runtime.io());
    try hardenSensitiveFile(path);
    return file;
}

/// 在锁保护下读取已有路由；首次保存还没有注册表时返回空值。
fn readPersistedGlobalRoute(allocator: std.mem.Allocator, path: []const u8) !?common.GlobalRoute {
    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(app_runtime.io());
    const data = try common.readFileAlloc(file, allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |object| object,
        else => return .direct,
    };
    const value = root_obj.get("global_route") orelse return .direct;
    const text = switch (value) {
        .string => |route| route,
        else => return .direct,
    };
    if (std.mem.eql(u8, text, "cpa")) return .cpa;
    if (std.mem.eql(u8, text, "newapi")) return .newapi;
    return .direct;
}

fn writeRegistryFileReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds()) });
    defer allocator.free(temp_path);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.{d}", .{ path, @as(i128, std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds()) });
    defer allocator.free(backup_path);

    {
        var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), temp_path, .{
            .truncate = true,
            .permissions = private_file_permissions,
        });
        defer file.close(app_runtime.io());
        try file.writeStreamingAll(app_runtime.io(), data);
        try file.sync(app_runtime.io());
    }

    const had_original = blk: {
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup_path, app_runtime.io()) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    errdefer {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), temp_path) catch {};
        if (had_original) {
            std.Io.Dir.cwd().rename(backup_path, std.Io.Dir.cwd(), path, app_runtime.io()) catch {};
        }
    }
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, app_runtime.io());
    if (had_original) {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try hardenSensitiveFile(path);
}

fn writeRegistryFileAtomic(path: []const u8, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return writeRegistryFileReplace(path, data);
    }
    var buf: [4096]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(app_runtime.io(), path, .{
        .replace = true,
        .permissions = private_file_permissions,
    });
    defer atomic_file.deinit(app_runtime.io());
    var file_writer = atomic_file.file.writer(app_runtime.io(), &buf);
    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
    try atomic_file.replace(app_runtime.io());
    try hardenSensitiveFile(path);
}

const RegistryOut = struct {
    schema_version: u32,
    global_route: common.GlobalRoute,
    active_account_key: ?[]const u8,
    previous_active_account_key: ?[]const u8,
    active_account_activated_at_ms: ?i64,
    interval_seconds: u16,
    accounts: []const AccountRecord,
};
