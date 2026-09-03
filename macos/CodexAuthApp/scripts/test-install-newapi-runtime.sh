#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLER_PATH="${SCRIPT_DIR}/install-newapi-runtime.sh"
readonly LAUNCHER_PATH="${SCRIPT_DIR}/newapi-service-launcher.sh"
readonly CREDENTIAL_HELPER_PATH="${SCRIPT_DIR}/newapi-credential-helper.sh"
readonly TEMP_ROOT="$(mktemp -d /tmp/codex-auth-newapi-installer-test.XXXXXX)"
readonly FIXTURE_DIR="${TEMP_ROOT}/fixture"
readonly BINARY_PATH="${FIXTURE_DIR}/new-api-macos"
readonly PATCHED_INSTALLER="${FIXTURE_DIR}/install-newapi-runtime.sh"
readonly PATCHED_LAUNCHER="${FIXTURE_DIR}/newapi-service-launcher.sh"
readonly PATCHED_CREDENTIAL_HELPER="${FIXTURE_DIR}/newapi-credential-helper.sh"
readonly FAKE_LAUNCHCTL="${FIXTURE_DIR}/launchctl"
readonly FAKE_CURL="${FIXTURE_DIR}/curl"
readonly FAKE_SLEEP="${FIXTURE_DIR}/sleep"
readonly FAKE_SCUTIL="${FIXTURE_DIR}/scutil"
readonly USER_ID="$(/usr/bin/id -u)"
readonly SERVICE_LABEL="com.codex-auth.newapi"

# 仅清理本测试创建的临时目录。
cleanup() {
    rm -rf -- "${TEMP_ROOT}"
}
trap cleanup EXIT

# 输出稳定英文错误并终止测试。
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 断言两个文本值完全一致。
assert_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

# 断言文件存在。
assert_file_exists() {
    [[ -f "$1" ]] || fail "Expected file to exist: $1"
}

# 断言文件不存在。
assert_file_missing() {
    [[ ! -e "$1" ]] || fail "Expected path to be absent: $1"
}

# 断言文件包含指定字面文本。
assert_contains() {
    /usr/bin/grep -Fq -- "$2" "$1" || fail "Expected '$1' to contain: $2"
}

# 断言文件不包含指定字面文本。
assert_not_contains() {
    if /usr/bin/grep -Fq -- "$2" "$1"; then
        fail "Expected '$1' not to contain: $2"
    fi
}

# 创建固定 NewAPI 二进制和伪系统命令。
create_fixtures() {
    install -d -m 700 "${FIXTURE_DIR}"

    cat > "${BINARY_PATH}" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "${FAKE_NEWAPI_VERSION:-v1.0.0-codex-auth.3}"
fi
exit 0
EOF
    chmod 755 "${BINARY_PATH}"

    cat > "${FAKE_LAUNCHCTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_LAUNCHCTL_LOG:?}"
: "${FAKE_LAUNCHCTL_STATE:?}"
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG}"
case "${1:-}" in
    print)
        [[ -f "${FAKE_LAUNCHCTL_STATE}" ]] && /usr/bin/grep -Fxq -- "${2:-}" "${FAKE_LAUNCHCTL_STATE}"
        ;;
    bootout)
        if [[ -f "${FAKE_LAUNCHCTL_STATE}" ]]; then
            /usr/bin/awk -v target="${2:-}" '$0 != target { print }' "${FAKE_LAUNCHCTL_STATE}" > "${FAKE_LAUNCHCTL_STATE}.tmp"
            /bin/mv "${FAKE_LAUNCHCTL_STATE}.tmp" "${FAKE_LAUNCHCTL_STATE}"
        fi
        ;;
    bootstrap)
        label="$(/usr/bin/plutil -extract Label raw -o - "${3:?}")"
        printf '%s/%s\n' "${2:?}" "${label}" > "${FAKE_LAUNCHCTL_STATE}"
        ;;
    enable|disable)
        ;;
    *)
        exit 64
        ;;
esac
EOF
    chmod 755 "${FAKE_LAUNCHCTL}"

    cat > "${FAKE_CURL}" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_NEWAPI_STATUS:-200}"
EOF
    chmod 755 "${FAKE_CURL}"

    cat > "${FAKE_SLEEP}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "${FAKE_SLEEP}"

    cat > "${FAKE_SCUTIL}" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--proxy" ]] || exit 64
