#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"

STATE_ROOT="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
DATA_DIR="${DATA_DIR:-$(lfp_data_dir "$STATE_ROOT")}"
MCP_DIR="$ROOT_DIR/packages/mcp-server"
MCP_PORT="${MCP_PORT:-7331}"
SQLITE3_BIN="${SQLITE3_BIN:-sqlite3}"
SQLITE_PATH="${SQLITE_PATH:-$DATA_DIR/design_store.sqlite}"
PID_FILE="${PID_FILE:-$(lfp_pid_file "$STATE_ROOT")}"
LOG_FILE="${LOG_FILE:-$(lfp_log_file "$STATE_ROOT")}"
NODE_SCRIPT="$MCP_DIR/dist/index.js"
MCP_PACKAGE_JSON="$MCP_DIR/package.json"
DDL_PATH="$ROOT_DIR/sql/design_store.v1.sql"
COMPAT_DDL_PATH="$ROOT_DIR/sql/design_store.v1.compat.sql"
IMPORTER_EXE="${IMPORTER_EXE:-$ROOT_DIR/packages/design-importer/target/release/design-importer}"

sqlite_statement() {
  local database_path="$1"
  local statement="$2"
  local output

  if ! output="$("$SQLITE3_BIN" "$database_path" "$statement" 2>&1)"; then
    printf '%s\n' "$output"
    return 1
  fi

  printf '%s\n' "$output" | tr -d '\r'
}

ensure_database_schema() {
  local has_fts_nodes=""
  local ddl=""
  local compat_ddl=""
  local init_output=""

  if [[ ! -f "$DDL_PATH" ]]; then
    echo "[start] missing DDL file: $DDL_PATH" >&2
    exit 1
  fi
  if [[ ! -f "$COMPAT_DDL_PATH" ]]; then
    echo "[start] missing compatibility DDL file: $COMPAT_DDL_PATH" >&2
    exit 1
  fi

  has_fts_nodes="$(sqlite_statement "$SQLITE_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_nodes' LIMIT 1;" || true)"
  if [[ "$has_fts_nodes" == "1" ]]; then
    return
  fi

  ddl="$(cat "$DDL_PATH")"
  if ! init_output="$(sqlite_statement "$SQLITE_PATH" "$ddl" 2>&1)"; then
    if [[ "$init_output" != *"expressions prohibited in PRIMARY KEY"* ]]; then
      echo "[start] failed to initialize SQLite schema: $init_output" >&2
      exit 1
    fi

    compat_ddl="$(cat "$COMPAT_DDL_PATH")"
    if ! init_output="$(sqlite_statement "$SQLITE_PATH" "$compat_ddl" 2>&1)"; then
      echo "[start] failed to initialize compatibility SQLite schema: $init_output" >&2
      exit 1
    fi
  fi

  has_fts_nodes="$(sqlite_statement "$SQLITE_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_nodes' LIMIT 1;" || true)"
  if [[ "$has_fts_nodes" != "1" ]]; then
    echo "[start] SQLite schema initialization did not create fts_nodes in $SQLITE_PATH" >&2
    exit 1
  fi

  echo "[start] initialized SQLite schema at $SQLITE_PATH"
}

ensure_mcp_entry_point() {
  if [[ -f "$NODE_SCRIPT" ]]; then
    if [[ ! -f "$MCP_PACKAGE_JSON" ]]; then
      echo "[start] missing MCP package metadata: $MCP_PACKAGE_JSON. Run scripts/install/macos.sh or scripts/install/linux.sh first." >&2
      exit 1
    fi
    return
  fi

  if [[ ! -f "$MCP_PACKAGE_JSON" ]]; then
    echo "[start] missing MCP package metadata and prebuilt entrypoint at $MCP_PACKAGE_JSON / $NODE_SCRIPT" >&2
    exit 1
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "[start] missing required command: npm" >&2
    exit 1
  fi

  (
    cd "$MCP_DIR"
    npm run build >/dev/null
  )

  if [[ ! -f "$NODE_SCRIPT" ]]; then
    echo "[start] MCP build did not produce $NODE_SCRIPT" >&2
    exit 1
  fi
}

mkdir -p "$DATA_DIR" "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"
ensure_database_schema
ensure_mcp_entry_point

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
    echo "[start] port $MCP_PORT is busy; stop existing process first (./scripts/runtime/stop.sh)"
    exit 1
  fi
fi

ENV_VARS=(
  env
  "PROJECT_ROOT=$ROOT_DIR"
  "SQLITE3_BIN=$SQLITE3_BIN"
  "SQLITE_PATH=$SQLITE_PATH"
  "DATA_DIR=$DATA_DIR"
  "MCP_PORT=$MCP_PORT"
)

if [[ -f "$IMPORTER_EXE" ]]; then
  chmod +x "$IMPORTER_EXE" >/dev/null 2>&1 || true
  ENV_VARS+=("IMPORTER_EXE=$IMPORTER_EXE")
fi

nohup "${ENV_VARS[@]}" node "$NODE_SCRIPT" >> "$LOG_FILE" 2>&1 &

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
echo "[start] sqlite3: $SQLITE3_BIN"
if [[ -f "$IMPORTER_EXE" ]]; then
  echo "[start] importer: $IMPORTER_EXE"
fi
echo "[start] log: $LOG_FILE"
