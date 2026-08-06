#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXPECTED_CPA_VERSION="7.2.120"
readonly EXPECTED_CPA_ARCHIVE_SHA256="01ebcb3a683560c91f532fb124ac30edcc68945859e3ddf4880e09f1979ffdee"
readonly EXPECTED_PANEL_VERSION="v1.21.4"
readonly EXPECTED_PANEL_SHA256="1d885552cc2d12b98613f31f2bc326e321c81dcbb792afb1e0b0066ecb74028e"
readonly LAUNCH_AGENT_LABEL="com.codex-auth.cpa"
readonly LEGACY_LAUNCH_AGENT_LABEL="com.boyan.codex-auth-cpa"
readonly LEGACY_INSTALLER_VERSION="7.2.109"
readonly LAUNCHCTL_BIN="/bin/launchctl"
readonly CURL_BIN="/usr/bin/curl"
readonly CREDENTIAL_HELPER_SOURCE="${SCRIPT_DIR}/cpa-credential-helper.sh"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <release-archive> <management-html>" >&2
    exit 64
fi

readonly ARCHIVE_PATH="$1"
readonly PANEL_PATH="$2"
readonly USER_HOME="${HOME:?HOME is required}"
readonly USER_DOMAIN="gui/${UID}"
readonly RUNTIME_DIR="${USER_HOME}/Library/Application Support/Codex Auth/CPA"
readonly BINARY_DIR="${RUNTIME_DIR}/bin"
readonly AUTH_DIR="${RUNTIME_DIR}/auth"
readonly LOG_DIR="${RUNTIME_DIR}/logs"
readonly STATIC_DIR="${RUNTIME_DIR}/static"
readonly CONFIG_PATH="${RUNTIME_DIR}/config.yaml"
readonly CLIENT_PATH="${RUNTIME_DIR}/client.json"
readonly CREDENTIAL_HELPER_PATH="${BINARY_DIR}/codex-auth-cpa-credential"
readonly VERSION_PATH="${RUNTIME_DIR}/VERSION"
readonly PANEL_VERSION_PATH="${RUNTIME_DIR}/PANEL_VERSION"
readonly LAUNCH_AGENT_PATH="${USER_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
readonly LEGACY_LAUNCH_AGENT_PATH="${USER_HOME}/Library/LaunchAgents/${LEGACY_LAUNCH_AGENT_LABEL}.plist"
readonly TEMP_DIR="$(mktemp -d /tmp/codex-auth-cpa-install.XXXXXX)"
readonly TEMP_CLIENT_PATH="${TEMP_DIR}/client.json"
readonly TEMP_CONFIG_PATH="${TEMP_DIR}/config.yaml"
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

# 计算文件 SHA-256，供两个固定上游资产共用。
file_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

# 在解压或写入前校验固定资产摘要。
verify_asset() {
    local path="$1"
    local expected_sha="$2"
    local label="$3"
    [[ -f "${path}" ]] || fail 66 "${label} not found: ${path}"
    local actual_sha=""
    actual_sha="$(file_sha256 "${path}")"
    [[ "${actual_sha}" == "${expected_sha}" ]] || fail 65 "${label} checksum mismatch."
}

# 返回给定 LaunchAgent 标签在当前用户 GUI 域中的完整目标。
service_target() {
    printf '%s/%s' "${USER_DOMAIN}" "$1"
}

# 使用 launchctl print 判断新旧用户级服务是否已加载。
service_is_loaded() {
    "${LAUNCHCTL_BIN}" print "$(service_target "$1")" >/dev/null 2>&1
}

# 从现有受保护 JSON 中读取字符串，缺失时返回空值。
read_client_value() {
    /usr/bin/plutil -extract "$1" raw -o - "${CLIENT_PATH}" 2>/dev/null || true
}

# 为首次安装生成不含特殊 YAML 字符的随机密钥。
generate_secret() {
    /usr/bin/openssl rand -hex 32
}

# 用 plutil 结构化生成应用拥有的客户端 JSON。
build_client_document() {
    local base_url="$1"
    local api_key="$2"
    local management_key="$3"
    local auth_directory="$4"
    local client_plist="${TEMP_DIR}/client.plist"
    /usr/bin/plutil -create xml1 "${client_plist}"
    /usr/bin/plutil -insert base_url -string "${base_url}" "${client_plist}"
    /usr/bin/plutil -insert api_key -string "${api_key}" "${client_plist}"
    /usr/bin/plutil -insert management_key -string "${management_key}" "${client_plist}"
    /usr/bin/plutil -insert auth_directory -string "${auth_directory}" "${client_plist}"
    /usr/bin/plutil -insert runtime_version -string "${EXPECTED_CPA_VERSION}" "${client_plist}"
    /usr/bin/plutil -insert management_panel_version -string "${EXPECTED_PANEL_VERSION}" "${client_plist}"
    /usr/bin/plutil -convert json -o "${TEMP_CLIENT_PATH}" "${client_plist}"
}

