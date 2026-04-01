#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"

PROJECT_ROOT="$ROOT_DIR"
STATE_ROOT_DIR="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"

SELECT_CODEX=0
SELECT_CLAUDE=0
SELECT_CURSOR=0
EXPLICIT_SELECTION=0

usage() {
  cat <<EOF
usage: ./scripts/verify-linux.sh [options]

options:
  --codex                 verify Codex integration
  --claude-code           verify Claude Code integration
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
    --cursor)
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --all)
      SELECT_CODEX=1
      SELECT_CLAUDE=1
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

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
REPO_SKILL="$PROJECT_ROOT/SKILL.md"
REPO_MCP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/mcp-stdio.js"
REPO_MCP_DIR="$PROJECT_ROOT/packages/mcp-server"
REPO_SQLITE="$(lfp_sqlite_path "$STATE_ROOT_DIR")"
REPO_DATA="$(lfp_data_dir "$STATE_ROOT_DIR")"

AGENTS_MARKER_START="<!-- FIGMA PORT MANAGED BLOCK START -->"
AGENTS_MARKER_END="<!-- FIGMA PORT MANAGED BLOCK END -->"
CLAUDE_MARKER_START="<!-- FIGMA PORT CLAUDE BLOCK START -->"
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
  check_contains "$PROJECT_ROOT/AGENTS.md" '$Local Figma Port' "AGENTS.md advertises \$Local Figma Port"
  check_contains "$PROJECT_ROOT/AGENTS.md" "$AGENTS_MARKER_START" "AGENTS.md has managed skill block"
  check_contains "$PROJECT_ROOT/AGENTS.md" "$REPO_SKILL" "AGENTS.md points at repo skill"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  check_contains "$CLAUDE_HOME_DIR/skills/local-figma-port/SKILL.md" "name: local-figma-port" "Claude Code skill installed"
  check_json_server "$PROJECT_ROOT/.mcp.json" "Claude project MCP config points at repo build"
  check_contains "$PROJECT_ROOT/CLAUDE.md" "$CLAUDE_MARKER_START" "CLAUDE.md has managed skill block"
  check_contains "$PROJECT_ROOT/CLAUDE.md" '$Local Figma Port' "CLAUDE.md advertises \$Local Figma Port"
  check_contains "$PROJECT_ROOT/CLAUDE.md" "$REPO_SKILL" "CLAUDE.md points at repo skill"
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  check_json_server "$PROJECT_ROOT/.cursor/mcp.json" "Cursor project MCP config points at repo build"
  check_contains "$PROJECT_ROOT/AGENTS.md" '$Local Figma Port' "Cursor alias is exposed through AGENTS.md"
  check_contains "$PROJECT_ROOT/AGENTS.md" "$AGENTS_MARKER_END" "AGENTS.md managed block is complete"
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[verify-linux] all checks passed"
