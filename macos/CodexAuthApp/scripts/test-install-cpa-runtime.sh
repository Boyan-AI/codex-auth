#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLER_PATH="${SCRIPT_DIR}/install-cpa-runtime.sh"
readonly CREDENTIAL_HELPER_PATH="${SCRIPT_DIR}/cpa-credential-helper.sh"
readonly TEMP_ROOT="$(mktemp -d /tmp/codex-auth-cpa-installer-test.XXXXXX)"
readonly FIXTURE_DIR="${TEMP_ROOT}/fixture"
readonly ARCHIVE_ROOT="${FIXTURE_DIR}/archive"
readonly ARCHIVE_PATH="${FIXTURE_DIR}/CLIProxyAPI.tar.gz"
readonly PANEL_PATH="${FIXTURE_DIR}/management.html"
readonly PATCHED_INSTALLER="${FIXTURE_DIR}/install-cpa-runtime.sh"
readonly PATCHED_CREDENTIAL_HELPER="${FIXTURE_DIR}/cpa-credential-helper.sh"
readonly FAKE_LAUNCHCTL="${FIXTURE_DIR}/launchctl"
readonly FAKE_CURL="${FIXTURE_DIR}/curl"
readonly FAKE_SLEEP="${FIXTURE_DIR}/sleep"
readonly FAKE_SCUTIL="${FIXTURE_DIR}/scutil"
readonly USER_ID="$(/usr/bin/id -u)"
readonly NEW_LABEL="com.codex-auth.cpa"
readonly LEGACY_LABEL="com.boyan.codex-auth-cpa"

# 仅清理本测试通过 mktemp 创建的隔离目录。
cleanup() {
    rm -rf -- "${TEMP_ROOT}"
}
trap cleanup EXIT

# 输出稳定的测试失败信息并终止执行。
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

# 创建可重复的 CPA 归档、面板和伪系统命令。
create_fixtures() {
    install -d -m 700 "${ARCHIVE_ROOT}"

    cat > "${FAKE_SCUTIL}" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--proxy" ]] || exit 64
case "${FAKE_SCUTIL_MODE:-direct}" in
    direct)
        printf '%s\n' '<dictionary> {' '}'
        ;;
    loopback)
        printf '%s\n' '<dictionary> {' '  HTTPEnable : 1' '  HTTPProxy : 127.0.0.1' '  HTTPPort : 7897' '}'
        ;;
    remote)
        printf '%s\n' '<dictionary> {' '  HTTPEnable : 1' '  HTTPProxy : proxy.example' '  HTTPPort : 8080' '}'
        ;;
    pac)
        printf '%s\n' '<dictionary> {' '  ProxyAutoConfigEnable : 1' \
            '  ProxyAutoConfigURLString : https://proxy.example/proxy.pac' '}'
        ;;
    *)
        exit 64
        ;;
esac
EOF
    chmod 755 "${FAKE_SCUTIL}"
    /usr/bin/sed "s|/usr/sbin/scutil|${FAKE_SCUTIL}|g" \
        "${CREDENTIAL_HELPER_PATH}" > "${PATCHED_CREDENTIAL_HELPER}"
    chmod 755 "${PATCHED_CREDENTIAL_HELPER}"
    cat > "${ARCHIVE_ROOT}/cli-proxy-api" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-h" ]]; then
    echo "CLIProxyAPI Version: 7.2.120, Commit: fixture, BuiltAt: fixture"
fi
exit 0
EOF
    chmod 755 "${ARCHIVE_ROOT}/cli-proxy-api"
    printf '%s\n' "fixture license" > "${ARCHIVE_ROOT}/LICENSE"
    /usr/bin/tar -czf "${ARCHIVE_PATH}" -C "${ARCHIVE_ROOT}" cli-proxy-api LICENSE
    printf '%s' "management-panel-v1.21.4" > "${PANEL_PATH}"

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
    enable|disable|kickstart)
        ;;
    *)
        exit 64
        ;;
