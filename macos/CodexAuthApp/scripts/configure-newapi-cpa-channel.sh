#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_NEWAPI_VERSION="v1.0.0-rc.25"
readonly MANAGED_NAME="Codex Auth CPA"
readonly MANAGED_REMARK="Managed by Codex Auth. Uses the local CPA default API key."
readonly MANAGED_MODEL="gpt-5.6-sol"
readonly MANAGED_GROUP="default"
readonly EXPECTED_CPA_BASE_URL="http://127.0.0.1:8317/v1"
readonly CHANNEL_BASE_URL="http://127.0.0.1:8317"
readonly NEWAPI_LABEL="com.codex-auth.newapi"
readonly USER_HOME="${HOME:?HOME is required}"
readonly DEFAULT_NEWAPI_RUNTIME_DIR="${USER_HOME}/Library/Application Support/Codex Auth/NewAPI"
readonly DEFAULT_CPA_CLIENT_PATH="${USER_HOME}/Library/Application Support/Codex Auth/CPA/client.json"

# 输出固定英文错误并终止配置，避免上层把部分写入误报为成功。
fail() {
    local exit_code="$1"
    shift
    echo "$*" >&2
    exit "${exit_code}"
}

# 仅允许测试在 /tmp 下覆盖真实运行目录，防止普通调用重定向数据库目标。
resolve_paths() {
    if [[ "${CODEX_AUTH_TESTING:-0}" == "1" ]]; then
        [[ -n "${CODEX_AUTH_NEWAPI_RUNTIME_DIR:-}" && -n "${CODEX_AUTH_CPA_CLIENT_PATH:-}" ]] || \
            fail 64 "Test path overrides are incomplete."
        case "${CODEX_AUTH_NEWAPI_RUNTIME_DIR}" in
            /tmp/*) ;;
            *) fail 64 "The test NewAPI runtime must be under /tmp." ;;
        esac
        case "${CODEX_AUTH_CPA_CLIENT_PATH}" in
            /tmp/*) ;;
            *) fail 64 "The test CPA configuration must be under /tmp." ;;
        esac
        NEWAPI_RUNTIME_DIR="${CODEX_AUTH_NEWAPI_RUNTIME_DIR}"
        CPA_CLIENT_PATH="${CODEX_AUTH_CPA_CLIENT_PATH}"
    else
        [[ -z "${CODEX_AUTH_NEWAPI_RUNTIME_DIR:-}" && -z "${CODEX_AUTH_CPA_CLIENT_PATH:-}" ]] || \
            fail 64 "Path overrides are available only in test mode."
        NEWAPI_RUNTIME_DIR="${DEFAULT_NEWAPI_RUNTIME_DIR}"
        CPA_CLIENT_PATH="${DEFAULT_CPA_CLIENT_PATH}"
    fi
    NEWAPI_DATABASE_PATH="${NEWAPI_RUNTIME_DIR}/data/new-api.db"
    NEWAPI_VERSION_PATH="${NEWAPI_RUNTIME_DIR}/VERSION"
    NEWAPI_BACKUP_DIR="${NEWAPI_RUNTIME_DIR}/backups"
}

# 要求生产环境中的 NewAPI LaunchAgent 和监听端口均已停止。
require_newapi_stopped() {
    [[ "${CODEX_AUTH_TESTING:-0}" == "1" ]] && return 0
    if /bin/launchctl print "gui/${UID}/${NEWAPI_LABEL}" >/dev/null 2>&1; then
        fail 69 "NewAPI must be stopped before configuring the managed CPA channel."
    fi
    if /usr/bin/nc -z -w 1 127.0.0.1 3000 >/dev/null 2>&1; then
        fail 69 "Port 3000 is still in use; refusing to modify the NewAPI database."
    fi
}

# 使用 macOS plist 工具从 JSON 中读取必需字符串。
read_json_string() {
    local path="$1"
    local key="$2"
    /usr/bin/plutil -extract "${key}" raw -o - "${path}" 2>/dev/null || \
        fail 78 "Configuration is missing ${key}: ${path}"
}

# 要求包含本机密钥或渠道凭据的文件仅允许当前用户读写。
require_private_file() {
    local path="$1"
    local label="$2"
    local mode=""
    mode="$(/usr/bin/stat -f '%Lp' "${path}" 2>/dev/null)" || fail 78 "Unable to inspect ${label} permissions."
    [[ "${mode}" == "600" ]] || fail 78 "${label} permissions must be 0600."
}

# 兼容旧版 NewAPI 以 0644 创建数据库的情况，仅收紧当前用户拥有的真实普通文件。
secure_managed_database() {
    [[ ! -L "${NEWAPI_DATABASE_PATH}" ]] || fail 78 "The managed NewAPI database must not be a symbolic link."
    local owner_uid=""
    owner_uid="$(/usr/bin/stat -f '%u' "${NEWAPI_DATABASE_PATH}" 2>/dev/null)" || \
        fail 78 "Unable to inspect the managed NewAPI database owner."
    [[ "${owner_uid}" == "${UID}" ]] || fail 78 "The managed NewAPI database must be owned by the current user."
    chmod 600 "${NEWAPI_DATABASE_PATH}" || fail 78 "Unable to secure the managed NewAPI database permissions."
    require_private_file "${NEWAPI_DATABASE_PATH}" "The managed NewAPI database"
}

# 把敏感字符串转为 SQL 十六进制字面量内容，避免拼接引号或暴露到进程参数。
hex_encode() {
    LC_ALL=C /usr/bin/printf '%s' "$1" | /usr/bin/xxd -p | /usr/bin/tr -d '\n'
}

# 校验固定版本数据库包含渠道与能力同步所需的全部列。
validate_schema() {
    local table="$1"
    shift
    local column=""
    local count=""
    for column in "$@"; do
        count="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" \
            "SELECT COUNT(*) FROM pragma_table_info('${table}') WHERE name='${column}';")" || \
            fail 78 "Unable to inspect the NewAPI database schema."
        [[ "${count}" == "1" ]] || \
            fail 78 "The pinned NewAPI database schema is incompatible: missing ${table}.${column}."
    done
}

# 在真实写入前截断 WAL 并创建可恢复的主数据库备份。
backup_database() {
    install -d -m 700 "${NEWAPI_BACKUP_DIR}"
    /usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null || \
        fail 74 "Unable to checkpoint the NewAPI database before backup."
    local backup_path="${NEWAPI_BACKUP_DIR}/new-api.pre-cpa-channel.$(/bin/date +%Y%m%d-%H%M%S).$$.db"
    /bin/cp -p "${NEWAPI_DATABASE_PATH}" "${backup_path}" || \
        fail 74 "Unable to back up the NewAPI database."
    chmod 600 "${backup_path}"
}

# 返回专属渠道是否已经完全符合期望，避免无变化时重复备份和写库。
managed_channel_is_current() {
    local managed_id="$1"
    local key_hex="$2"
    local count=""
    count="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
SELECT COUNT(*)
FROM channels c
WHERE c.id = ${managed_id}
  AND c.type = 1
  AND hex(c.key) = upper('${key_hex}')
  AND c.status = 1
  AND c.base_url = '${CHANNEL_BASE_URL}'
  AND c.models = '${MANAGED_MODEL}'
  AND c."group" = '${MANAGED_GROUP}'
  AND typeof(c.channel_info) = 'blob'
  AND json_valid(c.channel_info)
  AND COALESCE(c.priority, 0) = 0
  AND COALESCE(c.weight, 0) = 0
  AND (SELECT COUNT(*) FROM abilities a WHERE a.channel_id = c.id) = 1
  AND EXISTS (
      SELECT 1 FROM abilities a
      WHERE a.channel_id = c.id
        AND a."group" = '${MANAGED_GROUP}'
        AND a.model = '${MANAGED_MODEL}'
        AND a.enabled = 1
        AND COALESCE(a.priority, 0) = 0
        AND COALESCE(a.weight, 0) = 0
  );
SQL
)" || fail 74 "Unable to inspect the managed NewAPI channel."
    [[ "${count}" == "1" ]]
}

# 在一个 SQLite 事务内创建或更新专属渠道及其路由能力。
upsert_managed_channel() {
    local managed_id="$1"
    local key_hex="$2"
    local now="$3"
    if [[ -n "${managed_id}" ]]; then
        /usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
.bail on
BEGIN IMMEDIATE;
UPDATE channels
SET type = 1,
    key = CAST(X'${key_hex}' AS TEXT),
    status = 1,
    name = '${MANAGED_NAME}',
    weight = 0,
    base_url = '${CHANNEL_BASE_URL}',
    models = '${MANAGED_MODEL}',
    "group" = '${MANAGED_GROUP}',
    priority = 0,
    auto_ban = 1,
    remark = '${MANAGED_REMARK}',
    channel_info = CAST('{}' AS BLOB)
WHERE id = ${managed_id};
DELETE FROM abilities WHERE channel_id = ${managed_id};
INSERT INTO abilities("group", model, channel_id, enabled, priority, weight, tag)
VALUES('${MANAGED_GROUP}', '${MANAGED_MODEL}', ${managed_id}, 1, 0, 0, NULL);
COMMIT;
SQL
    else
        /usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
.bail on
BEGIN IMMEDIATE;
INSERT INTO channels(
    type, key, status, name, weight, created_time, base_url, models, "group",
    used_quota, priority, auto_ban, other_info, tag, remark, channel_info, settings
) VALUES(
    1, CAST(X'${key_hex}' AS TEXT), 1, '${MANAGED_NAME}', 0, ${now},
    '${CHANNEL_BASE_URL}', '${MANAGED_MODEL}', '${MANAGED_GROUP}',
    0, 0, 1, '', NULL, '${MANAGED_REMARK}', CAST('{}' AS BLOB), ''
);
INSERT INTO abilities("group", model, channel_id, enabled, priority, weight, tag)
VALUES('${MANAGED_GROUP}', '${MANAGED_MODEL}', last_insert_rowid(), 1, 0, 0, NULL);
COMMIT;
SQL
    fi
}

# 校验配置、备份数据库并幂等同步应用专属渠道。
main() {
    [[ $# -eq 0 ]] || fail 64 "Usage: configure-newapi-cpa-channel.sh"
    resolve_paths
    [[ -x /usr/bin/sqlite3 ]] || fail 69 "The system SQLite client is unavailable."
    [[ -f "${NEWAPI_VERSION_PATH}" ]] || fail 66 "The managed NewAPI version file is missing."
    [[ "$(<"${NEWAPI_VERSION_PATH}")" == "${EXPECTED_NEWAPI_VERSION}" ]] || \
        fail 78 "The installed NewAPI version is outside the managed channel contract."
    [[ -f "${NEWAPI_DATABASE_PATH}" ]] || fail 66 "The managed NewAPI database is missing."
    [[ -f "${CPA_CLIENT_PATH}" ]] || fail 66 "The managed CPA client configuration is missing."
    require_newapi_stopped
    secure_managed_database
    require_private_file "${CPA_CLIENT_PATH}" "The managed CPA client configuration"

    local cpa_base_url=""
    local cpa_key=""
    local key_hex=""
    cpa_base_url="$(read_json_string "${CPA_CLIENT_PATH}" base_url)"
    cpa_key="$(read_json_string "${CPA_CLIENT_PATH}" api_key)"
    [[ "${cpa_base_url}" == "${EXPECTED_CPA_BASE_URL}" ]] || \
        fail 78 "The CPA base URL is outside the managed NewAPI channel contract."
    [[ -n "${cpa_key}" ]] || fail 78 "The managed CPA client Key is empty."
    key_hex="$(hex_encode "${cpa_key}")"
    unset cpa_key
    [[ -n "${key_hex}" ]] || fail 78 "The managed CPA client Key cannot be encoded."

    validate_schema channels id type key status name weight created_time base_url models group priority auto_ban remark channel_info settings
    validate_schema abilities group model channel_id enabled priority weight tag

    local managed_count=""
    local managed_id=""
    managed_count="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" \
        "SELECT COUNT(*) FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")" || \
        fail 74 "Unable to inspect the managed NewAPI channel."
    [[ "${managed_count}" =~ ^[0-9]+$ ]] || fail 74 "The managed NewAPI channel count is invalid."
    ((managed_count <= 1)) || fail 78 "Multiple Codex Auth managed CPA channels exist; refusing an ambiguous update."
    if ((managed_count == 1)); then
        managed_id="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" \
            "SELECT id FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}';")"
        [[ "${managed_id}" =~ ^[0-9]+$ ]] || fail 74 "The managed NewAPI channel identifier is invalid."
        if managed_channel_is_current "${managed_id}" "${key_hex}"; then
            echo "The Codex Auth managed CPA channel is already configured."
            return 0
        fi
    fi

    backup_database
    upsert_managed_channel "${managed_id}" "${key_hex}" "$(/bin/date +%s)" || \
        fail 74 "Unable to configure the Codex Auth managed CPA channel; the transaction was rolled back."
    echo "The Codex Auth managed CPA channel is configured."
}

main "$@"