# 用 plutil 生成固定标签和本地面板路径的用户级 LaunchAgent。
build_launch_agent() {
    /usr/bin/plutil -create xml1 "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert Label -string "${LAUNCH_AGENT_LABEL}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments -array "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments.0 -string "${BINARY_DIR}/cli-proxy-api" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments.1 -string "-config" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert ProgramArguments.2 -string "${CONFIG_PATH}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert WorkingDirectory -string "${RUNTIME_DIR}" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert EnvironmentVariables -dictionary "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert EnvironmentVariables.MANAGEMENT_STATIC_PATH -string "${STATIC_DIR}" \
        "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert RunAtLoad -bool true "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert KeepAlive -bool true "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert StandardOutPath -string "${LOG_DIR}/stdout.log" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -insert StandardErrorPath -string "${LOG_DIR}/stderr.log" "${TEMP_LAUNCH_AGENT_PATH}"
    /usr/bin/plutil -lint "${TEMP_LAUNCH_AGENT_PATH}" >/dev/null
}

# 首次安装时只生成应用基础设施字段，其他 CPA 配置交给原生面板。
build_initial_configuration() {
    local api_key="$1"
    local management_key="$2"
    local escaped_auth_dir=""
    escaped_auth_dir="$(printf '%s' "${AUTH_DIR}" | /usr/bin/sed "s/'/''/g")"
    cat > "${TEMP_CONFIG_PATH}" <<EOF
host: "127.0.0.1"
port: 8317

remote-management:
  allow-remote: false
  secret-key: "${management_key}"
  disable-control-panel: false
  disable-auto-update-panel: true

auth-dir: '${escaped_auth_dir}'

api-keys:
  - "${api_key}"
EOF
    chmod 600 "${TEMP_CONFIG_PATH}"
}

# 统计配置中完全匹配的单行，用于识别旧安装器拥有的规范契约。
exact_line_count() {
    /usr/bin/awk -v expected="$2" '$0 == expected { count++ } END { print count + 0 }' "$1"
}

# 统计字段前缀，防止重复键或用户改动被误判为可迁移旧契约。
field_prefix_count() {
    /usr/bin/awk -v prefix="$2" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$1"
}

# 仅对明确来自 7.2.109 安装器的安全配置定向开启面板，不重写其他内容。
migrate_legacy_owned_configuration() {
    local previous_version="$1"
    [[ "${previous_version}" == "${LEGACY_INSTALLER_VERSION}" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "host:")" == "1" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "port:")" == "1" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "remote-management:")" == "1" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "  allow-remote:")" == "1" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "  disable-control-panel:")" == "1" ]] || return 0
    [[ "$(field_prefix_count "${CONFIG_PATH}" "  disable-auto-update-panel:")" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" 'host: "127.0.0.1"')" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" 'port: 8317')" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" 'remote-management:')" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" '  allow-remote: false')" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" '  disable-control-panel: true')" == "1" ]] || return 0
    [[ "$(exact_line_count "${CONFIG_PATH}" '  disable-auto-update-panel: true')" == "1" ]] || return 0

    /usr/bin/awk '
        $0 == "  disable-control-panel: true" { print "  disable-control-panel: false"; next }
        { print }
    ' "${CONFIG_PATH}" > "${TEMP_DIR}/migrated-config.yaml"
    install -m 600 "${TEMP_DIR}/migrated-config.yaml" "${CONFIG_PATH}"
}