esac
EOF
    chmod 755 "${FAKE_LAUNCHCTL}"

    cat > "${FAKE_CURL}" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "${url}" in
    */v0/management/config) printf '%s' "${FAKE_MANAGEMENT_STATUS:-200}" ;;
    */management.html) printf '%s' "${FAKE_PANEL_STATUS:-200}" ;;
    *) printf '%s' "${FAKE_MODEL_STATUS:-200}" ;;
esac
EOF
    chmod 755 "${FAKE_CURL}"

    cat > "${FAKE_SLEEP}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "${FAKE_SLEEP}"

    local archive_sha=""
    local panel_sha=""
    archive_sha="$(/usr/bin/shasum -a 256 "${ARCHIVE_PATH}" | /usr/bin/awk '{print $1}')"
    panel_sha="$(/usr/bin/shasum -a 256 "${PANEL_PATH}" | /usr/bin/awk '{print $1}')"
    /usr/bin/sed \
        -e "s|^readonly EXPECTED_CPA_ARCHIVE_SHA256=.*|readonly EXPECTED_CPA_ARCHIVE_SHA256=\"${archive_sha}\"|" \
        -e "s|^readonly EXPECTED_PANEL_SHA256=.*|readonly EXPECTED_PANEL_SHA256=\"${panel_sha}\"|" \
        -e "s|^readonly LAUNCHCTL_BIN=.*|readonly LAUNCHCTL_BIN=\"${FAKE_LAUNCHCTL}\"|" \
        -e "s|^readonly CURL_BIN=.*|readonly CURL_BIN=\"${FAKE_CURL}\"|" \
        -e "s|^        sleep 1$|        \"${FAKE_SLEEP}\" 1|" \
        "${INSTALLER_PATH}" > "${PATCHED_INSTALLER}"
    chmod 755 "${PATCHED_INSTALLER}"
    assert_contains "${PATCHED_INSTALLER}" "readonly EXPECTED_CPA_ARCHIVE_SHA256=\"${archive_sha}\""
    assert_contains "${PATCHED_INSTALLER}" "readonly EXPECTED_PANEL_SHA256=\"${panel_sha}\""
    assert_contains "${PATCHED_CREDENTIAL_HELPER}" "${FAKE_SCUTIL} --proxy"
}

# 运行被测安装器，所有用户目录和 launchd 状态都指向隔离夹具。
run_installer() {
    local home_dir="$1"
    local launchctl_log="$2"
    local launchctl_state="$3"
    HOME="${home_dir}" \
    FAKE_LAUNCHCTL_LOG="${launchctl_log}" \
    FAKE_LAUNCHCTL_STATE="${launchctl_state}" \
    FAKE_MODEL_STATUS="${FAKE_MODEL_STATUS:-200}" \
    FAKE_MANAGEMENT_STATUS="${FAKE_MANAGEMENT_STATUS:-200}" \
    FAKE_PANEL_STATUS="${FAKE_PANEL_STATUS:-200}" \
        "${PATCHED_INSTALLER}" "${ARCHIVE_PATH}" "${PANEL_PATH}"
}

# 验证归档或面板被篡改时，安装器在写入前失败。
test_pinned_checksums() {
    local home_dir="${TEMP_ROOT}/checksum-home"
    local log_path="${TEMP_ROOT}/checksum-launchctl.log"
    local state_path="${TEMP_ROOT}/checksum-launchctl.state"
    local tampered_panel="${TEMP_ROOT}/tampered-management.html"
    install -d -m 700 "${home_dir}"
    printf '%s' "tampered" > "${tampered_panel}"

    if HOME="${home_dir}" FAKE_LAUNCHCTL_LOG="${log_path}" FAKE_LAUNCHCTL_STATE="${state_path}" \
        "${PATCHED_INSTALLER}" "${ARCHIVE_PATH}" "${tampered_panel}" >/dev/null 2>&1; then
        fail "Tampered management panel was accepted"
    fi
    assert_file_missing "${home_dir}/Library/Application Support/Codex Auth/CPA/VERSION"
}

