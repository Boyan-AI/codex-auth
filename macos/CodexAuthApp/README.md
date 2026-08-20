# Codex Switch macOS 菜单栏 App

这是 `codex-auth` 的 macOS 菜单栏账号与路由管理 App，用于在本机快速查看、添加、切换、删除 Codex 连接，并管理直连与本地自动路由。

## 使用方式

以下命令默认从仓库根目录执行。

开发运行，会自动编译 CLI 和菜单栏 App：

```bash
macos/CodexAuthApp/scripts/run-app.sh
```

安装到桌面：

```bash
macos/CodexAuthApp/scripts/install-shortcut.sh desktop
```

安装到 Applications：

```bash
macos/CodexAuthApp/scripts/install-shortcut.sh applications
```

清理本地构建产物：

```bash
macos/CodexAuthApp/scripts/clean.sh
```

## 行为说明

- App 会优先使用打包在 `.app` 内的 `codex-auth` CLI。
- 打包脚本会从版本化的 1024×1024 源图生成 macOS `.icns` 应用图标。
- “新会话”会先选择工作目录，然后优先用 Ghostty 恢复该目录最近的 Codex 会话；没有可恢复会话时会进入新的 Codex 会话。
- 打开 Ghostty 时会复用现有窗口并新建前台 tab；如果还没有 Ghostty 窗口，则新建窗口。
- 如果没有安装 Ghostty，会回退到 macOS Terminal。
- 切换账号只影响新的 Codex CLI 会话；已打开的旧命令行会话不会自动切换账号。
- 菜单栏图标旁会以紧凑两行显示当前活动账号的 5 小时和 7 天剩余额度，并每 60 秒自动刷新。
- 剩余额度低于 20% 时百分比标红，否则标绿。

## 本地产物

脚本默认把构建中间产物放在系统临时目录：

```text
${TMPDIR}/codex-auth-menu-app-build
```

仓库内的 `.build`、`.swiftpm`、`.zig-cache`、`zig-out` 都不是必须保留的产物，可以随时删除后重新构建。
