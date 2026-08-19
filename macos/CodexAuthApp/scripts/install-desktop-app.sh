#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$HOME/Desktop/Codex Auth.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/CodexAuthApp"
CLI_EXECUTABLE="$APP_BUNDLE/Contents/Resources/codex-auth"
BUNDLE_ID="com.loongphy.codex-auth.menu"
GRACEFUL_STOP_TIMEOUT_SECONDS=5
TERM_STOP_TIMEOUT_SECONDS=3
FORCE_STOP_TIMEOUT_SECONDS=2
START_TIMEOUT_SECONDS=8
STARTUP_REFRESH_TIMEOUT_SECONDS=120

# 查找命令行以指定可执行文件开头的进程，避免误伤其他安装位置的同名进程。
process_ids_for_executable() {
  local executable="$1"
  local pid
  local command

  while read -r pid command; do
    if [[ "$command" == "$executable" || "$command" == "$executable "* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(/bin/ps ax -o pid=,command=)
}

# 汇总桌面 App Bundle 内主程序和内置 CLI 的进程 ID。
bundle_process_ids() {
  process_ids_for_executable "$APP_EXECUTABLE"
  process_ids_for_executable "$CLI_EXECUTABLE"
}

# 判断桌面 App Bundle 是否仍有相关进程运行。
has_bundle_processes() {
  [[ -n "$(bundle_process_ids)" ]]
}

# 在限定时间内等待桌面 App Bundle 的所有相关进程退出。
wait_for_bundle_to_stop() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))

  while has_bundle_processes; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 0.2
  done
}

# 向桌面 App Bundle 的所有相关进程发送指定信号。
signal_bundle_processes() {
  local signal_name="$1"
  local pid

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "-$signal_name" "$pid" 2>/dev/null || true
  done < <(bundle_process_ids)
}

# 异步请求 App 正常退出，并限制 AppleScript 自身的等待时间。
request_graceful_quit() {
  local osascript_pid
  local deadline=$((SECONDS + GRACEFUL_STOP_TIMEOUT_SECONDS))

  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
  osascript_pid=$!
  while kill -0 "$osascript_pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -TERM "$osascript_pid" 2>/dev/null || true
      wait "$osascript_pid" 2>/dev/null || true
      return
    fi
    sleep 0.2
  done
  wait "$osascript_pid" 2>/dev/null || true
}

# 先请求正常退出，超时后逐级终止限定路径内的残留进程。
stop_existing_app() {
  if ! has_bundle_processes; then
    return
  fi

  echo "Stopping the existing desktop app..."
  request_graceful_quit
  if wait_for_bundle_to_stop "$GRACEFUL_STOP_TIMEOUT_SECONDS"; then
    return
  fi

  echo "The app did not quit in time; terminating its remaining processes..." >&2
  signal_bundle_processes TERM
  if wait_for_bundle_to_stop "$TERM_STOP_TIMEOUT_SECONDS"; then
    return
  fi

  echo "The app ignored SIGTERM; forcing its remaining processes to stop..." >&2
  signal_bundle_processes KILL
  if ! wait_for_bundle_to_stop "$FORCE_STOP_TIMEOUT_SECONDS"; then
    echo "Failed to stop the existing desktop app." >&2
    return 1
  fi
}

# 在限定时间内等待新安装的 App 主进程启动。
wait_for_app_to_start() {
  local deadline=$((SECONDS + START_TIMEOUT_SECONDS))

  while [[ -z "$(process_ids_for_executable "$APP_EXECUTABLE")" ]]; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 0.2
  done
}

# 等待启动时的内置 CLI 刷新结束，避免把临时子进程误报为残留进程。
wait_for_startup_refresh() {
  local deadline=$((SECONDS + STARTUP_REFRESH_TIMEOUT_SECONDS))

  sleep 1
  while [[ -n "$(process_ids_for_executable "$CLI_EXECUTABLE")" ]]; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 0.2
  done
}

# 验证桌面 App 只有一个主进程，并返回该进程 ID。
verify_single_app_process() {
  local first_pid
  local second_pid

  first_pid="$(process_ids_for_executable "$APP_EXECUTABLE" | /usr/bin/head -n 1)"
  second_pid="$(process_ids_for_executable "$APP_EXECUTABLE" | /usr/bin/sed -n '2p')"
  if [[ -z "$first_pid" || -n "$second_pid" ]]; then
    echo "Expected exactly one desktop app process after installation." >&2
    return 1
  fi

  printf '%s\n' "$first_pid"
}

# 执行退出、构建安装、启动和进程验证的完整桌面验收流程。
main() {
  local app_pid

  stop_existing_app

  echo "Building and installing the desktop app..."
  "$SCRIPT_DIR/install-shortcut.sh" desktop

  if [[ ! -x "$APP_EXECUTABLE" || ! -x "$CLI_EXECUTABLE" ]]; then
    echo "The installed app bundle is incomplete." >&2
    return 1
  fi

  echo "Launching $APP_BUNDLE..."
  # 检查 Launch Services 的真实返回值，避免仅凭短暂进程误报启动成功。
  if ! /usr/bin/open -n "$APP_BUNDLE"; then
    echo "Launch Services failed to open the desktop app bundle." >&2
    return 1
  fi
  if ! wait_for_app_to_start; then
    echo "The desktop app did not start in time." >&2
    return 1
  fi
  if ! wait_for_startup_refresh; then
    echo "The desktop app started, but its initial refresh did not finish in time." >&2
    return 1
  fi

  app_pid="$(verify_single_app_process)"
  echo "Desktop app installed and running: $APP_BUNDLE (PID $app_pid)"
}

main "$@"
