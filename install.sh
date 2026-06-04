#!/usr/bin/env bash
# mcp-locks installer. Idempotent — safe to re-run.
#
# Env vars:
#   MCP_LOCKS_BIN_DIR — where to install the binary (default: ~/bin)
#   MCP_LOCKS_PREFIX  — where to symlink for PATH (default: /usr/local/bin)
#   MCP_LOCKS_NO_LAUNCHAGENT=1 — skip the LaunchAgent install (Linux, or you
#                                want to run reap via cron instead)
#   MCP_LOCKS_NO_SYMLINK=1     — skip the sudo symlink step (rely on PATH
#                                already including MCP_LOCKS_BIN_DIR)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="mcp-locks"

BIN_DIR="${MCP_LOCKS_BIN_DIR:-$HOME/bin}"
PREFIX="${MCP_LOCKS_PREFIX:-/usr/local/bin}"
STATE_DIR="${MCP_LOCKS_STATE_DIR:-$HOME/.local/state/mcp-locks}"

# Detect platform
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *)      PLATFORM=other ;;
esac

echo "==> mcp-locks installer (platform: $PLATFORM)"
echo "    bin dir:   $BIN_DIR"
echo "    prefix:    $PREFIX"
echo "    state dir: $STATE_DIR"
echo ""

# ---- 1. Pre-flight ----

echo "==> 1. Pre-flight"
for cmd in jq bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "    MISSING: $cmd not in PATH. Install it first." >&2
    if [ "$PLATFORM" = macos ]; then
      echo "    macOS:   brew install $cmd" >&2
    fi
    exit 1
  fi
done
echo "    OK — jq, bash present"

# ---- 2. Install binary ----

echo "==> 2. Install binary to $BIN_DIR/$SCRIPT_NAME"
mkdir -p "$BIN_DIR"
install -m 755 "$REPO_DIR/bin/$SCRIPT_NAME" "$BIN_DIR/$SCRIPT_NAME"
echo "    OK — $(ls -la "$BIN_DIR/$SCRIPT_NAME" | awk '{print $1, $9}')"

# ---- 3. Smoke test ----

echo "==> 3. Smoke test"
"$BIN_DIR/$SCRIPT_NAME" doctor >/dev/null
echo "    OK — \`$SCRIPT_NAME doctor\` runs clean"

# ---- 4. Symlink for PATH ----

if [ "${MCP_LOCKS_NO_SYMLINK:-0}" = "1" ]; then
  echo "==> 4. Symlink skipped (MCP_LOCKS_NO_SYMLINK=1)"
  echo "    Make sure $BIN_DIR is on your PATH."
else
  echo "==> 4. Symlink to $PREFIX/$SCRIPT_NAME (may prompt for sudo)"
  if [ -L "$PREFIX/$SCRIPT_NAME" ] && [ "$(readlink "$PREFIX/$SCRIPT_NAME")" = "$BIN_DIR/$SCRIPT_NAME" ]; then
    echo "    OK — symlink already correct"
  else
    if [ -w "$PREFIX" ]; then
      ln -sf "$BIN_DIR/$SCRIPT_NAME" "$PREFIX/$SCRIPT_NAME"
    else
      sudo ln -sf "$BIN_DIR/$SCRIPT_NAME" "$PREFIX/$SCRIPT_NAME"
    fi
    echo "    OK — $(ls -la "$PREFIX/$SCRIPT_NAME" | awk '{print $1, $9, $10, $11}')"
  fi
fi

# ---- 5. LaunchAgent (macOS only) ----

if [ "${MCP_LOCKS_NO_LAUNCHAGENT:-0}" = "1" ]; then
  echo "==> 5-7. LaunchAgent install skipped (MCP_LOCKS_NO_LAUNCHAGENT=1)"
  echo "    Schedule \`$SCRIPT_NAME reap\` yourself (cron, systemd timer, etc.)"
elif [ "$PLATFORM" != macos ]; then
  echo "==> 5-7. LaunchAgent install skipped (not macOS)"
  echo "    Schedule \`$SCRIPT_NAME reap\` via cron or systemd timer."
else
  PLIST_TEMPLATE="$REPO_DIR/share/launchagent.template.plist"
  PLIST_LABEL="com.${USER}.mcp-locks-reap"
  PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  echo "==> 5. Render LaunchAgent plist → $PLIST_DST"
  if [ ! -f "$PLIST_TEMPLATE" ]; then
    echo "    MISSING: $PLIST_TEMPLATE" >&2
    exit 1
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"
  sed \
    -e "s|@@USER@@|${USER}|g" \
    -e "s|@@MCP_LOCKS_BIN@@|${BIN_DIR}/${SCRIPT_NAME}|g" \
    -e "s|@@STATE_DIR@@|${STATE_DIR}|g" \
    -e "s|@@HOME@@|${HOME}|g" \
    "$PLIST_TEMPLATE" > "$PLIST_DST"
  plutil -lint "$PLIST_DST" >/dev/null
  echo "    OK — plist installed and valid"

  echo "==> 6. Load LaunchAgent (idempotent)"
  launchctl bootout "gui/$UID/${PLIST_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST_DST"
  if launchctl print "gui/$UID/${PLIST_LABEL}" >/dev/null 2>&1; then
    echo "    OK — bootstrapped"
  else
    echo "    FAIL — agent did not load" >&2
    exit 1
  fi

  echo "==> 7. Kickstart to verify the reaper actually runs"
  launchctl kickstart -k "gui/$UID/${PLIST_LABEL}"
  sleep 2
  if [ -f "$STATE_DIR/reap.log" ]; then
    echo "    OK — reap log tail:"
    tail -3 "$STATE_DIR/reap.log" | sed 's/^/      /'
  else
    echo "    FAIL — no reap.log; check $STATE_DIR/launchd.err.log" >&2
    [ -f "$STATE_DIR/launchd.err.log" ] && head -20 "$STATE_DIR/launchd.err.log" >&2
    exit 1
  fi
fi

echo ""
echo "✅ mcp-locks installed."
echo ""
echo "   Try:      mcp-locks list"
echo "             mcp-locks doctor"
[ "$PLATFORM" = macos ] && [ "${MCP_LOCKS_NO_LAUNCHAGENT:-0}" != "1" ] && \
  echo "   Schedule: 09:00 and 14:00 daily (\`launchctl print gui/$UID/com.${USER}.mcp-locks-reap\`)"
echo "   Registry: ~/.config/mcp-locks/registry.json (edit to add/remove lockable instances)"
echo "   State:    $STATE_DIR/state.json"
echo "   Logs:     $STATE_DIR/reap.log"
echo ""
echo "   See README.md for the agent-prompt contract."
