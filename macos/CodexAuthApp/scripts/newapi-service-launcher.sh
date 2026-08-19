#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIME_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SERVER_CONFIG_PATH="${RUNTIME_DIR}/server.json"
readonly BINARY_PATH="${SCRIPT_DIR}/new-api"

# 输出英文错误并终止服务启动。
fail() {
    echo "$*" >&2
    exit 78
}

# 从受保护配置中读取必需字符串。
read_required_value() {
    local key="$1"
    local value=""
    value="$(/usr/bin/plutil -extract "${key}" raw -o - "${SERVER_CONFIG_PATH}" 2>/dev/null)" || \
        fail "NewAPI server configuration is missing ${key}."
    [[ -n "${value}" ]] || fail "NewAPI server configuration contains an empty ${key}."
    printf '%s' "${value}"
}

# 校验安装器拥有的路径后，以最小固定环境启动 NewAPI。
main() {
    [[ -x "${BINARY_PATH}" ]] || fail "NewAPI executable is missing."
    [[ -f "${SERVER_CONFIG_PATH}" ]] || fail "NewAPI server configuration is missing."

    local session_secret=""
    local sqlite_path=""
    session_secret="$(read_required_value session_secret)"
    sqlite_path="$(read_required_value sqlite_path)"
    [[ "${sqlite_path}" == "${RUNTIME_DIR}/data/new-api.db" ]] || \
        fail "NewAPI SQLite path is outside the managed runtime."

    export SESSION_SECRET="${session_secret}"
    export SQLITE_PATH="${sqlite_path}"
    export GIN_MODE="release"
    export TRUSTED_PROXIES="none"
    export SHUTDOWN_TIMEOUT_SECONDS="10"
    export TZ="Asia/Shanghai"

    exec "${BINARY_PATH}" --port 3000 --log-dir "${RUNTIME_DIR}/logs"
}

main "$@"
