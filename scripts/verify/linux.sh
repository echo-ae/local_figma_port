#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"
source "$ROOT_DIR/scripts/lib/claude_desktop_extension.sh"

PROJECT_ROOT="$ROOT_DIR"
STATE_ROOT_DIR="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"
CLAUDE_CLI_PATH=""

SELECT_CODEX=0
SELECT_CLAUDE=0
SELECT_CLAUDE_DESKTOP=0
SELECT_CURSOR=0
EXPLICIT_SELECTION=0

usage() {
  cat <<EOF
usage: ./scripts/verify/linux.sh [options]

options:
  --codex                 verify Codex integration
  --claude-code           verify Claude Code integration
  --claude-desktop        verify Claude Desktop integration
  --cursor                verify Cursor integration
  --all                   verify all supported targets
  --project-root PATH     override repository root
  --state-dir PATH        override Local Figma Port state root
  --codex-home PATH       override Codex home
  --claude-home PATH      override Claude home
  --cursor-home PATH      override Cursor home
  --help                  show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex)
      SELECT_CODEX=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --claude-code)
      SELECT_CLAUDE=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --claude-desktop)
      SELECT_CLAUDE_DESKTOP=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --cursor)
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --all)
      SELECT_CODEX=1
      SELECT_CLAUDE=1
      SELECT_CLAUDE_DESKTOP=1
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --state-dir)
      STATE_ROOT_DIR="$2"
      shift 2
      ;;
    --codex-home)
      CODEX_HOME_DIR="$2"
      shift 2
      ;;
    --claude-home)
      CLAUDE_HOME_DIR="$2"
      shift 2
      ;;
    --cursor-home)
      CURSOR_HOME_DIR="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "[verify-linux] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$EXPLICIT_SELECTION" -eq 0 ]]; then
  SELECT_CODEX=1
  SELECT_CLAUDE=1
  SELECT_CLAUDE_DESKTOP=0
  SELECT_CURSOR=1
fi

