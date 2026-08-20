#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIGURATOR="${SCRIPT_DIR}/configure-newapi-cpa-channel.sh"
readonly MANAGED_NAME="Codex Auth CPA"
readonly MANAGED_REMARK="Managed by Codex Auth. Uses the local CPA default API key."
readonly EXPECTED_MODELS="gpt-5.5,gpt-5.6-sol,gpt-5.6-terra"
readonly TEST_ROOT="$(mktemp -d /tmp/codex-auth-newapi-cpa-channel-test.XXXXXX)"

# 仅清理本测试创建的临时目录。
cleanup() {
    rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

# 输出失败原因并终止测试。
fail() {
    echo "$*" >&2
    exit 1
}

# 比较两个字符串并输出稳定错误。
assert_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'."
}

# 要求给定文本不包含敏感内容。
assert_not_contains() {
    local text="$1"
    local unexpected="$2"
    local label="$3"
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: output exposed sensitive content."
}

# 创建固定 NewAPI 版本和 CPA 客户端配置的隔离夹具。
create_fixture() {
    local fixture_root="$1"
    local cpa_key="${2:-cpa-secret-key}"
    local runtime_dir="${fixture_root}/NewAPI"
    local cpa_dir="${fixture_root}/CPA"
    install -d -m 700 "${runtime_dir}/data" "${runtime_dir}/backups" "${cpa_dir}"
    printf '%s\n' 'v1.0.0-rc.25' > "${runtime_dir}/VERSION"
    printf '{"base_url":"http://127.0.0.1:8317/v1","api_key":"%s"}\n' "${cpa_key}" > "${cpa_dir}/client.json"
    printf '%s\n' '{"data":[{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-sol"},{"id":"gpt-5.5"},{"id":"gpt-5.6-terra"},{"id":"  "}]}' > "${cpa_dir}/models.json"
    chmod 600 "${runtime_dir}/VERSION" "${cpa_dir}/client.json" "${cpa_dir}/models.json"
    /usr/bin/sqlite3 "${runtime_dir}/data/new-api.db" <<'SQL'
CREATE TABLE channels (
    id INTEGER PRIMARY KEY,
    type INTEGER DEFAULT 0,
    key TEXT NOT NULL,
    status INTEGER DEFAULT 1,
    name TEXT,
    weight INTEGER DEFAULT 0,
    created_time INTEGER,
    base_url TEXT DEFAULT '',
    models TEXT,
    "group" varchar(64) DEFAULT 'default',
    used_quota INTEGER DEFAULT 0,
    priority INTEGER DEFAULT 0,
    auto_ban INTEGER DEFAULT 1,
    other_info TEXT,
    tag TEXT,
    remark varchar(255),
    channel_info json,
    settings TEXT
);
CREATE TABLE abilities (
    "group" varchar(64) NOT NULL,
    model varchar(255) NOT NULL,
    channel_id INTEGER NOT NULL,
    enabled numeric,
    priority INTEGER DEFAULT 0,
    weight INTEGER DEFAULT 0,
    tag TEXT,
    PRIMARY KEY ("group", model, channel_id)
);
SQL
    chmod 600 "${runtime_dir}/data/new-api.db"
}

# 在测试模式下运行配置器并捕获标准输出和错误。
run_configurator() {
    local fixture_root="$1"
    CODEX_AUTH_TESTING=1 \
    CODEX_AUTH_NEWAPI_RUNTIME_DIR="${fixture_root}/NewAPI" \
    CODEX_AUTH_CPA_CLIENT_PATH="${fixture_root}/CPA/client.json" \
    CODEX_AUTH_CPA_MODELS_PATH="${fixture_root}/CPA/models.json" \
    "${CONFIGURATOR}" 2>&1
}

# 返回测试数据库路径。
database_path() {
    printf '%s/NewAPI/data/new-api.db' "$1"
}

[[ -x "${CONFIGURATOR}" ]] || fail "NewAPI CPA channel configurator is missing or not executable."

fixture="${TEST_ROOT}/create"
create_fixture "${fixture}" "first-secret"
output="$(run_configurator "${fixture}")"
db="$(database_path "${fixture}")"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")" "1" "Managed channel count"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT type || '|' || key || '|' || status || '|' || base_url || '|' || models || '|' || \"group\" FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")" "1|first-secret|1|http://127.0.0.1:8317|${EXPECTED_MODELS}|default" "Managed channel fields"
managed_id="$(/usr/bin/sqlite3 "${db}" "SELECT id FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT group_concat(model, ',') FROM (SELECT model FROM abilities WHERE channel_id=${managed_id} AND \"group\"='default' AND enabled=1 ORDER BY model);")" "${EXPECTED_MODELS}" "Managed ability models"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT typeof(channel_info) || '|' || json_valid(channel_info) FROM channels WHERE id=${managed_id};")" "blob|1" "Managed channel JSON storage"
assert_not_contains "${output}" "first-secret" "Create output"

# 模型和 Key 均未变化时必须幂等返回，不产生额外数据库备份。
backup_count="$(find "${fixture}/NewAPI/backups" -type f | wc -l | tr -d ' ')"
output="$(run_configurator "${fixture}")"
assert_equal "$(find "${fixture}/NewAPI/backups" -type f | wc -l | tr -d ' ')" "${backup_count}" "Idempotent backup count"
assert_not_contains "${output}" "first-secret" "Idempotent output"

