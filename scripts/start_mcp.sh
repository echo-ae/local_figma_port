#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"

STATE_ROOT="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
DATA_DIR="${DATA_DIR:-$(lfp_data_dir "$STATE_ROOT")}"
MCP_DIR="$ROOT_DIR/packages/mcp-server"
MCP_PORT="${MCP_PORT:-7331}"
SQLITE_PATH="${SQLITE_PATH:-$DATA_DIR/design_store.sqlite}"
PID_FILE="${PID_FILE:-$(lfp_pid_file "$STATE_ROOT")}"
LOG_FILE="${LOG_FILE:-$(lfp_log_file "$STATE_ROOT")}"

mkdir -p "$DATA_DIR" "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"

if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" || true)"
  if [[ -n "${OLD_PID}" ]] && kill -0 "$OLD_PID" >/dev/null 2>&1; then
    echo "[start] MCP already running pid=$OLD_PID"
    exit 0
  fi
fi

if command -v lsof >/dev/null 2>&1; then
  PIDS_ON_PORT="$(lsof -ti tcp:"$MCP_PORT" -sTCP:LISTEN || true)"
  if [[ -n "$PIDS_ON_PORT" ]]; then
    echo "[start] port $MCP_PORT is busy; stop existing process first (./scripts/stop_mcp.sh)"
    exit 1
  fi
fi

(
  cd "$MCP_DIR"
  npm run build >/dev/null
)

nohup env \
  PROJECT_ROOT="$ROOT_DIR" \
  SQLITE_PATH="$SQLITE_PATH" \
  DATA_DIR="$DATA_DIR" \
  MCP_PORT="$MCP_PORT" \
  node "$MCP_DIR/dist/index.js" >> "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
NEW_PID="$(cat "$PID_FILE")"
sleep 1
if ! kill -0 "$NEW_PID" >/dev/null 2>&1; then
  rm -f "$PID_FILE"
  echo "[start] MCP failed to stay running on port $MCP_PORT" >&2
  if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
    echo "[start] recent log output:" >&2
    tail -n 20 "$LOG_FILE" >&2
  fi
  exit 1
fi
echo "[start] MCP started pid=$NEW_PID port=$MCP_PORT"
echo "[start] log: $LOG_FILE"