# 覆盖应用拥有文件前创建带时间的可恢复备份，不备份或改动账号目录。
backup_existing_installation() {
    local has_files="false"
    local path=""
    for path in \
        "${CONFIG_PATH}" \
        "${CLIENT_PATH}" \
        "${CREDENTIAL_HELPER_PATH}" \
        "${BINARY_DIR}/cli-proxy-api" \
        "${STATIC_DIR}/management.html" \
        "${VERSION_PATH}" \
        "${PANEL_VERSION_PATH}" \
        "${LAUNCH_AGENT_PATH}" \
        "${LEGACY_LAUNCH_AGENT_PATH}"; do
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
    [[ -e "${CONFIG_PATH}" ]] && /bin/cp -p "${CONFIG_PATH}" "${backup_dir}/config.yaml"
    [[ -e "${CLIENT_PATH}" ]] && /bin/cp -p "${CLIENT_PATH}" "${backup_dir}/client.json"
    [[ -e "${CREDENTIAL_HELPER_PATH}" ]] && \
        /bin/cp -p "${CREDENTIAL_HELPER_PATH}" "${backup_dir}/codex-auth-cpa-credential"
    [[ -e "${BINARY_DIR}/cli-proxy-api" ]] && \
        /bin/cp -p "${BINARY_DIR}/cli-proxy-api" "${backup_dir}/cli-proxy-api"
    [[ -e "${STATIC_DIR}/management.html" ]] && \
        /bin/cp -p "${STATIC_DIR}/management.html" "${backup_dir}/management.html"
    [[ -e "${VERSION_PATH}" ]] && /bin/cp -p "${VERSION_PATH}" "${backup_dir}/VERSION"
    [[ -e "${PANEL_VERSION_PATH}" ]] && \
        /bin/cp -p "${PANEL_VERSION_PATH}" "${backup_dir}/PANEL_VERSION"
    [[ -e "${LAUNCH_AGENT_PATH}" ]] && \
        /bin/cp -p "${LAUNCH_AGENT_PATH}" "${backup_dir}/${LAUNCH_AGENT_LABEL}.plist"
    [[ -e "${LEGACY_LAUNCH_AGENT_PATH}" ]] && \
        /bin/cp -p "${LEGACY_LAUNCH_AGENT_PATH}" "${backup_dir}/${LEGACY_LAUNCH_AGENT_LABEL}.plist"
    return 0
}

# 在替换二进制和 LaunchAgent 前停止新旧标签，防止运行中文件竞态。
stop_existing_services() {
    "${LAUNCHCTL_BIN}" bootout "$(service_target "${LAUNCH_AGENT_LABEL}")" >/dev/null 2>&1 || true
    "${LAUNCHCTL_BIN}" bootout "$(service_target "${LEGACY_LAUNCH_AGENT_LABEL}")" >/dev/null 2>&1 || true
    "${LAUNCHCTL_BIN}" disable "$(service_target "${LEGACY_LAUNCH_AGENT_LABEL}")" >/dev/null 2>&1 || true
}

# 对本机端点发出不经过代理的短请求并只返回 HTTP 状态码。
http_status() {
    local url="$1"
    local header_name="${2:-}"
    local header_value="${3:-}"
    if [[ -n "${header_name}" ]]; then
        "${CURL_BIN}" --silent --output /dev/null --write-out '%{http_code}' --max-time 2 --noproxy '*' \
            --header "${header_name}: ${header_value}" "${url}" || true
    else
        "${CURL_BIN}" --silent --output /dev/null --write-out '%{http_code}' --max-time 2 --noproxy '*' \
            "${url}" || true
    fi
}

