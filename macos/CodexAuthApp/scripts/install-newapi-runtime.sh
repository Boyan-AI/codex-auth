#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXPECTED_NEWAPI_VERSION="v1.0.0-rc.25"
readonly EXPECTED_NEWAPI_SHA256="c287e317f5bbd8112e24af40523525a330a933047082e61308a1b8603d7e485e"
readonly OFFICIAL_UNSTAMPED_VERSION_OUTPUT="v0.0.0"
readonly LAUNCH_AGENT_LABEL="com.codex-auth.newapi"
readonly LAUNCHCTL_BIN="/bin/launchctl"
readonly CURL_BIN="/usr/bin/curl"
readonly SERVICE_LAUNCHER_SOURCE="${SCRIPT_DIR}/newapi-service-launcher.sh"
readonly CREDENTIAL_HELPER_SOURCE="${SCRIPT_DIR}/newapi-credential-helper.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <newapi-macos-binary>" >&2
    exit 64
fi

readonly SOURCE_BINARY_PATH="$1"
readonly USER_HOME="${HOME:?HOME is required}"
readonly USER_DOMAIN="gui/${UID}"
readonly RUNTIME_DIR="${USER_HOME}/Library/Application Support/Codex Auth/NewAPI"
readonly BINARY_DIR="${RUNTIME_DIR}/bin"
readonly DATA_DIR="${RUNTIME_DIR}/data"
readonly LOG_DIR="${RUNTIME_DIR}/logs"
readonly CLIENT_CONFIG_PATH="${RUNTIME_DIR}/client.json"
readonly SERVER_CONFIG_PATH="${RUNTIME_DIR}/server.json"
readonly VERSION_PATH="${RUNTIME_DIR}/VERSION"
readonly NEWAPI_BINARY_PATH="${BINARY_DIR}/new-api"
readonly SERVICE_LAUNCHER_PATH="${BINARY_DIR}/codex-auth-newapi-service"
readonly CREDENTIAL_HELPER_PATH="${BINARY_DIR}/codex-auth-newapi-credential"
readonly SQLITE_PATH="${DATA_DIR}/new-api.db"
readonly LAUNCH_AGENT_PATH="${USER_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
readonly TEMP_DIR="$(mktemp -d /tmp/codex-auth-newapi-install.XXXXXX)"
readonly TEMP_BINARY_PATH="${TEMP_DIR}/new-api"
readonly TEMP_CLIENT_CONFIG_PATH="${TEMP_DIR}/client.json"
readonly TEMP_SERVER_CONFIG_PATH="${TEMP_DIR}/server.json"
readonly TEMP_LAUNCH_AGENT_PATH="${TEMP_DIR}/${LAUNCH_AGENT_LABEL}.plist"

# 仅清理本脚本通过 mktemp 创建的临时目录。
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

# 输出英文错误并使用指定退出码终止安装。
fail() {
    local exit_code="$1"
    shift
    echo "$*" >&2
    exit "${exit_code}"
}

# 计算单个文件的 SHA-256。
file_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

# 返回 LaunchAgent 在当前用户 GUI 域中的完整目标。
service_target() {
    printf '%s/%s' "${USER_DOMAIN}" "${LAUNCH_AGENT_LABEL}"
}

# 使用 launchctl print 判断用户级服务是否已加载。
service_is_loaded() {
    "${LAUNCHCTL_BIN}" print "$(service_target)" >/dev/null 2>&1
}

# 从现有 JSON 中读取字符串，读取失败时终止升级。
read_required_json_value() {
    local path="$1"
    local key="$2"
    local value=""
    value="$(/usr/bin/plutil -extract "${key}" raw -o - "${path}" 2>/dev/null)" || \
        fail 78 "Existing NewAPI configuration is missing ${key}."
    printf '%s' "${value}"
}

# 生成只包含十六进制字符的高熵本机密钥。
generate_secret() {
    /usr/bin/openssl rand -hex 32
}

# 用 plutil 结构化生成应用拥有的客户端 JSON。
build_client_document() {
    local base_url="$1"
    local api_key="$2"
    local plist_path="${TEMP_DIR}/client.plist"
    /usr/bin/plutil -create xml1 "${plist_path}"
    /usr/bin/plutil -insert base_url -string "${base_url}" "${plist_path}"
    /usr/bin/plutil -insert api_key -string "${api_key}" "${plist_path}"
    /usr/bin/plutil -insert runtime_version -string "${EXPECTED_NEWAPI_VERSION}" "${plist_path}"
    /usr/bin/plutil -convert json -o "${TEMP_CLIENT_CONFIG_PATH}" "${plist_path}"
}

