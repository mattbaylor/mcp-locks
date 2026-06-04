#!/usr/bin/env bash
# mcp-locks uninstaller. Idempotent.
#
# Removes: binary, symlink, LaunchAgent. Does NOT remove state, registry, or
# logs by default — pass --purge to delete those too.

set -euo pipefail

BIN_DIR="${MCP_LOCKS_BIN_DIR:-$HOME/bin}"
PREFIX="${MCP_LOCKS_PREFIX:-/usr/local/bin}"
STATE_DIR="${MCP_LOCKS_STATE_DIR:-$HOME/.local/state/mcp-locks}"
REGISTRY_DIR="${MCP_LOCKS_REGISTRY_DIR:-$HOME/.config/mcp-locks}"
PLIST_LABEL="com.${USER}.mcp-locks-reap"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      cat <<EOF
mcp-locks uninstaller.

Usage: ./uninstall.sh [--purge]

  --purge    Also delete state file, registry, and logs.
             Without it, those are preserved so re-install picks up
             your existing claims and registry customizations.
EOF
      exit 0
      ;;
  esac
done

echo "==> Unloading LaunchAgent (if present)"
launchctl bootout "gui/$UID/${PLIST_LABEL}" 2>/dev/null && echo "    OK — unloaded" || echo "    (was not loaded)"

echo "==> Removing plist (if present)"
rm -f "$PLIST_PATH" && [ -e "$PLIST_PATH" ] || echo "    OK — $PLIST_PATH gone"

echo "==> Removing symlink $PREFIX/mcp-locks (if present)"
if [ -L "$PREFIX/mcp-locks" ]; then
  if [ -w "$PREFIX" ]; then
    rm -f "$PREFIX/mcp-locks"
  else
    sudo rm -f "$PREFIX/mcp-locks"
  fi
  echo "    OK — removed"
else
  echo "    (was not present)"
fi

echo "==> Removing binary $BIN_DIR/mcp-locks (if present)"
rm -f "$BIN_DIR/mcp-locks" && echo "    OK — removed"

if [ "$PURGE" = "1" ]; then
  echo "==> --purge: removing state and registry"
  rm -rf "$STATE_DIR" "$REGISTRY_DIR"
  echo "    OK — removed $STATE_DIR and $REGISTRY_DIR"
else
  echo "==> Preserving state + registry (use --purge to delete)"
  echo "    $STATE_DIR"
  echo "    $REGISTRY_DIR"
fi

echo ""
echo "✅ mcp-locks uninstalled."