# 验证首次安装生成安全契约，但不启动 CPA。
test_fresh_install_is_stopped() {
    local home_dir="${TEMP_ROOT}/install-home"
    local log_path="${TEMP_ROOT}/install-launchctl.log"
    local state_path="${TEMP_ROOT}/install-launchctl.state"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/CPA"
    local plist_path="${home_dir}/Library/LaunchAgents/${NEW_LABEL}.plist"
    install -d -m 700 "${home_dir}"
    : > "${log_path}"
    : > "${state_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    assert_equal "$(<"${runtime_dir}/VERSION")" "7.2.120" "CPA version"
    assert_equal "$(<"${runtime_dir}/PANEL_VERSION")" "v1.21.4" "Panel version"
    assert_file_exists "${runtime_dir}/static/management.html"
    assert_file_exists "${runtime_dir}/bin/codex-auth-cpa-credential"
    assert_equal "$(/usr/bin/stat -f '%Lp' "${runtime_dir}/bin/codex-auth-cpa-credential")" "755" \
        "Credential helper mode"
    /usr/bin/cmp -s "${PANEL_PATH}" "${runtime_dir}/static/management.html" || fail "Panel asset changed during install"
    assert_contains "${runtime_dir}/config.yaml" 'host: "127.0.0.1"'
    assert_contains "${runtime_dir}/config.yaml" "port: 8317"
    assert_contains "${runtime_dir}/config.yaml" "  allow-remote: false"
    assert_contains "${runtime_dir}/config.yaml" "  disable-control-panel: false"
    assert_contains "${runtime_dir}/config.yaml" "  disable-auto-update-panel: true"
    assert_equal "$(/usr/bin/plutil -extract base_url raw -o - "${runtime_dir}/client.json")" \
        "http://127.0.0.1:8317/v1" "Client base URL"
    [[ -n "$(/usr/bin/plutil -extract api_key raw -o - "${runtime_dir}/client.json")" ]] || fail "Missing client key"
    [[ -n "$(/usr/bin/plutil -extract management_key raw -o - "${runtime_dir}/client.json")" ]] || fail "Missing management key"
    assert_equal "$(/usr/bin/stat -f '%Lp' "${runtime_dir}/client.json")" "600" "Client config mode"
    assert_equal "$(/usr/bin/plutil -extract Label raw -o - "${plist_path}")" "${NEW_LABEL}" "LaunchAgent label"
    assert_equal "$(/usr/bin/plutil -extract EnvironmentVariables.MANAGEMENT_STATIC_PATH raw -o - "${plist_path}")" \
        "${runtime_dir}/static" "Management static path"
    assert_equal "$(/usr/bin/plutil -extract RunAtLoad raw -o - "${plist_path}")" "true" "RunAtLoad"
    assert_equal "$(/usr/bin/plutil -extract KeepAlive raw -o - "${plist_path}")" "true" "KeepAlive"
    assert_contains "${log_path}" "disable gui/${USER_ID}/${NEW_LABEL}"
    assert_not_contains "${log_path}" "bootstrap "
    assert_not_contains "${log_path}" "kickstart "

    printf '%s\n' "${home_dir}" > "${TEMP_ROOT}/installed-home"
    printf '%s\n' "${log_path}" > "${TEMP_ROOT}/installed-log"
    printf '%s\n' "${state_path}" > "${TEMP_ROOT}/installed-state"
}

