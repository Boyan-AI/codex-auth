#!/usr/bin/env bash
set -euo pipefail

# 受控升级入口：清单只负责声明项目已验证的资产，实际安装复用现有安装器。
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: $0 <manifest-json>" >&2; exit 64; }
MANIFEST="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="${HOME:?HOME is required}"
TMP_ROOT="$(mktemp -d /tmp/codex-auth-runtime-update.XXXXXX)"
RUNTIME_ROOT="$USER_HOME/Library/Application Support/Codex Auth"
BACKUP_ROOT="$TMP_ROOT/backup"
mkdir -p "$BACKUP_ROOT"
for component in NewAPI CPA CPAMP; do
  source_dir="$RUNTIME_ROOT/$component"
  [[ -d "$source_dir" ]] && /bin/cp -R "$source_dir" "$BACKUP_ROOT/$component"
done
restore_on_failure() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    for component in NewAPI CPA CPAMP; do
      backup_dir="$BACKUP_ROOT/$component"
      target_dir="$RUNTIME_ROOT/$component"
      if [[ -d "$backup_dir" ]]; then
        /bin/rm -rf "$target_dir"
        /bin/cp -R "$backup_dir" "$target_dir"
      fi
    done
    echo "Runtime upgrade failed; previous runtime files were restored." >&2
  fi
  rm -rf -- "$TMP_ROOT"
  exit "$status"
}
trap restore_on_failure EXIT

read_json() { /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
download_verified() {
  local url="$1" expected="$2" output="$3"
  [[ "$url" == https://* ]] || { echo "Runtime asset URL must use HTTPS." >&2; return 65; }
  /usr/bin/curl --fail --silent --show-error --location --max-time 120 --output "$output" "$url"
  [[ "$(sha256 "$output")" == "$expected" ]] || { echo "Runtime asset checksum mismatch." >&2; return 65; }
}

newapi_url="$(read_json components.newapi.asset_url)"
cpa_url="$(read_json components.cpa.asset_url)"
cpamp_url="$(read_json components.cpamp.asset_url)"
[[ -n "$newapi_url" && -n "$cpa_url" && -n "$cpamp_url" ]] || { echo "No verified runtime upgrade assets are available." >&2; exit 78; }

newapi_asset="$TMP_ROOT/new-api"
cpa_asset="$TMP_ROOT/cpa.tar.gz"
cpamp_asset="$TMP_ROOT/cpamp.tar.gz"
download_verified "$newapi_url" "$(read_json components.newapi.sha256)" "$newapi_asset"
download_verified "$cpa_url" "$(read_json components.cpa.sha256)" "$cpa_asset"
download_verified "$cpamp_url" "$(read_json components.cpamp.sha256)" "$cpamp_asset"
cpa_panel="$USER_HOME/Library/Application Support/Codex Auth/CPA/static/management.html"
[[ -f "$cpa_panel" ]] || { echo "Installed CPA management panel is missing." >&2; exit 78; }

# 安装器内部负责备份、原子替换、LaunchAgent 和健康检查；没有任何服务时也保持幂等。
"$SCRIPT_DIR/install-newapi-runtime.sh" "$newapi_asset"
"$SCRIPT_DIR/install-cpa-runtime.sh" "$cpa_asset" "$cpa_panel"
"$SCRIPT_DIR/install-cpamp-manager.sh"
echo "Runtime upgrade completed."