# 用 plutil 生成不向 LaunchAgent 暴露会话密钥的服务配置。
build_server_document() {
    local session_secret="$1"
    local plist_path="${TEMP_DIR}/server.plist"
    /usr/bin/plutil -create xml1 "${plist_path}"
    /usr/bin/plutil -insert session_secret -string "${session_secret}" "${plist_path}"
    /usr/bin/plutil -insert sqlite_path -string "${SQLITE_PATH}" "${plist_path}"
    /usr/bin/plutil -insert runtime_version -string "${EXPECTED_NEWAPI_VERSION}" "${plist_path}"
    /usr/bin/plutil -convert json -o "${TEMP_SERVER_CONFIG_PATH}" "${plist_path}"
}

# 用 plutil 生成只调用受保护启动器的用户级 LaunchAgent。
build_launch_agent() {
    /usr/bin/plutil -create xml1 "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert Label -string "${LAUNCH_AGENT_LABEL}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments -array "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments.0 -string "${SERVICE_LAUNCHER_PATH}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert WorkingDirectory -string "${RUNTIME_DIR}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert RunAtLoad -bool true "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert KeepAlive -bool true "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProcessType -string Background "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ThrottleInterval -integer 10 "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert StandardOutPath -string "${LOG_DIR}/stdout.log" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert StandardErrorPath -string "${LOG_DIR}/stderr.log" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -lint "${TEMP_LAUNCH_AGENT_PATH}" >/dev/null
}

# 在覆盖应用拥有文件前创建可恢复备份，不复制 SQLite 数据库。
backup_existing_installation() {
    local has_files="false"
    local path=""
    for path in \
        "${CLIENT_CONFIG_PATH}" \
        "${SERVER_CONFIG_PATH}" \
        "${VERSION_PATH}" \
        "${NEWAPI_BINARY_PATH}" \
        "${SERVICE_LAUNCHER_PATH}" \
        "${CREDENTIAL_HELPER_PATH}" \
        "${LAUNCH_AGENT_PATH}"; do
        if [[ -e "${path}" ]]; then
            has_files="true"
            break
        fi
    done
    [[ "${has_files}" == "true" ]] || return 0

    local backup_root="${RUNTIME_DIR}/backups"
    local backup_dir=""
    install -d -m 700 "${backup_root}"
    backup_dir="$(mktemp -d "${backup_root}/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    for path in \
        "${CLIENT_CONFIG_PATH}" \
        "${SERVER_CONFIG_PATH}" \
        "${VERSION_PATH}" \
        "${NEWAPI_BINARY_PATH}" \
        "${SERVICE_LAUNCHER_PATH}" \
        "${CREDENTIAL_HELPER_PATH}" \
        "${LAUNCH_AGENT_PATH}"; do
        [[ -e "${path}" ]] && /bin/cp -p "${path}" "${backup_dir}/$(basename "${path}")"
    done
}

# 在替换二进制和 LaunchAgent 前停止现有服务。
stop_existing_service() {
    "${LAUNCHCTL_BIN}" bootout "$(service_target)" >/dev/null 2>&1 || true
}

# 对本机状态端点发出不经过代理的短请求并返回 HTTP 状态码。
status_http_code() {
    "${CURL_BIN}" --silent --output /dev/null --write-out '%{http_code}' --max-time 2 --noproxy '*' \
        "http://127.0.0.1:3000/api/status" || true
}