# 恢复升级前的开启状态后，仅验证进程和客户端 Key；配置兼容性由应用独立报告。
wait_for_healthy_service() {
    local api_key="$1"
    local model_status="000"
    local attempt=""
    for attempt in {1..15}; do
        model_status="$(http_status "http://127.0.0.1:8317/v1/models" "Authorization" "Bearer ${api_key}")"
        if [[ "${model_status}" == "200" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "CPA restart health check failed (models=${model_status})." >&2
    return 1
}

verify_asset "${ARCHIVE_PATH}" "${EXPECTED_CPA_ARCHIVE_SHA256}" "Release archive"
verify_asset "${PANEL_PATH}" "${EXPECTED_PANEL_SHA256}" "Management panel"
[[ -x "${CREDENTIAL_HELPER_SOURCE}" ]] || fail 66 "CPA credential helper is missing or not executable."

/usr/bin/tar -xzf "${ARCHIVE_PATH}" -C "${TEMP_DIR}"
[[ -x "${TEMP_DIR}/cli-proxy-api" ]] || fail 65 "Release archive does not contain executable cli-proxy-api."
readonly VERSION_OUTPUT="$("${TEMP_DIR}/cli-proxy-api" -h 2>&1 || true)"
[[ "${VERSION_OUTPUT}" == *"CLIProxyAPI Version: ${EXPECTED_CPA_VERSION},"* ]] || \
    fail 65 "Release archive version mismatch."

existing_installation="false"
if [[ -e "${CONFIG_PATH}" || -e "${CLIENT_PATH}" ]]; then
    [[ -f "${CONFIG_PATH}" && -f "${CLIENT_PATH}" ]] || \
        fail 78 "Existing CPA installation is incomplete; config.yaml and client.json must both exist."
    existing_installation="true"
elif [[ -e "${BINARY_DIR}/cli-proxy-api" || -e "${LAUNCH_AGENT_PATH}" || -e "${LEGACY_LAUNCH_AGENT_PATH}" ]]; then
    fail 78 "Existing CPA installation is incomplete; refusing to replace it."
fi

previous_version=""
[[ -f "${VERSION_PATH}" ]] && previous_version="$(<"${VERSION_PATH}")"
base_url="http://127.0.0.1:8317/v1"
api_key=""
management_key=""
auth_directory="${AUTH_DIR}"
if [[ "${existing_installation}" == "true" ]]; then
    base_url="$(read_client_value base_url)"
    api_key="$(read_client_value api_key)"
    management_key="$(read_client_value management_key)"
    auth_directory="$(read_client_value auth_directory)"
    [[ -n "${base_url}" ]] || fail 78 "Existing client.json is missing base_url."
    [[ -n "${api_key}" ]] || fail 78 "Existing client.json is missing api_key."
    [[ -n "${management_key}" ]] || fail 78 "Existing client.json is missing management_key."
    [[ -n "${auth_directory}" ]] || auth_directory="${AUTH_DIR}"
else
    api_key="$(generate_secret)"
    management_key="$(generate_secret)"
    build_initial_configuration "${api_key}" "${management_key}"
fi

build_client_document "${base_url}" "${api_key}" "${management_key}" "${auth_directory}"
build_launch_agent

was_running="false"
if service_is_loaded "${LAUNCH_AGENT_LABEL}" || service_is_loaded "${LEGACY_LAUNCH_AGENT_LABEL}"; then
    was_running="true"
fi

install -d -m 700 "${RUNTIME_DIR}" "${BINARY_DIR}" "${AUTH_DIR}" "${LOG_DIR}" "${STATIC_DIR}"
install -d -m 755 "${USER_HOME}/Library/LaunchAgents"
backup_existing_installation
stop_existing_services

install -m 755 "${TEMP_DIR}/cli-proxy-api" "${BINARY_DIR}/cli-proxy-api"
install -m 755 "${CREDENTIAL_HELPER_SOURCE}" "${CREDENTIAL_HELPER_PATH}"
[[ -f "${TEMP_DIR}/LICENSE" ]] && install -m 644 "${TEMP_DIR}/LICENSE" "${RUNTIME_DIR}/LICENSE"
install -m 600 "${PANEL_PATH}" "${STATIC_DIR}/management.html"
if [[ "${existing_installation}" == "false" ]]; then
    install -m 600 "${TEMP_CONFIG_PATH}" "${CONFIG_PATH}"
else
    migrate_legacy_owned_configuration "${previous_version}"
    chmod 600 "${CONFIG_PATH}"
fi
install -m 600 "${TEMP_CLIENT_PATH}" "${CLIENT_PATH}"
printf '%s\n' "${EXPECTED_CPA_VERSION}" > "${TEMP_DIR}/VERSION"
printf '%s\n' "${EXPECTED_PANEL_VERSION}" > "${TEMP_DIR}/PANEL_VERSION"
install -m 600 "${TEMP_DIR}/VERSION" "${VERSION_PATH}"
install -m 600 "${TEMP_DIR}/PANEL_VERSION" "${PANEL_VERSION_PATH}"
install -m 644 "${TEMP_LAUNCH_AGENT_PATH}" "${LAUNCH_AGENT_PATH}"
rm -f -- "${LEGACY_LAUNCH_AGENT_PATH}"
/usr/bin/plutil -lint "${LAUNCH_AGENT_PATH}" >/dev/null

readonly NEW_SERVICE_TARGET="$(service_target "${LAUNCH_AGENT_LABEL}")"
if [[ "${was_running}" == "true" ]]; then
    "${LAUNCHCTL_BIN}" enable "${NEW_SERVICE_TARGET}"
    if ! "${LAUNCHCTL_BIN}" bootstrap "${USER_DOMAIN}" "${LAUNCH_AGENT_PATH}"; then
        "${LAUNCHCTL_BIN}" print "${NEW_SERVICE_TARGET}" >/dev/null
    fi
    "${LAUNCHCTL_BIN}" kickstart -k "${NEW_SERVICE_TARGET}"
    if ! wait_for_healthy_service "${api_key}"; then
        fail 70 "CPA files were installed and the service remains loaded, but its health check failed."
    fi
    echo "CLIProxyAPI ${EXPECTED_CPA_VERSION} and management panel ${EXPECTED_PANEL_VERSION} are installed and healthy."
else
    "${LAUNCHCTL_BIN}" bootout "${NEW_SERVICE_TARGET}" >/dev/null 2>&1 || true
    "${LAUNCHCTL_BIN}" disable "${NEW_SERVICE_TARGET}"
    echo "CLIProxyAPI ${EXPECTED_CPA_VERSION} and management panel ${EXPECTED_PANEL_VERSION} are installed and stopped."
fi
echo "Runtime: ${RUNTIME_DIR}"