printf '%s\n' '<dictionary> {' '}'
EOF
    chmod 755 "${FAKE_SCUTIL}"

    /usr/bin/sed "s|/usr/sbin/scutil|${FAKE_SCUTIL}|g" \
        "${CREDENTIAL_HELPER_PATH}" > "${PATCHED_CREDENTIAL_HELPER}"
    /bin/cp "${LAUNCHER_PATH}" "${PATCHED_LAUNCHER}"
    chmod 755 "${PATCHED_CREDENTIAL_HELPER}" "${PATCHED_LAUNCHER}"

    local binary_sha=""
    binary_sha="$(/usr/bin/shasum -a 256 "${BINARY_PATH}" | /usr/bin/awk '{print $1}')"
    /usr/bin/sed \
        -e "s|^readonly EXPECTED_NEWAPI_SHA256=.*|readonly EXPECTED_NEWAPI_SHA256=\"${binary_sha}\"|" \
        -e "s|^readonly LAUNCHCTL_BIN=.*|readonly LAUNCHCTL_BIN=\"${FAKE_LAUNCHCTL}\"|" \
        -e "s|^readonly CURL_BIN=.*|readonly CURL_BIN=\"${FAKE_CURL}\"|" \
        -e "s|^readonly SERVICE_LAUNCHER_SOURCE=.*|readonly SERVICE_LAUNCHER_SOURCE=\"${PATCHED_LAUNCHER}\"|" \
        -e "s|^readonly CREDENTIAL_HELPER_SOURCE=.*|readonly CREDENTIAL_HELPER_SOURCE=\"${PATCHED_CREDENTIAL_HELPER}\"|" \
        -e "s|^        sleep 1$|        \"${FAKE_SLEEP}\" 1|" \
        "${INSTALLER_PATH}" > "${PATCHED_INSTALLER}"
    chmod 755 "${PATCHED_INSTALLER}"
}

# 在隔离 HOME 和伪 launchd 状态下运行安装器。
run_installer() {
    local home_dir="$1"
    local log_path="$2"
    local state_path="$3"
    HOME="${home_dir}" \
    FAKE_LAUNCHCTL_LOG="${log_path}" \
    FAKE_LAUNCHCTL_STATE="${state_path}" \
    FAKE_NEWAPI_STATUS="${FAKE_NEWAPI_STATUS:-200}" \
    FAKE_NEWAPI_VERSION="${FAKE_NEWAPI_VERSION:-v1.0.0-codex-auth.3}" \
        "${PATCHED_INSTALLER}" "${BINARY_PATH}"
}

# 验证摘要不匹配时安装器不会创建运行目录。
test_rejects_tampered_binary() {
    local home_dir="${TEMP_ROOT}/checksum-home"
    local log_path="${TEMP_ROOT}/checksum.log"
    local state_path="${TEMP_ROOT}/checksum.state"
    local tampered_binary="${TEMP_ROOT}/tampered-new-api"
    install -d -m 700 "${home_dir}"
    /bin/cp "${BINARY_PATH}" "${tampered_binary}"
    printf '%s\n' '# tampered' >> "${tampered_binary}"
    chmod 755 "${tampered_binary}"
    : > "${log_path}"
    : > "${state_path}"

    if HOME="${home_dir}" FAKE_LAUNCHCTL_LOG="${log_path}" FAKE_LAUNCHCTL_STATE="${state_path}" \
        "${PATCHED_INSTALLER}" "${tampered_binary}" >/dev/null 2>&1; then
        fail "Tampered NewAPI binary was accepted"
    fi
    assert_file_missing "${home_dir}/Library/Application Support/Codex Auth/NewAPI/VERSION"
}

# 验证摘要正确但版本输出异常时安装器仍会拒绝资产。
test_rejects_unexpected_version_output() {
    local home_dir="${TEMP_ROOT}/version-home"
    local log_path="${TEMP_ROOT}/version.log"
    local state_path="${TEMP_ROOT}/version.state"
    install -d -m 700 "${home_dir}"
    : > "${log_path}"
    : > "${state_path}"

    if FAKE_NEWAPI_VERSION="v0.0.0" run_installer "${home_dir}" "${log_path}" "${state_path}" \
        >/dev/null 2>&1; then
        fail "Unexpected NewAPI version output was accepted"
    fi
    assert_file_missing "${home_dir}/Library/Application Support/Codex Auth/NewAPI/VERSION"
}