# 等待升级后服务恢复匿名状态端点。
wait_for_healthy_service() {
    local attempt=""
    local status_code="000"
    for attempt in {1..20}; do
        status_code="$(status_http_code)"
        if [[ "${status_code}" == "200" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "NewAPI restart health check failed (status=${status_code})." >&2
    return 1
}

# 校验固定资产、准备配置并原子替换应用拥有的运行文件。
main() {
    [[ -f "${SOURCE_BINARY_PATH}" ]] || fail 66 "NewAPI binary not found: ${SOURCE_BINARY_PATH}"
    [[ -x "${SERVICE_LAUNCHER_SOURCE}" ]] || fail 66 "NewAPI service launcher is missing or not executable."
    [[ -x "${CREDENTIAL_HELPER_SOURCE}" ]] || fail 66 "NewAPI credential helper is missing or not executable."
    [[ "$(file_sha256 "${SOURCE_BINARY_PATH}")" == "${EXPECTED_NEWAPI_SHA256}" ]] || \
        fail 65 "NewAPI binary checksum mismatch."

    /bin/cp "${SOURCE_BINARY_PATH}" "${TEMP_BINARY_PATH}"
    chmod 755 "${TEMP_BINARY_PATH}"
    local version_output=""
    version_output="$("${TEMP_BINARY_PATH}" --version 2>&1 || true)"
    # 官方 rc.25 macOS 资产未注入构建版本并返回 v0.0.0，固定 SHA 仍是资产身份的权威校验。
    [[ "${version_output}" == "${EXPECTED_NEWAPI_VERSION}" || \
        "${version_output}" == "${OFFICIAL_UNSTAMPED_VERSION_OUTPUT}" ]] || \
        fail 65 "NewAPI binary version mismatch."

    local existing_installation="false"
    if [[ -e "${CLIENT_CONFIG_PATH}" || -e "${SERVER_CONFIG_PATH}" ]]; then
        [[ -f "${CLIENT_CONFIG_PATH}" && -f "${SERVER_CONFIG_PATH}" ]] || \
            fail 78 "Existing NewAPI installation is incomplete; client.json and server.json must both exist."
        existing_installation="true"
    elif [[ -e "${NEWAPI_BINARY_PATH}" || -e "${LAUNCH_AGENT_PATH}" ]]; then
        fail 78 "Existing NewAPI installation is incomplete; refusing to replace it."
    fi

    local base_url="http://127.0.0.1:3000/v1"
    local api_key=""
    local session_secret=""
    if [[ "${existing_installation}" == "true" ]]; then
        base_url="$(read_required_json_value "${CLIENT_CONFIG_PATH}" base_url)"
        api_key="$(read_required_json_value "${CLIENT_CONFIG_PATH}" api_key)"
        session_secret="$(read_required_json_value "${SERVER_CONFIG_PATH}" session_secret)"
        local existing_sqlite_path=""
        existing_sqlite_path="$(read_required_json_value "${SERVER_CONFIG_PATH}" sqlite_path)"
        [[ "${base_url}" == "http://127.0.0.1:3000/v1" ]] || \
            fail 78 "Existing NewAPI base URL is outside the managed contract."
        [[ "${existing_sqlite_path}" == "${SQLITE_PATH}" ]] || \
            fail 78 "Existing NewAPI SQLite path is outside the managed runtime."
    else
        session_secret="$(generate_secret)"
    fi

    build_client_document "${base_url}" "${api_key}"
    build_server_document "${session_secret}"
    build_launch_agent

    local was_running="false"
    if service_is_loaded; then
        was_running="true"
    fi

    install -d -m 700 "${RUNTIME_DIR}" "${BINARY_DIR}" "${DATA_DIR}" "${LOG_DIR}"
    install -d -m 755 "${USER_HOME}/Library/LaunchAgents"
    backup_existing_installation
    stop_existing_service

    install -m 755 "${TEMP_BINARY_PATH}" "${NEWAPI_BINARY_PATH}"
    install -m 755 "${SERVICE_LAUNCHER_SOURCE}" "${SERVICE_LAUNCHER_PATH}"
    install -m 755 "${CREDENTIAL_HELPER_SOURCE}" "${CREDENTIAL_HELPER_PATH}"
    install -m 600 "${TEMP_CLIENT_CONFIG_PATH}" "${CLIENT_CONFIG_PATH}"
    install -m 600 "${TEMP_SERVER_CONFIG_PATH}" "${SERVER_CONFIG_PATH}"
    printf '%s\n' "${EXPECTED_NEWAPI_VERSION}" > "${TEMP_DIR}/VERSION"
    install -m 600 "${TEMP_DIR}/VERSION" "${VERSION_PATH}"
    install -m 644 "${TEMP_LAUNCH_AGENT_PATH}" "${LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -lint "${LAUNCH_AGENT_PATH}" >/dev/null

    if [[ "${was_running}" == "true" ]]; then
        "${LAUNCHCTL_BIN}" enable "$(service_target)"
        if ! "${LAUNCHCTL_BIN}" bootstrap "${USER_DOMAIN}" "${LAUNCH_AGENT_PATH}"; then
            "${LAUNCHCTL_BIN}" print "$(service_target)" >/dev/null
        fi
        if ! wait_for_healthy_service; then
            fail 70 "NewAPI files were installed and the service remains loaded, but its health check failed."
        fi
        echo "NewAPI ${EXPECTED_NEWAPI_VERSION} is installed and healthy."
    else
        "${LAUNCHCTL_BIN}" bootout "$(service_target)" >/dev/null 2>&1 || true
        "${LAUNCHCTL_BIN}" disable "$(service_target)"
        echo "NewAPI ${EXPECTED_NEWAPI_VERSION} is installed and stopped."
    fi
    echo "Runtime: ${RUNTIME_DIR}"
}

main "$@"