normalize_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
    return
  fi
  if [[ "$path" == ~/* ]]; then
    printf '%s\n' "$HOME/${path#~/}"
    return
  fi
  printf '%s\n' "$path"
}

resolve_claude_cli() {
  if [[ -n "$CLAUDE_CLI_PATH" && -x "$CLAUDE_CLI_PATH" ]]; then
    return
  fi
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CLI_PATH="$(command -v claude)"
    return
  fi

  local candidate
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/claude" \
    "/usr/local/bin/claude" \
    "/usr/bin/claude"
  do
    if [[ -x "$candidate" ]]; then
      CLAUDE_CLI_PATH="$candidate"
      return
    fi
  done

  fail "Claude Code CLI is installed (missing command: claude)"
}

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
REPO_SKILL="$PROJECT_ROOT/SKILL.md"
REPO_MCP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/mcp-stdio.js"
REPO_MCP_DIR="$PROJECT_ROOT/packages/mcp-server"
REPO_SQLITE="$(lfp_sqlite_path "$STATE_ROOT_DIR")"
REPO_DATA="$(lfp_data_dir "$STATE_ROOT_DIR")"
CLAUDE_DESKTOP_BUNDLE_PATH="$(lfp_claude_desktop_bundle_path "$STATE_ROOT_DIR")"

CODEX_TOML_MARKER_START="# >>> FIGMA PORT MCP START >>>"

failures=0

ok() {
  echo "[verify-linux] ok: $1"
}

fail() {
  echo "[verify-linux] fail: $1" >&2
  failures=$((failures + 1))
}

check_sqlite_fts5() {
  local label="$1"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    fail "$label (missing command: sqlite3)"
    return
  fi
  if sqlite3 :memory: "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

check_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    fail "$label (missing file: $file)"
    return
  fi
  if grep -Fq "$needle" "$file"; then
    ok "$label"
  else
    fail "$label"
  fi
}

check_json_server() {
  local file="$1"
  local label="$2"
  if [[ ! -f "$file" ]]; then
    fail "$label (missing file: $file)"
    return
  fi
  if node - "$file" "$REPO_MCP_ENTRY" "$REPO_SQLITE" "$REPO_DATA" <<'NODE'
const fs = require("node:fs");
const [file, entry, sqlite, dataDir] = process.argv.slice(2);
const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
const server = parsed?.mcpServers?.["local-figma-port"];
if (!server) process.exit(1);
if (server.command !== "node") process.exit(1);
if (!Array.isArray(server.args) || server.args[0] !== entry) process.exit(1);
if (!server.env || server.env.SQLITE_PATH !== sqlite || server.env.DATA_DIR !== dataDir) process.exit(1);
NODE
  then
    ok "$label"
  else
    fail "$label"
  fi
}

check_claude_desktop_bundle() {
  local bundle_path="$1"
  local label="$2"
  local manifest_json=""
  local sqlite_bin=""
  local server_entry=""
  local schema_json=""

  sqlite_bin="$(command -v sqlite3)"
  if [[ ! -f "$bundle_path" ]]; then
    fail "$label (missing file: $bundle_path)"
    return
  fi

  manifest_json="$(lfp_cdext_read_file "$bundle_path" "manifest.json" 2>/dev/null || true)"
  server_entry="$(lfp_cdext_read_file "$bundle_path" "server/mcp-stdio.js" 2>/dev/null || true)"
  schema_json="$(lfp_cdext_read_file "$bundle_path" "schemas/mcp-tools.v1.schema.json" 2>/dev/null || true)"
  if [[ -z "$manifest_json" ]]; then
    fail "$label (missing manifest.json)"
    return
  fi
  if [[ -z "$server_entry" ]]; then
    fail "$label (missing server/mcp-stdio.js)"
    return
  fi
  if [[ -z "$schema_json" ]]; then
    fail "$label (missing schemas/mcp-tools.v1.schema.json)"
    return
  fi

  if MANIFEST_JSON="$manifest_json" node - "$sqlite_bin" "$REPO_SQLITE" "$REPO_DATA" <<'NODE'
const [sqliteBin, sqlitePath, dataDir] = process.argv.slice(2);
const manifest = JSON.parse(process.env.MANIFEST_JSON || "");
if (!manifest) process.exit(1);
{
  const server = manifest?.server;
  if (!server || server.type !== "node" || server.entry_point !== "server/mcp-stdio.js") process.exit(1);
  const cfg = server.mcp_config;
  if (!cfg || cfg.command !== "node") process.exit(1);
  if (!Array.isArray(cfg.args) || cfg.args[0] !== "${__dirname}/server/mcp-stdio.js") process.exit(1);
  if (!cfg.env || cfg.env.SQLITE3_BIN !== sqliteBin || cfg.env.SQLITE_PATH !== sqlitePath || cfg.env.DATA_DIR !== dataDir) process.exit(1);
}
NODE
  then
    ok "$label"
  else
    fail "$label"
  fi
}

verify_codex_shared_config() {
  local label_prefix="$1"
  check_contains "$CODEX_HOME_DIR/skills/local-figma-port/SKILL.md" "name: local-figma-port" "$label_prefix skill installed"
  check_contains "$CODEX_HOME_DIR/config.toml" "$CODEX_TOML_MARKER_START" "$label_prefix config has managed block"
  check_contains "$CODEX_HOME_DIR/config.toml" "$REPO_MCP_ENTRY" "$label_prefix config points at repo MCP build"
  check_contains "$CODEX_HOME_DIR/config.toml" "$REPO_SQLITE" "$label_prefix config points at stable sqlite path"
  check_contains "$CODEX_HOME_DIR/config.toml" "$REPO_DATA" "$label_prefix config points at stable data dir"
  if grep -Fq "[mcp_servers.design_local]" "$CODEX_HOME_DIR/config.toml"; then
    fail "$label_prefix config removed legacy design_local block"
  else
    ok "$label_prefix config removed legacy design_local block"
  fi
}

if [[ ! -f "$REPO_SKILL" ]]; then
  fail "repo skill exists ($REPO_SKILL)"
fi
if [[ ! -f "$REPO_MCP_ENTRY" ]]; then
  fail "built MCP entry exists ($REPO_MCP_ENTRY)"
fi
if [[ ! -d "$REPO_DATA" ]]; then
  fail "stable data dir exists ($REPO_DATA)"
fi
if [[ ! -d "$REPO_MCP_DIR/node_modules" ]]; then
  fail "MCP runtime dependencies exist ($REPO_MCP_DIR/node_modules)"
fi
check_sqlite_fts5 "system sqlite3 supports FTS5"

if [[ "$SELECT_CODEX" -eq 1 ]]; then
  verify_codex_shared_config "Codex"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  check_contains "$CLAUDE_HOME_DIR/skills/local-figma-port/SKILL.md" "name: local-figma-port" "Claude Code skill installed"
  check_contains "$CLAUDE_HOME_DIR/agents/local-figma-port.md" "name: local-figma-port" "Claude Code subagent file installed"
  ok "Claude Code subagent is registered"
  resolve_claude_cli
  if [[ -n "$CLAUDE_CLI_PATH" ]]; then
    claude_mcp_output="$("$CLAUDE_CLI_PATH" mcp get local-figma-port --scope user 2>/dev/null || true)"
    if [[ -n "$claude_mcp_output" ]] &&
       grep -Fq "$REPO_MCP_ENTRY" <<<"$claude_mcp_output" &&
       grep -Fq "$REPO_SQLITE" <<<"$claude_mcp_output" &&
       grep -Fq "$REPO_DATA" <<<"$claude_mcp_output"; then
      ok "Claude Code user MCP config points at repo build"
    else
      fail "Claude Code user MCP config points at repo build"
    fi
  fi
fi

if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then
  check_claude_desktop_bundle "$CLAUDE_DESKTOP_BUNDLE_PATH" "Claude Desktop extension bundle points at repo build"
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  check_json_server "$CURSOR_HOME_DIR/mcp.json" "Cursor global MCP config points at repo build"
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[verify-linux] all checks passed"