# 验证首次安装生成受保护契约并保持服务关闭。
test_fresh_install_is_stopped() {
    local home_dir="${TEMP_ROOT}/install-home"
    local log_path="${TEMP_ROOT}/install.log"
    local state_path="${TEMP_ROOT}/install.state"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/NewAPI"
    local plist_path="${home_dir}/Library/LaunchAgents/${SERVICE_LABEL}.plist"
    install -d -m 700 "${home_dir}"
    : > "${log_path}"
    : > "${state_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    assert_equal "$(<"${runtime_dir}/VERSION")" "v1.0.0-codex-auth.3" "NewAPI version"
    assert_file_exists "${runtime_dir}/bin/new-api"
    assert_file_exists "${runtime_dir}/bin/codex-auth-newapi-service"
    assert_file_exists "${runtime_dir}/bin/codex-auth-newapi-credential"
    assert_equal "$(/usr/bin/stat -f '%Lp' "${runtime_dir}/client.json")" "600" "Client config mode"
    assert_equal "$(/usr/bin/stat -f '%Lp' "${runtime_dir}/server.json")" "600" "Server config mode"
    assert_equal "$(/usr/bin/plutil -extract base_url raw -o - "${runtime_dir}/client.json")" \
        "http://127.0.0.1:3000/v1" "Client base URL"
    assert_equal "$(/usr/bin/plutil -extract api_key raw -o - "${runtime_dir}/client.json")" "" "Initial token"
    [[ -n "$(/usr/bin/plutil -extract session_secret raw -o - "${runtime_dir}/server.json")" ]] || \
        fail "Missing session secret"
    assert_equal "$(/usr/bin/plutil -extract sqlite_path raw -o - "${runtime_dir}/server.json")" \
        "${runtime_dir}/data/new-api.db" "SQLite path"
    assert_equal "$(/usr/bin/plutil -extract Label raw -o - "${plist_path}")" "${SERVICE_LABEL}" "LaunchAgent label"
    assert_equal "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "${plist_path}")" \
        "${runtime_dir}/bin/codex-auth-newapi-service" "LaunchAgent program"
    assert_not_contains "${plist_path}" "session_secret"
    assert_contains "${log_path}" "disable gui/${USER_ID}/${SERVICE_LABEL}"
    assert_not_contains "${log_path}" "bootstrap "

    printf '%s\n' "${home_dir}" > "${TEMP_ROOT}/installed-home"
    printf '%s\n' "${log_path}" > "${TEMP_ROOT}/installed-log"
    printf '%s\n' "${state_path}" > "${TEMP_ROOT}/installed-state"
}

# 验证运行中升级保留 SQLite、Token 和会话密钥并恢复服务。
test_running_upgrade_preserves_user_data() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/NewAPI"
    local client_path="${runtime_dir}/client.json"
    local database_path="${runtime_dir}/data/new-api.db"
    local original_secret=""
    original_secret="$(/usr/bin/plutil -extract session_secret raw -o - "${runtime_dir}/server.json")"
    /usr/bin/plutil -replace api_key -string "sk-preserved" "${client_path}"
    printf '%s' "sqlite-user-data" > "${database_path}"
    printf 'gui/%s/%s\n' "${USER_ID}" "${SERVICE_LABEL}" > "${state_path}"
    : > "${log_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    assert_equal "$(/usr/bin/plutil -extract api_key raw -o - "${client_path}")" "sk-preserved" "Preserved token"
    assert_equal "$(<"${database_path}")" "sqlite-user-data" "Preserved SQLite data"
    assert_equal "$(/usr/bin/plutil -extract session_secret raw -o - "${runtime_dir}/server.json")" \
        "${original_secret}" "Preserved session secret"
    assert_contains "${log_path}" "bootstrap gui/${USER_ID}"
}

# 验证安装后的凭据助手只为安全回环请求输出 Token。
test_installed_credential_helper_reads_token() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/NewAPI"
    local helper_path="${runtime_dir}/bin/codex-auth-newapi-credential"
    local client_path="${runtime_dir}/client.json"
    local actual=""

    actual="$(/usr/bin/env -i HOME="${home_dir}" \
        "${helper_path}" "http://127.0.0.1:3000/v1" "${client_path}")"
    assert_equal "${actual}" "sk-preserved" "Credential helper token"
}

# 依次运行全部隔离安装器测试。
main() {
    create_fixtures
    test_rejects_tampered_binary
    test_rejects_unexpected_version_output
    test_fresh_install_is_stopped
    test_running_upgrade_preserves_user_data
    test_installed_credential_helper_reads_token
    echo "NewAPI installer tests passed."
}

main "$@"
