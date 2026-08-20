#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-desktop}"

case "$TARGET" in
  desktop)
    INSTALL_DIR="$HOME/Desktop"
    ;;
  applications)
    INSTALL_DIR="/Applications"
    ;;
  *)
    echo "Usage: $0 [desktop|applications]" >&2
    exit 2
    ;;
esac

DESTINATION="$INSTALL_DIR/Codex Switch.app"
LEGACY_DESTINATION="$INSTALL_DIR/Codex Auth.app"
BUILD_ROOT="${CODEX_AUTH_APP_BUILD_ROOT:-${TMPDIR:-/tmp}/codex-auth-menu-app-build}"
STAGING="$BUILD_ROOT/install/Codex Switch.app"

echo "Building app for installation..."
CODEX_AUTH_APP_BUNDLE_PATH="$STAGING" "$SCRIPT_DIR/build-app.sh" >/dev/null

echo "Installing $DESTINATION..."
rm -rf "$DESTINATION"
cp -R "$STAGING" "$DESTINATION"

if [[ -e "$LEGACY_DESTINATION" ]]; then
  echo "Removing legacy app $LEGACY_DESTINATION..."
  rm -rf "$LEGACY_DESTINATION"
fi

echo "$DESTINATION"