# 用户自建的同地址渠道不能被自动渠道认领或覆盖。
/usr/bin/sqlite3 "${db}" "INSERT INTO channels(type,key,status,name,base_url,models,\"group\",remark) VALUES(1,'user-secret',1,'User CPA','http://127.0.0.1:8317','user-model','default','User managed');"
printf '%s\n' '{"base_url":"http://127.0.0.1:8317/v1","api_key":"second-secret"}' > "${fixture}/CPA/client.json"
printf '%s\n' '{"data":[{"id":"o3"},{"id":"gpt-5.6-sol"},{"id":"o3"}]}' > "${fixture}/CPA/models.json"
output="$(run_configurator "${fixture}")"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT key || '|' || models || '|' || remark FROM channels WHERE name='User CPA';")" "user-secret|user-model|User managed" "User channel preservation"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT key FROM channels WHERE id=${managed_id};")" "second-secret" "Managed key refresh"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT models FROM channels WHERE id=${managed_id};")" "gpt-5.6-sol,o3" "Managed model refresh"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT group_concat(model, ',') FROM (SELECT model FROM abilities WHERE channel_id=${managed_id} ORDER BY model);")" "gpt-5.6-sol,o3" "Managed ability refresh"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT typeof(channel_info) || '|' || json_valid(channel_info) FROM channels WHERE id=${managed_id};")" "blob|1" "Updated channel JSON storage"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")" "1" "Idempotent managed channel count"
assert_not_contains "${output}" "second-secret" "Update output"

# 缺少最低健康模型时必须在数据库写入前失败。
fixture="${TEST_ROOT}/missing-managed-model"
create_fixture "${fixture}" "minimum-model-secret"
printf '%s\n' '{"data":[{"id":"gpt-5.6-terra"}]}' > "${fixture}/CPA/models.json"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "A CPA catalog without the managed model was accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "$(database_path "${fixture}")" "SELECT COUNT(*) FROM channels;")" "0" "Missing managed model write count"
assert_not_contains "${output}" "minimum-model-secret" "Missing managed model output"

# 含逗号的模型无法安全写入 NewAPI 逗号分隔字段，必须关闭失败。
fixture="${TEST_ROOT}/unsafe-model"
create_fixture "${fixture}" "unsafe-model-secret"
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"unsafe,model"}]}' > "${fixture}/CPA/models.json"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "A model identifier containing a comma was accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "$(database_path "${fixture}")" "SELECT COUNT(*) FROM channels;")" "0" "Unsafe model write count"
assert_not_contains "${output}" "unsafe-model-secret" "Unsafe model output"

# 非法 JSON 和缺失 id 的目录项必须在数据库写入前失败。
fixture="${TEST_ROOT}/malformed-catalog"
create_fixture "${fixture}" "malformed-catalog-secret"
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{}]}' > "${fixture}/CPA/models.json"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "A malformed CPA model catalog was accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "$(database_path "${fixture}")" "SELECT COUNT(*) FROM channels;")" "0" "Malformed catalog write count"
assert_not_contains "${output}" "malformed-catalog-secret" "Malformed catalog output"

# 缺失必要 schema 时必须在写入前失败。
fixture="${TEST_ROOT}/schema"
create_fixture "${fixture}"
db="$(database_path "${fixture}")"
/usr/bin/sqlite3 "${db}" "ALTER TABLE channels RENAME TO channels_full; CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT);"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "Incompatible NewAPI schema was accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM channels;")" "0" "Schema failure write count"

# 缺失 CPA Key 时必须失败且不得创建渠道。
fixture="${TEST_ROOT}/missing-key"
create_fixture "${fixture}"
printf '%s\n' '{"base_url":"http://127.0.0.1:8317/v1","api_key":""}' > "${fixture}/CPA/client.json"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "Missing CPA key was accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "$(database_path "${fixture}")" "SELECT COUNT(*) FROM channels;")" "0" "Missing key write count"

# 权限过宽的 CPA 配置必须在读取 Key 前被拒绝。
fixture="${TEST_ROOT}/permissions"
create_fixture "${fixture}" "permission-secret"
chmod 644 "${fixture}/CPA/client.json"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "Insecure CPA client configuration permissions were accepted."
fi
assert_equal "$(/usr/bin/sqlite3 "$(database_path "${fixture}")" "SELECT COUNT(*) FROM channels;")" "0" "Permission failure write count"
assert_not_contains "${output}" "permission-secret" "Permission failure output"

# 旧版 NewAPI 的 0644 数据库应在停服后自动收紧，再完成渠道配置。
fixture="${TEST_ROOT}/database-permissions"
create_fixture "${fixture}" "database-permission-secret"
db="$(database_path "${fixture}")"
chmod 644 "${db}"
output="$(run_configurator "${fixture}")"
assert_equal "$(/usr/bin/stat -f '%Lp' "${db}")" "600" "Secured database permissions"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")" "1" "Secured database channel count"
assert_not_contains "${output}" "database-permission-secret" "Database permission output"

# ability 写入失败时必须回滚同一事务中的渠道创建。
fixture="${TEST_ROOT}/rollback"
create_fixture "${fixture}"
db="$(database_path "${fixture}")"
/usr/bin/sqlite3 "${db}" "CREATE TRIGGER reject_ability BEFORE INSERT ON abilities BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
if output="$(run_configurator "${fixture}" 2>&1)"; then
    fail "Ability failure did not abort channel provisioning."
fi
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM channels;")" "0" "Transaction rollback channel count"
assert_equal "$(/usr/bin/sqlite3 "${db}" "SELECT COUNT(*) FROM abilities;")" "0" "Transaction rollback ability count"

echo "NewAPI CPA channel configurator tests passed."
