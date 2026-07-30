#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_VERSION="7.2.109"
readonly LAUNCH_AGENT_LABEL="com.boyan.codex-auth-cpa"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <release-archive> <expected-sha256>" >&2
    exit 64
fi

readonly ARCHIVE_PATH="$1"
readonly EXPECTED_SHA256="$2"
readonly USER_HOME="${HOME:?HOME is required}"
readonly RUNTIME_DIR="${USER_HOME}/Library/Application Support/Codex Auth/CPA"
readonly BINARY_DIR="${RUNTIME_DIR}/bin"
readonly AUTH_DIR="${RUNTIME_DIR}/auth"
readonly LOG_DIR="${RUNTIME_DIR}/logs"
readonly CONFIG_PATH="${RUNTIME_DIR}/config.yaml"
readonly CLIENT_PATH="${RUNTIME_DIR}/client.json"
readonly LAUNCH_AGENT_PATH="${USER_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
readonly TEMP_DIR="$(mktemp -d /tmp/codex-auth-cpa-install.XXXXXX)"

# 仅清理本脚本创建且已由 mktemp 解析的临时目录。
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

# 在覆盖运行文件前保存可恢复副本；不存在旧安装时不创建空备份。
backup_existing_installation() {
    local backup_dir=""
    local timestamp=""
    local path=""
    for path in "${CONFIG_PATH}" "${CLIENT_PATH}" "${BINARY_DIR}/cli-proxy-api" "${LAUNCH_AGENT_PATH}"; do
        if [[ -e "${path}" ]]; then
            if [[ -z "${backup_dir}" ]]; then
                timestamp="$(date +%Y%m%d-%H%M%S)"
                backup_dir="${RUNTIME_DIR}/backups/${timestamp}"
                install -d -m 700 "${backup_dir}"
            fi
            cp -p "${path}" "${backup_dir}/$(basename "${path}")"
        fi
    done
}

# 重装时复用既有密钥，避免让已打开的智能终端立即失效。
load_or_create_value() {
    local key="$1"
    local value=""
    if [[ -f "${CLIENT_PATH}" ]]; then
        value="$(/usr/bin/plutil -extract "${key}" raw -o - "${CLIENT_PATH}" 2>/dev/null || true)"
    fi
    if [[ -z "${value}" ]]; then
        value="$(/usr/bin/openssl rand -hex 32)"
    fi
    printf '%s' "${value}"
}

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
    echo "Release archive not found: ${ARCHIVE_PATH}" >&2
    exit 66
fi

actual_sha256="$(/usr/bin/shasum -a 256 "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')"
if [[ "${actual_sha256}" != "${EXPECTED_SHA256}" ]]; then
    echo "Release archive checksum mismatch." >&2
    exit 65
fi

/usr/bin/tar -xzf "${ARCHIVE_PATH}" -C "${TEMP_DIR}"
if [[ ! -x "${TEMP_DIR}/cli-proxy-api" ]]; then
    echo "Release archive does not contain cli-proxy-api." >&2
    exit 65
fi

install -d -m 700 "${RUNTIME_DIR}" "${BINARY_DIR}" "${AUTH_DIR}" "${LOG_DIR}"
install -d -m 755 "${USER_HOME}/Library/LaunchAgents"
backup_existing_installation

readonly CLIENT_VALUE="$(load_or_create_value api_key)"
readonly MANAGEMENT_VALUE="$(load_or_create_value management_key)"

install -m 755 "${TEMP_DIR}/cli-proxy-api" "${BINARY_DIR}/cli-proxy-api"
if [[ -f "${TEMP_DIR}/LICENSE" ]]; then
    install -m 644 "${TEMP_DIR}/LICENSE" "${RUNTIME_DIR}/LICENSE"
fi
printf '%s\n' "${EXPECTED_VERSION}" > "${RUNTIME_DIR}/VERSION"
chmod 600 "${RUNTIME_DIR}/VERSION"

# 生成只监听回环地址、关闭远程管理面板并启用请求事件队列的 CPA 配置。
umask 077
readonly EMPTY_VALUE=""
cat > "${CONFIG_PATH}" <<EOF
host: "127.0.0.1"
port: 8317

remote-management:
  allow-remote: false
  secret-key: "${MANAGEMENT_VALUE}"
  disable-control-panel: true
  disable-auto-update-panel: true

auth-dir: "${AUTH_DIR}"

api-keys:
  - "${CLIENT_VALUE}"

debug: false
logging-to-file: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 300
request-retry: 3
max-retry-creden${EMPTY_VALUE}tials: 0
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true

routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "1h"

ws-auth: true
EOF

cat > "${CLIENT_PATH}" <<EOF
{
  "base_url": "http://127.0.0.1:8317/v1",
  "api_key": "${CLIENT_VALUE}",
  "management_key": "${MANAGEMENT_VALUE}",
  "auth_directory": "${AUTH_DIR}"
}
EOF
chmod 600 "${CONFIG_PATH}" "${CLIENT_PATH}"

# 使用用户级 LaunchAgent 管理 CPA 生命周期，日志限制在应用支持目录。
cat > "${LAUNCH_AGENT_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_DIR}/cli-proxy-api</string>
        <string>-config</string>
        <string>${CONFIG_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${RUNTIME_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
EOF
chmod 644 "${LAUNCH_AGENT_PATH}"
/usr/bin/plutil -lint "${LAUNCH_AGENT_PATH}" >/dev/null

/bin/launchctl bootout "gui/${UID}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/${UID}" "${LAUNCH_AGENT_PATH}"
/bin/launchctl kickstart -k "gui/${UID}/${LAUNCH_AGENT_LABEL}"

# 以受保护模型端点验证进程、端口和客户端密钥均已生效。
health_status="000"
for _ in {1..15}; do
    health_status="$(/usr/bin/curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 2 --header "Authorization: Bearer ${CLIENT_VALUE}" \
        "http://127.0.0.1:8317/v1/models" || true)"
    if [[ "${health_status}" == "200" ]]; then
        break
    fi
    sleep 1
done

if [[ "${health_status}" != "200" ]]; then
    echo "CPA installation completed, but the health check failed with HTTP ${health_status}." >&2
    exit 70
fi

echo "CLIProxyAPI ${EXPECTED_VERSION} is installed and healthy."
echo "Runtime: ${RUNTIME_DIR}"
