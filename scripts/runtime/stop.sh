#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"

STATE_ROOT="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
PID_FILE="${PID_FILE:-$(lfp_pid_file "$STATE_ROOT")}"
MCP_PORT="${MCP_PORT:-7331}"

stopped=0
PORT_BUSY_PIDS=""

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" || true
    sleep 1
    if kill -0 "$PID" >/dev/null 2>&1; then
      kill -9 "$PID" || true
    fi
    echo "[stop] stopped MCP pid=$PID"
    stopped=1
  fi
  rm -f "$PID_FILE"
fi

if command -v lsof >/dev/null 2>&1; then
  PORT_BUSY_PIDS="$(lsof -ti tcp:"$MCP_PORT" -sTCP:LISTEN || true)"
fi

if [[ "$stopped" -eq 0 ]]; then
  echo "[stop] no running managed MCP process found"
fi

if [[ -n "$PORT_BUSY_PIDS" ]]; then
  echo "[stop] port $MCP_PORT is still in use by non-managed process(es): $PORT_BUSY_PIDS" >&2
fi
