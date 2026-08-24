#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_NEWAPI_VERSION="v1.0.0-rc.25"
readonly MANAGED_NAME="Codex Auth CPA"
readonly MANAGED_REMARK="Managed by Codex Auth. Uses the local CPA default API key."
readonly REQUIRED_MANAGED_MODEL="gpt-5.6-sol"
readonly MANAGED_GROUP="default"
readonly EXPECTED_CPA_BASE_URL="http://127.0.0.1:8317/v1"
readonly CHANNEL_BASE_URL="http://127.0.0.1:8317"
readonly NEWAPI_LABEL="com.codex-auth.newapi"
readonly USER_HOME="${HOME:?HOME is required}"
readonly DEFAULT_NEWAPI_RUNTIME_DIR="${USER_HOME}/Library/Application Support/Codex Auth/NewAPI"
readonly DEFAULT_CPA_CLIENT_PATH="${USER_HOME}/Library/Application Support/Codex Auth/CPA/client.json"
readonly MANAGED_NEWAPI_RETRY_TIMES="2"
readonly MANAGED_NEWAPI_DISABLE_STATUS_CODES="401,403,429,500-599"
readonly MANAGED_NEWAPI_RETRY_STATUS_CODES="401-407,409-499,500-503,505-523,525-599"
TEMP_ROOT=""
MODEL_LIST=""
MODEL_LIST_HEX=""
MODEL_COUNT="0"
MODEL_ABILITIES_SQL=""

# 仅由 Codex Auth 管理的 NewAPI 可靠性选项，其他系统选项保持用户所有。
MANAGED_NEWAPI_OPTION_SQL=""

