#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly VERSION="1.11.11"
readonly ARCHIVE_SHA256="fafe1665dd0a6f67a7e9bd33064b8d12fc335f5ac9f3c4e3506e2c2f2454753b"
readonly ARCHIVE_URL="https://github.com/seakee/CPA-Manager-Plus/releases/download/v${VERSION}/cpa-manager-plus_v${VERSION}_darwin_arm64.tar.gz"
readonly LABEL="com.codex-auth.cpamp"
readonly USER_HOME="${HOME:?HOME is required}"
readonly USER_DOMAIN="gui/${UID}"
readonly ROOT_DIR="${USER_HOME}/Library/Application Support/Codex Auth/CPAMP"
readonly BIN_DIR="${ROOT_DIR}/bin"
readonly DATA_DIR="${ROOT_DIR}/data"
readonly LOG_DIR="${ROOT_DIR}/logs"
readonly CONFIG_PATH="${ROOT_DIR}/config.json"
readonly ADMIN_KEY_PATH="${ROOT_DIR}/admin-key"
readonly CPA_KEY_PATH="${ROOT_DIR}/cpa-management-key"
readonly BINARY_PATH="${BIN_DIR}/cpa-manager-plus"
readonly PLIST_PATH="${USER_HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly TEMP_DIR="$(mktemp -d /tmp/codex-auth-cpamp-install.XXXXXX)"
readonly ARCHIVE_PATH="${TEMP_DIR}/cpamp.tar.gz"
readonly TEMP_PLIST="${TEMP_DIR}/${LABEL}.plist"
readonly CPA_CLIENT_PATH="${USER_HOME}/Library/Application Support/Codex Auth/CPA/client.json"
readonly LAUNCHCTL_BIN="/bin/launchctl"
readonly CURL_BIN="/usr/bin/curl"

cleanup() { rm -rf -- "${TEMP_DIR}"; }
trap cleanup EXIT

fail() {
    local code="$1"
    shift
    echo "$*" >&2
    exit "${code}"
}

file_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

service_target() {
    printf '%s/%s' "${USER_DOMAIN}" "${LABEL}"
}

read_cpa_management_key() {
    /usr/bin/plutil -extract management_key raw -o - "${CPA_CLIENT_PATH}" 2>/dev/null
}

generate_admin_key() {
    /usr/bin/openssl rand -hex 32
}

write_config() {
    cat > "${CONFIG_PATH}" <<EOF
{
  "httpAddr": "127.0.0.1:18317",
  "dataDir": "${DATA_DIR}"
}
EOF
    chmod 600 "${CONFIG_PATH}"
}

write_launch_agent() {
    /usr/bin/plutil -create xml1 "${TEMP_PLIST}"
    /usr/bin/plutil -insert Label -string "${LABEL}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert ProgramArguments -array "${TEMP_PLIST}"
    /usr/bin/plutil -insert ProgramArguments.0 -string "${BINARY_PATH}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables -dictionary "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.CPA_MANAGER_CONFIG -string "${CONFIG_PATH}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.CPA_MANAGER_ADMIN_KEY_FILE -string "${ADMIN_KEY_PATH}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.CPA_UPSTREAM_URL -string "http://127.0.0.1:8317" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.CPA_MANAGEMENT_KEY_FILE -string "${CPA_KEY_PATH}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.USAGE_DATA_DIR -string "${DATA_DIR}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert EnvironmentVariables.HTTP_ADDR -string "127.0.0.1:18317" "${TEMP_PLIST}"
    /usr/bin/plutil -insert RunAtLoad -bool true "${TEMP_PLIST}"
    /usr/bin/plutil -insert KeepAlive -bool true "${TEMP_PLIST}"
    /usr/bin/plutil -insert WorkingDirectory -string "${ROOT_DIR}" "${TEMP_PLIST}"
    /usr/bin/plutil -insert StandardOutPath -string "${LOG_DIR}/stdout.log" "${TEMP_PLIST}"
    /usr/bin/plutil -insert StandardErrorPath -string "${LOG_DIR}/stderr.log" "${TEMP_PLIST}"
    /usr/bin/plutil -lint "${TEMP_PLIST}" >/dev/null
    install -m 600 "${TEMP_PLIST}" "${PLIST_PATH}"
}

wait_for_health() {
    local status="000"
    local attempt
    for attempt in {1..20}; do
        status="$(${CURL_BIN} --silent --output /dev/null --write-out '%{http_code}' --noproxy '*' \
            --max-time 2 http://127.0.0.1:18317/health || true)"
        [[ "${status}" == "200" ]] && return 0
        sleep 1
    done
    echo "CPAMP health check failed (HTTP ${status})." >&2
    return 1
}

[[ "$(uname -m)" == "arm64" ]] || fail 64 "This installer requires macOS arm64."
[[ -f "${CPA_CLIENT_PATH}" ]] || fail 78 "CPA client configuration is missing: ${CPA_CLIENT_PATH}"

install -d -m 700 "${ROOT_DIR}" "${BIN_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${USER_HOME}/Library/LaunchAgents"
if [[ ! -f "${ADMIN_KEY_PATH}" ]]; then
    generate_admin_key > "${ADMIN_KEY_PATH}"
    chmod 600 "${ADMIN_KEY_PATH}"
fi
read_cpa_management_key > "${CPA_KEY_PATH}"
chmod 600 "${CPA_KEY_PATH}"
write_config

"${CURL_BIN}" --fail --silent --show-error --location --output "${ARCHIVE_PATH}" "${ARCHIVE_URL}"
[[ "$(file_sha256 "${ARCHIVE_PATH}")" == "${ARCHIVE_SHA256}" ]] || fail 65 "CPAMP archive checksum mismatch."
/usr/bin/tar -xzf "${ARCHIVE_PATH}" -C "${TEMP_DIR}"
readonly EXTRACTED_BINARY="${TEMP_DIR}/cpa-manager-plus_v${VERSION}_darwin_arm64/cpa-manager-plus"
[[ -x "${EXTRACTED_BINARY}" ]] || fail 65 "CPAMP binary is missing from the release archive."

"${LAUNCHCTL_BIN}" bootout "$(service_target)" >/dev/null 2>&1 || true
install -m 755 "${EXTRACTED_BINARY}" "${BINARY_PATH}"
write_launch_agent
"${LAUNCHCTL_BIN}" enable "$(service_target)"
"${LAUNCHCTL_BIN}" bootstrap "${USER_DOMAIN}" "${PLIST_PATH}" >/dev/null 2>&1 || \
    "${LAUNCHCTL_BIN}" print "$(service_target)" >/dev/null
"${LAUNCHCTL_BIN}" kickstart -k "$(service_target)"
wait_for_health
echo "CPAMP Manager Plus v${VERSION} is installed and healthy at http://127.0.0.1:18317."
echo "Admin key file: ${ADMIN_KEY_PATH}"