# 验证凭据助手只在回环请求不会进入 HTTP 代理时输出客户端 Key。
test_credential_helper_rejects_unsafe_proxy_routes() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/CPA"
    local helper_path="${runtime_dir}/bin/codex-auth-cpa-credential"
    local client_path="${runtime_dir}/client.json"
    local base_url="http://127.0.0.1:8317/v1"
    local expected_key=""
    local actual_key=""
    local stdout_path="${TEMP_ROOT}/credential-helper.stdout"
    local stderr_path="${TEMP_ROOT}/credential-helper.stderr"
    expected_key="$(/usr/bin/plutil -extract api_key raw -o - "${client_path}")"

    actual_key="$(/usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=direct \
        "${helper_path}" "${base_url}" "${client_path}")"
    assert_equal "${actual_key}" "${expected_key}" "Credential helper direct key"

    actual_key="$(/usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=direct \
        HTTP_PROXY="http://127.0.0.1:7897" \
        "${helper_path}" "${base_url}" "${client_path}")"
    assert_equal "${actual_key}" "${expected_key}" "Credential helper loopback proxy key"

    actual_key="$(/usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=loopback \
        "${helper_path}" "${base_url}" "${client_path}")"
    assert_equal "${actual_key}" "${expected_key}" "Credential helper loopback system proxy key"

    if /usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=direct \
        HTTP_PROXY="http://proxy.example:8080" \
        "${helper_path}" "${base_url}" "${client_path}" >"${stdout_path}" 2>"${stderr_path}"; then
        fail "Credential helper exposed the client key to an unsafe proxy route"
    fi
    assert_equal "$(<"${stdout_path}")" "" "Unsafe proxy stdout"
    assert_contains "${stderr_path}" "Refusing to expose the CPA client key"

    actual_key="$(/usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=direct \
        HTTP_PROXY="http://proxy.example:8080" \
        NO_PROXY="127.0.0.1" "${helper_path}" "${base_url}" "${client_path}")"
    assert_equal "${actual_key}" "${expected_key}" "Credential helper no-proxy key"

    if /usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=remote \
        HTTP_PROXY="http://proxy.example:8080" NO_PROXY="127.0.0.1" \
        "${helper_path}" "${base_url}" "${client_path}" >"${stdout_path}" 2>"${stderr_path}"; then
        fail "Credential helper trusted NO_PROXY over an unsafe system proxy route"
    fi
    assert_equal "$(<"${stdout_path}")" "" "Unsafe system proxy stdout"

    if /usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=pac \
        "${helper_path}" "${base_url}" "${client_path}" >"${stdout_path}" 2>"${stderr_path}"; then
        fail "Credential helper accepted an unresolved PAC route"
    fi
    assert_equal "$(<"${stdout_path}")" "" "PAC proxy stdout"

    if /usr/bin/env -i HOME="${home_dir}" FAKE_SCUTIL_MODE=remote REQUEST_METHOD=GET \
        "${helper_path}" "${base_url}" "${client_path}" >"${stdout_path}" 2>"${stderr_path}"; then
        fail "Credential helper bypassed system proxy checks in a CGI environment"
    fi
    assert_equal "$(<"${stdout_path}")" "" "CGI system proxy stdout"
}

# 验证已关闭升级不改写用户的 Provider 和路由配置。
test_stopped_upgrade_preserves_configuration() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/CPA"
    local expected_config="${TEMP_ROOT}/expected-config.yaml"
    cat >> "${runtime_dir}/config.yaml" <<'EOF'

codex-api-key:
  - api-key: "user-owned-provider-key"
    base-url: "https://provider.example.com/v1"
routing:
  strategy: "fill-first"
EOF
    /bin/cp -p "${runtime_dir}/config.yaml" "${expected_config}"
    : > "${log_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    /usr/bin/cmp -s "${expected_config}" "${runtime_dir}/config.yaml" || fail "Stopped upgrade rewrote user configuration"
    assert_contains "${runtime_dir}/config.yaml" "request-retry: 3"
    assert_contains "${runtime_dir}/config.yaml" "max-retry-credentials: 3"
    assert_contains "${runtime_dir}/config.yaml" "max-retry-interval: 30"
    assert_not_contains "${log_path}" "bootstrap "
    assert_contains "${log_path}" "disable gui/${USER_ID}/${NEW_LABEL}"
}

# 验证运行中升级会恢复新标签服务，且仍保留用户配置。
test_running_upgrade_restores_service() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/CPA"
    local expected_config="${TEMP_ROOT}/running-expected-config.yaml"
    /bin/cp -p "${runtime_dir}/config.yaml" "${expected_config}"
    printf 'gui/%s/%s\n' "${USER_ID}" "${NEW_LABEL}" > "${state_path}"
    : > "${log_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    /usr/bin/cmp -s "${expected_config}" "${runtime_dir}/config.yaml" || fail "Running upgrade rewrote user configuration"
    assert_contains "${log_path}" "bootstrap gui/${USER_ID}"
    assert_contains "${log_path}" "kickstart -k gui/${USER_ID}/${NEW_LABEL}"
    assert_contains "${state_path}" "gui/${USER_ID}/${NEW_LABEL}"
}

