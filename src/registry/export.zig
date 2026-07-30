const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const common = @import("common.zig");

const Registry = common.Registry;
const accountAuthPath = common.accountAuthPath;
const accountSnapshotFileName = common.accountSnapshotFileName;
const copyManagedFile = common.copyManagedFile;
const ensurePrivateDir = common.ensurePrivateDir;
const readFileAlloc = common.readFileAlloc;
const writeFile = common.writeFile;

pub const ExportFormat = enum { standard, cpa };

pub const ExportSummary = struct {
    dest_path: []u8,
    exported: usize,

    pub fn deinit(self: *ExportSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.dest_path);
    }
};

pub fn defaultExportDirectory(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "backup" });
}

pub fn exportAccounts(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    maybe_dest_path: ?[]const u8,
    format: ExportFormat,
) !ExportSummary {
    return exportAccountsFiltered(allocator, codex_home, reg, maybe_dest_path, format, false);
}

/// 只导出明确加入智能池的账号，供 CPA 初始认证目录使用。
pub fn exportSmartPoolAccounts(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    maybe_dest_path: ?[]const u8,
    format: ExportFormat,
) !ExportSummary {
    return exportAccountsFiltered(allocator, codex_home, reg, maybe_dest_path, format, true);
}

/// 按智能池过滤条件导出账号，同时保留原有完整导出语义。
fn exportAccountsFiltered(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    maybe_dest_path: ?[]const u8,
    format: ExportFormat,
    smart_pool_only: bool,
) !ExportSummary {
    const dest_path = if (maybe_dest_path) |path|
        try allocator.dupe(u8, path)
    else
        try defaultExportDirectory(allocator, codex_home);
    errdefer allocator.free(dest_path);

    try ensurePrivateDir(dest_path);
    if (smart_pool_only) {
        try removeExcludedCpaFiles(allocator, reg, dest_path);
    }

    var exported: usize = 0;
    for (reg.accounts.items) |rec| {
        if (smart_pool_only and !rec.smart_pool_enabled) continue;
        if (format == .cpa and rec.auth_mode != null and rec.auth_mode.? == .apikey) {
            std.log.warn("skipping API-key account {s}: CPA export requires ChatGPT tokens", .{rec.email});
            continue;
        }

        const src = try accountAuthPath(allocator, codex_home, rec.account_key);
        defer allocator.free(src);

        const base_name = try accountSnapshotFileName(allocator, rec.account_key);
        defer allocator.free(base_name);

        const dest_name = switch (format) {
            .standard => try allocator.dupe(u8, base_name),
            .cpa => try cpaExportFileName(allocator, base_name),
        };
        defer allocator.free(dest_name);

        const dest = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, dest_name });
        defer allocator.free(dest);

        switch (format) {
            .standard => try copyManagedFile(src, dest),
            .cpa => try exportCpaFile(allocator, src, dest),
        }
        exported += 1;
    }

    return .{
        .dest_path = dest_path,
        .exported = exported,
    };
}

/// 同步单个账号的 CPA 凭据副本；排除操作只删除该账号确定性文件名。
pub fn syncCpaAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const Registry,
    account_key: []const u8,
    auth_dir: []const u8,
    enabled: bool,
) !void {
    try ensurePrivateDir(auth_dir);
    const base_name = try accountSnapshotFileName(allocator, account_key);
    defer allocator.free(base_name);
    const dest_name = try cpaExportFileName(allocator, base_name);
    defer allocator.free(dest_name);
    const dest = try std.fs.path.join(allocator, &[_][]const u8{ auth_dir, dest_name });
    defer allocator.free(dest);

    if (!enabled) {
        try removeCpaFile(dest);
        return;
    }

    const rec = for (reg.accounts.items) |candidate| {
        if (std.mem.eql(u8, candidate.account_key, account_key)) break candidate;
    } else return error.AccountNotFound;
    if (!rec.smart_pool_enabled) return error.AccountExcludedFromSmartPool;
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) return error.UnsupportedCpaAuthMode;
    const src = try accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(src);
    try exportCpaFile(allocator, src, dest);
}

/// 全量智能池导出时移除已知且明确排除的旧副本，未知文件保持不变。
fn removeExcludedCpaFiles(
    allocator: std.mem.Allocator,
    reg: *const Registry,
    auth_dir: []const u8,
) !void {
    for (reg.accounts.items) |rec| {
        if (rec.smart_pool_enabled) continue;
        const base_name = try accountSnapshotFileName(allocator, rec.account_key);
        defer allocator.free(base_name);
        const dest_name = try cpaExportFileName(allocator, base_name);
        defer allocator.free(dest_name);
        const dest = try std.fs.path.join(allocator, &[_][]const u8{ auth_dir, dest_name });
        defer allocator.free(dest);
        try removeCpaFile(dest);
    }
}

/// 幂等删除一个确定性 CPA 文件，避免不存在文件阻断状态同步。
fn removeCpaFile(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(app_runtime.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn cpaExportFileName(allocator: std.mem.Allocator, auth_name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, auth_name, ".auth.json")) {
        return try std.mem.concat(allocator, u8, &[_][]const u8{ auth_name[0 .. auth_name.len - ".auth.json".len], ".json" });
    }
    return try std.mem.concat(allocator, u8, &[_][]const u8{ auth_name, ".json" });
}

fn exportCpaFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), src, .{});
    defer file.close(app_runtime.io());
    const data = try readFileAlloc(file, allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const converted = try auth.convertStandardAuthJsonToCpa(allocator, data);
    defer allocator.free(converted);
    const payload = try addCpaProviderDiscriminator(allocator, converted);
    defer allocator.free(payload);
    try writeFile(dest, payload);
}

/// 在 CPA 专用导出边界写入文件认证所需的 Provider 标识，不修改标准认证快照。
fn addCpaProviderDiscriminator(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const trimmed = std.mem.trimStart(u8, data, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidCPAFormat;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\n  \"type\": \"codex\",");
    try out.writer.writeAll(trimmed[1..]);
    return try out.toOwnedSlice();
}