# 仅清理本次模型发现创建的受保护临时目录。
cleanup() {
    [[ -z "${TEMP_ROOT}" ]] || rm -rf -- "${TEMP_ROOT}"
}
trap cleanup EXIT

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
        [[ -n "${CODEX_AUTH_NEWAPI_RUNTIME_DIR:-}" && -n "${CODEX_AUTH_CPA_CLIENT_PATH:-}" && -n "${CODEX_AUTH_CPA_MODELS_PATH:-}" ]] || \
            fail 64 "Test path overrides are incomplete."
        case "${CODEX_AUTH_NEWAPI_RUNTIME_DIR}" in
            /tmp/*) ;;
            *) fail 64 "The test NewAPI runtime must be under /tmp." ;;
        esac
        case "${CODEX_AUTH_CPA_CLIENT_PATH}" in
            /tmp/*) ;;
            *) fail 64 "The test CPA configuration must be under /tmp." ;;
        esac
        case "${CODEX_AUTH_CPA_MODELS_PATH}" in
            /tmp/*) ;;
            *) fail 64 "The test CPA model catalog must be under /tmp." ;;
        esac
        NEWAPI_RUNTIME_DIR="${CODEX_AUTH_NEWAPI_RUNTIME_DIR}"
        CPA_CLIENT_PATH="${CODEX_AUTH_CPA_CLIENT_PATH}"
        CPA_MODELS_PATH="${CODEX_AUTH_CPA_MODELS_PATH}"
    else
        [[ -z "${CODEX_AUTH_NEWAPI_RUNTIME_DIR:-}" && -z "${CODEX_AUTH_CPA_CLIENT_PATH:-}" && -z "${CODEX_AUTH_CPA_MODELS_PATH:-}" ]] || \
            fail 64 "Path overrides are available only in test mode."
        NEWAPI_RUNTIME_DIR="${DEFAULT_NEWAPI_RUNTIME_DIR}"
        CPA_CLIENT_PATH="${DEFAULT_CPA_CLIENT_PATH}"
        CPA_MODELS_PATH=""
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

# 通过临时头文件请求本机 CPA 模型目录，避免客户端 Key 出现在进程参数或输出中。
fetch_model_catalog() {
    local cpa_key="$1"
    if [[ "${CODEX_AUTH_TESTING:-0}" == "1" ]]; then
        [[ -f "${CPA_MODELS_PATH}" && ! -L "${CPA_MODELS_PATH}" ]] || \
            fail 66 "The test CPA model catalog is missing or is not a regular file."
        return 0
    fi

    [[ -x /usr/bin/curl ]] || fail 69 "The system curl client is unavailable."
    [[ "${cpa_key}" != *$'\t'* && "${cpa_key}" != *$'\n'* && "${cpa_key}" != *$'\r'* ]] || \
        fail 78 "The managed CPA client Key contains unsupported control characters."
    TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-auth-cpa-models.XXXXXX")" || \
        fail 74 "Unable to create a protected model discovery directory."
    chmod 700 "${TEMP_ROOT}"
    local header_path="${TEMP_ROOT}/authorization.header"
    CPA_MODELS_PATH="${TEMP_ROOT}/models.json"
    /usr/bin/printf 'Authorization: Bearer %s\n' "${cpa_key}" > "${header_path}"
    chmod 600 "${header_path}"
    if ! /usr/bin/curl --silent --show-error --fail-with-body --max-time 10 \
        --noproxy '*' --header "@${header_path}" --output "${CPA_MODELS_PATH}" \
        "${EXPECTED_CPA_BASE_URL}/models"; then
        fail 69 "Unable to read the managed CPA model catalog."
    fi
    chmod 600 "${CPA_MODELS_PATH}"
}

# 校验模型目录并生成稳定列表及事务内使用的安全十六进制 SQL。
prepare_model_catalog() {
    local catalog_path_hex=""
    local catalog_is_valid=""
    local invalid_entry_count=""
    local unsafe_model_count=""
    local required_model_count=""
    local model_hex_lines=""
    catalog_path_hex="$(hex_encode "${CPA_MODELS_PATH}")"
    catalog_is_valid="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
)
SELECT CASE
    WHEN json_valid(value) AND json_type(value, '$.data') = 'array' THEN 1
    ELSE 0
END
FROM document;
SQL
)" || fail 78 "Unable to parse the managed CPA model catalog."
    [[ "${catalog_is_valid}" == "1" ]] || fail 78 "The managed CPA model catalog is invalid."

    invalid_entry_count="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
)
SELECT COUNT(*)
FROM document, json_each(document.value, '$.data') AS item
WHERE COALESCE(json_type(item.value, '$.id'), '') != 'text';
SQL
)" || fail 78 "Unable to inspect the managed CPA model catalog."
    [[ "${invalid_entry_count}" == "0" ]] || fail 78 "The managed CPA model catalog contains an invalid entry."

    unsafe_model_count="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
), models(model) AS (
    SELECT trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ')
    FROM document, json_each(document.value, '$.data') AS item
)
SELECT COUNT(*)
FROM models
WHERE model != ''
  AND (instr(model, ',') > 0 OR instr(model, char(9)) > 0 OR instr(model, char(10)) > 0 OR instr(model, char(13)) > 0 OR instr(model, char(0)) > 0);
SQL
)" || fail 78 "Unable to validate the managed CPA model identifiers."
    [[ "${unsafe_model_count}" == "0" ]] || \
        fail 78 "The managed CPA model catalog contains an unsupported model identifier."

    MODEL_LIST="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
), models(model) AS (
    SELECT DISTINCT trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ')
    FROM document, json_each(document.value, '$.data') AS item
    WHERE trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ') != ''
)
SELECT group_concat(model, ',') FROM (SELECT model FROM models ORDER BY model COLLATE BINARY);
SQL
)" || fail 78 "Unable to normalize the managed CPA model catalog."
    [[ -n "${MODEL_LIST}" ]] || fail 78 "The managed CPA model catalog is empty."
    MODEL_LIST_HEX="$(hex_encode "${MODEL_LIST}")"
    MODEL_COUNT="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
)
SELECT COUNT(DISTINCT trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' '))
FROM document, json_each(document.value, '$.data') AS item
WHERE trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ') != '';
SQL
)" || fail 78 "Unable to count the managed CPA models."
    [[ "${MODEL_COUNT}" =~ ^[1-9][0-9]*$ ]] || fail 78 "The managed CPA model count is invalid."
    required_model_count="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
)
SELECT COUNT(*)
FROM document, json_each(document.value, '$.data') AS item
WHERE trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ') = '${REQUIRED_MANAGED_MODEL}';
SQL
)" || fail 78 "Unable to validate the required managed CPA model."
    [[ "${required_model_count}" -ge 1 ]] || \
        fail 78 "The managed CPA model catalog does not contain ${REQUIRED_MANAGED_MODEL}."

    model_hex_lines="$(/usr/bin/sqlite3 ':memory:' <<SQL
WITH document(value) AS (
    SELECT CAST(readfile(CAST(X'${catalog_path_hex}' AS TEXT)) AS TEXT)
), models(model) AS (
    SELECT DISTINCT trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ')
    FROM document, json_each(document.value, '$.data') AS item
    WHERE trim(json_extract(item.value, '$.id'), char(9) || char(10) || char(13) || ' ') != ''
)
SELECT hex(model) FROM models ORDER BY model COLLATE BINARY;
SQL
)" || fail 78 "Unable to encode the managed CPA models."
    MODEL_ABILITIES_SQL=""
    while IFS= read -r model_hex; do
        [[ -n "${model_hex}" ]] || continue
        MODEL_ABILITIES_SQL+="INSERT INTO abilities(\"group\", model, channel_id, enabled, priority, weight, tag) VALUES('${MANAGED_GROUP}', CAST(X'${model_hex}' AS TEXT), CHANNEL_ID_PLACEHOLDER, 1, 0, 0, NULL);"$'\n'
    done <<< "${model_hex_lines}"
}

# 构造 NewAPI 故障转移选项的幂等 SQL，不记录 Key 或上游响应。
prepare_failover_options() {
    MANAGED_NEWAPI_OPTION_SQL="INSERT INTO options(key, value) VALUES
('RetryTimes', '${MANAGED_NEWAPI_RETRY_TIMES}'),
('AutomaticDisableChannelEnabled', 'true'),
('AutomaticDisableStatusCodes', '${MANAGED_NEWAPI_DISABLE_STATUS_CODES}'),
('AutomaticRetryStatusCodes', '${MANAGED_NEWAPI_RETRY_STATUS_CODES}'),
('channel_affinity_setting.keep_on_channel_disabled', 'false')
ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
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
    local model_list_hex="$3"
    local model_count="$4"
    local count=""
    count="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
SELECT COUNT(*)
FROM channels c
WHERE c.id = ${managed_id}
  AND c.type = 1
  AND hex(c.key) = upper('${key_hex}')
  AND c.status = 1
  AND c.base_url = '${CHANNEL_BASE_URL}'
  AND hex(c.models) = upper('${model_list_hex}')
  AND c."group" = '${MANAGED_GROUP}'
  AND typeof(c.channel_info) = 'blob'
  AND json_valid(c.channel_info)
  AND COALESCE(c.priority, 0) = 0
  AND COALESCE(c.weight, 0) = 0
  AND (SELECT COUNT(*) FROM abilities a WHERE a.channel_id = c.id) = ${model_count}
  AND (
      SELECT group_concat(model, ',')
      FROM (
          SELECT a.model
          FROM abilities a
          WHERE a.channel_id = ${managed_id}
            AND a."group" = '${MANAGED_GROUP}'
            AND a.enabled = 1
            AND COALESCE(a.priority, 0) = 0
            AND COALESCE(a.weight, 0) = 0
          ORDER BY a.model COLLATE BINARY
      )
  ) = CAST(X'${model_list_hex}' AS TEXT);
SQL
)" || fail 74 "Unable to inspect the managed NewAPI channel."
    [[ "${count}" == "1" ]]
}

# 返回 Codex Auth 管理的故障转移选项是否完整且符合期望，避免漏迁移已有安装。
failover_options_are_current() {
    local count=""
    count="$(/usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
SELECT COUNT(*)
FROM options
WHERE (key = 'RetryTimes' AND value = '${MANAGED_NEWAPI_RETRY_TIMES}')
   OR (key = 'AutomaticDisableChannelEnabled' AND value = 'true')
   OR (key = 'AutomaticDisableStatusCodes' AND value = '${MANAGED_NEWAPI_DISABLE_STATUS_CODES}')
   OR (key = 'AutomaticRetryStatusCodes' AND value = '${MANAGED_NEWAPI_RETRY_STATUS_CODES}')
   OR (key = 'channel_affinity_setting.keep_on_channel_disabled' AND value = 'false');
SQL
)" || fail 74 "Unable to inspect the managed NewAPI failover options."
    [[ "${count}" == "5" ]]
}

# 在一个 SQLite 事务内创建或更新专属渠道及其路由能力。
upsert_managed_channel() {
    local managed_id="$1"
    local key_hex="$2"
    local now="$3"
    local model_list_hex="$4"
    local ability_sql=""
    if [[ -n "${managed_id}" ]]; then
        ability_sql="${MODEL_ABILITIES_SQL//CHANNEL_ID_PLACEHOLDER/${managed_id}}"
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
    models = CAST(X'${model_list_hex}' AS TEXT),
    "group" = '${MANAGED_GROUP}',
    priority = 0,
    auto_ban = 1,
    remark = '${MANAGED_REMARK}',
    channel_info = CAST('{}' AS BLOB)
WHERE id = ${managed_id};
DELETE FROM abilities WHERE channel_id = ${managed_id};
${ability_sql}
${MANAGED_NEWAPI_OPTION_SQL}
COMMIT;
SQL
    else
        local channel_reference="(SELECT id FROM channels WHERE name='${MANAGED_NAME}' AND remark='${MANAGED_REMARK}')"
        ability_sql="${MODEL_ABILITIES_SQL//CHANNEL_ID_PLACEHOLDER/${channel_reference}}"
        /usr/bin/sqlite3 "${NEWAPI_DATABASE_PATH}" <<SQL
.bail on
BEGIN IMMEDIATE;
INSERT INTO channels(
    type, key, status, name, weight, created_time, base_url, models, "group",
    used_quota, priority, auto_ban, other_info, tag, remark, channel_info, settings
) VALUES(
    1, CAST(X'${key_hex}' AS TEXT), 1, '${MANAGED_NAME}', 0, ${now},
    '${CHANNEL_BASE_URL}', CAST(X'${model_list_hex}' AS TEXT), '${MANAGED_GROUP}',
    0, 0, 1, '', NULL, '${MANAGED_REMARK}', CAST('{}' AS BLOB), ''
);
${ability_sql}
${MANAGED_NEWAPI_OPTION_SQL}
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
    [[ -n "${key_hex}" ]] || fail 78 "The managed CPA client Key cannot be encoded."

    fetch_model_catalog "${cpa_key}"
    unset cpa_key
    prepare_model_catalog
    prepare_failover_options

    validate_schema channels id type key status name weight created_time base_url models group priority auto_ban remark channel_info settings
    validate_schema abilities group model channel_id enabled priority weight tag
    validate_schema options key value

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
        if managed_channel_is_current "${managed_id}" "${key_hex}" "${MODEL_LIST_HEX}" "${MODEL_COUNT}" && \
            failover_options_are_current; then
            echo "The Codex Auth managed CPA channel is already configured."
            return 0
        fi
    fi

    backup_database
    upsert_managed_channel "${managed_id}" "${key_hex}" "$(/bin/date +%s)" "${MODEL_LIST_HEX}" || \
        fail 74 "Unable to configure the Codex Auth managed CPA channel; the transaction was rolled back."
    echo "The Codex Auth managed CPA channel is configured."
}

main "$@"