# 验证面板或管理契约不兼容时，升级仍保留原服务状态供应用报错和回滚。
test_running_upgrade_keeps_service_for_app_validation() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    printf 'gui/%s/%s\n' "${USER_ID}" "${NEW_LABEL}" > "${state_path}"
    : > "${log_path}"

    FAKE_MANAGEMENT_STATUS="401" FAKE_PANEL_STATUS="404" \
        run_installer "${home_dir}" "${log_path}" "${state_path}"

    assert_contains "${state_path}" "gui/${USER_ID}/${NEW_LABEL}"
    assert_contains "${log_path}" "kickstart -k gui/${USER_ID}/${NEW_LABEL}"
}

# 验证恢复后健康检查失败会阻止交付，但不把仍被全局路由引用的服务主动停掉。
test_failed_running_upgrade_keeps_service_loaded() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    printf 'gui/%s/%s\n' "${USER_ID}" "${NEW_LABEL}" > "${state_path}"
    : > "${log_path}"

    if FAKE_MODEL_STATUS="503" run_installer "${home_dir}" "${log_path}" "${state_path}" >/dev/null 2>&1; then
        fail "Unhealthy restored service was reported as successful"
    fi

    assert_contains "${state_path}" "gui/${USER_ID}/${NEW_LABEL}"
    assert_not_contains "${log_path}" "disable gui/${USER_ID}/${NEW_LABEL}"
}

# 验证旧安装器拥有的面板开关被定向迁移，其他配置不受影响。
test_legacy_label_and_panel_migration() {
    local home_dir="$(<"${TEMP_ROOT}/installed-home")"
    local log_path="$(<"${TEMP_ROOT}/installed-log")"
    local state_path="$(<"${TEMP_ROOT}/installed-state")"
    local runtime_dir="${home_dir}/Library/Application Support/Codex Auth/CPA"
    local new_plist="${home_dir}/Library/LaunchAgents/${NEW_LABEL}.plist"
    local legacy_plist="${home_dir}/Library/LaunchAgents/${LEGACY_LABEL}.plist"
    local migrated_config="${TEMP_ROOT}/legacy-config.yaml"
    printf '%s\n' "7.2.109" > "${runtime_dir}/VERSION"
    /usr/bin/sed 's/^  disable-control-panel: false$/  disable-control-panel: true/' \
        "${runtime_dir}/config.yaml" > "${migrated_config}"
    /bin/mv "${migrated_config}" "${runtime_dir}/config.yaml"
    /bin/mv "${new_plist}" "${legacy_plist}"
    /usr/bin/plutil -replace Label -string "${LEGACY_LABEL}" "${legacy_plist}"
    printf 'gui/%s/%s\n' "${USER_ID}" "${LEGACY_LABEL}" > "${state_path}"
    : > "${log_path}"

    run_installer "${home_dir}" "${log_path}" "${state_path}"

    assert_contains "${runtime_dir}/config.yaml" "  disable-control-panel: false"
    assert_contains "${runtime_dir}/config.yaml" 'api-key: "user-owned-provider-key"'
    assert_file_missing "${legacy_plist}"
    assert_file_exists "${new_plist}"
    assert_contains "${log_path}" "bootout gui/${USER_ID}/${LEGACY_LABEL}"
    assert_contains "${log_path}" "bootstrap gui/${USER_ID}"
    assert_contains "${state_path}" "gui/${USER_ID}/${NEW_LABEL}"
}

# 按从无副作用校验到升级迁移的顺序执行安装器回归。
main() {
    create_fixtures
    test_pinned_checksums
    test_fresh_install_is_stopped
    test_credential_helper_rejects_unsafe_proxy_routes
    test_stopped_upgrade_preserves_configuration
    test_running_upgrade_restores_service
    test_running_upgrade_keeps_service_for_app_validation
    test_failed_running_upgrade_keeps_service_loaded
    test_legacy_label_and_panel_migration
    echo "CPA runtime installer tests passed."
}

main "$@"
