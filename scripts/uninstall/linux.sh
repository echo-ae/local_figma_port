#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
PURGE_DATA=0
KEEP_DATA=0
EXPLICIT_DATA_MODE=0

usage() {
  cat <<EOF
usage: ./scripts/uninstall/linux.sh [options]

options:
  --codex                 uninstall from Codex
  --claude-code           uninstall from Claude Code
  --cursor                uninstall from Cursor
  --all                   uninstall from all supported targets
  --targets LIST          uninstall from comma-separated target numbers: 1=Codex, 2=Claude Code, 3=Cursor
  --purge                 remove stable Local Figma Port state data
  --keep-data             keep stable Local Figma Port state data
  --project-root PATH     override repository root
  --state-dir PATH        override Local Figma Port state root
  --codex-home PATH       override Codex home (default: \$CODEX_HOME or ~/.codex)
  --claude-home PATH      override Claude home (default: \$CLAUDE_HOME or ~/.claude)
  --cursor-home PATH      override Cursor home (default: ~/.cursor)
  --help                  show this help
EOF
}

apply_target_token() {
  local token="$1"
  case "$token" in
    1|codex)
      SELECT_CODEX=1
      ;;
    2|claude|claude-code|claude_code)
      SELECT_CLAUDE=1
      ;;
    3|cursor)
      SELECT_CURSOR=1
      ;;
    *)
      echo "[uninstall-linux] unknown target token: $token" >&2
      exit 2
      ;;
  esac
}

apply_targets_csv() {
  local csv="$1"
  local token
  SELECT_CODEX=0
  SELECT_CLAUDE=0
  SELECT_CURSOR=0
  if [[ "$csv" == "all" || "$csv" == "ALL" ]]; then
    SELECT_CODEX=1
    SELECT_CLAUDE=1
    SELECT_CURSOR=1
    EXPLICIT_SELECTION=1
    return
  fi
  IFS=',' read -r -a target_tokens <<< "$csv"
  for token in "${target_tokens[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -z "$token" ]] && continue
    apply_target_token "$token"
  done
  EXPLICIT_SELECTION=1
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
    --targets)
      apply_targets_csv "$2"
      shift 2
      ;;
    --purge)
      PURGE_DATA=1
      KEEP_DATA=0
      EXPLICIT_DATA_MODE=1
      shift
      ;;
    --keep-data)
      KEEP_DATA=1
      PURGE_DATA=0
      EXPLICIT_DATA_MODE=1
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
      echo "[uninstall-linux] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

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

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[uninstall-linux] missing required command: $cmd" >&2
    exit 1
  fi
}

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

AGENTS_MARKER_START="<!-- FIGMA PORT MANAGED BLOCK START -->"
AGENTS_MARKER_END="<!-- FIGMA PORT MANAGED BLOCK END -->"
CLAUDE_MARKER_START="<!-- FIGMA PORT CLAUDE BLOCK START -->"
CLAUDE_MARKER_END="<!-- FIGMA PORT CLAUDE BLOCK END -->"
CODEX_TOML_MARKER_START="# >>> FIGMA PORT MCP START >>>"
CODEX_TOML_MARKER_END="# <<< FIGMA PORT MCP END <<<"

print_target_menu() {
  cat <<EOF

Select targets to uninstall:
  [1] Codex
  [2] Claude Code
  [3] Cursor

Enter numbers separated by commas, or use 'all'. Example: 1,2,3
EOF
}

run_interactive_selection() {
  SELECT_CODEX=1
  SELECT_CLAUDE=1
  SELECT_CURSOR=1

  while true; do
    print_target_menu
    read -r -p "> " choice
    if [[ -z "$choice" ]]; then
      choice="all"
    fi
    apply_targets_csv "$choice"
    if [[ "$SELECT_CODEX" -eq 0 && "$SELECT_CLAUDE" -eq 0 && "$SELECT_CURSOR" -eq 0 ]]; then
      echo "[uninstall-linux] select at least one target." >&2
      continue
    fi
    break
  done
}

resolve_data_mode() {
  if [[ "$EXPLICIT_DATA_MODE" -eq 1 ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    KEEP_DATA=1
    return
  fi

  while true; do
    read -r -p "[uninstall-linux] remove Local Figma Port data at $STATE_ROOT_DIR? [y/N] " choice
    case "$choice" in
      y|Y|yes|YES)
        PURGE_DATA=1
        KEEP_DATA=0
        return
        ;;
      n|N|no|NO|"")
        KEEP_DATA=1
        PURGE_DATA=0
        return
        ;;
      *)
        echo "[uninstall-linux] answer yes or no." >&2
        ;;
    esac
  done
}

if [[ "$EXPLICIT_SELECTION" -eq 0 ]]; then
  if [[ -t 0 ]]; then
    run_interactive_selection
  else
    echo "[uninstall-linux] no target selection provided and stdin is not interactive." >&2
    echo "[uninstall-linux] use --all, --targets, or one of --codex / --claude-code / --cursor." >&2
    exit 2
  fi
fi

resolve_data_mode

require_cmd node

validate_json_file_if_present() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    return
  fi

  if ! node - "$file" <<'NODE'
const fs = require("node:fs");
const [file] = process.argv.slice(2);
const raw = fs.readFileSync(file, "utf8").trim();
if (raw) {
  JSON.parse(raw);
}
NODE
  then
    echo "[uninstall-linux] invalid JSON in $label: $file" >&2
    exit 1
  fi
}

preflight_project_json_configs() {
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
    validate_json_file_if_present "$PROJECT_ROOT/.mcp.json" "Claude project MCP config"
  fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then
    validate_json_file_if_present "$PROJECT_ROOT/.cursor/mcp.json" "Cursor project MCP config"
  fi
}

write_or_remove_with_backup() {
  local file="$1"
  local tmp="$2"
  local has_content=0

  if [[ -f "$tmp" ]] && grep -q '[^[:space:]]' "$tmp"; then
    has_content=1
  fi

  if [[ "$has_content" -eq 1 && -f "$file" ]] && cmp -s "$file" "$tmp"; then
    echo "[uninstall-linux] unchanged: $file"
    rm -f "$tmp"
    return
  fi

  if [[ -e "$file" ]]; then
    mkdir -p "$(dirname "$file")"
    cp "$file" "$file.local-figma-port.$TIMESTAMP.bak"
    echo "[uninstall-linux] backup: $file.local-figma-port.$TIMESTAMP.bak"
  fi

  if [[ "$has_content" -eq 1 ]]; then
    mkdir -p "$(dirname "$file")"
    mv "$tmp" "$file"
    echo "[uninstall-linux] wrote: $file"
  else
    rm -f "$tmp"
    if [[ -e "$file" ]]; then
      rm -f "$file"
      echo "[uninstall-linux] removed: $file"
    else
      echo "[uninstall-linux] unchanged: $file"
    fi
  fi
}

remove_backup_files() {
  local file="$1"
  local backup
  shopt -s nullglob
  for backup in "$file".local-figma-port.*.bak; do
    rm -f "$backup"
    echo "[uninstall-linux] removed backup: $backup"
  done
  shopt -u nullglob
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "[uninstall-linux] unchanged: $path"
    return
  fi
  rm -rf "$path"
  echo "[uninstall-linux] removed: $path"
}

remove_markdown_block() {
  local file="$1"
  local marker_start="$2"
  local marker_end="$3"
  local tmp

  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v start="$marker_start" -v end="$marker_end" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$file" > "$tmp"
  fi
  write_or_remove_with_backup "$file" "$tmp"
  remove_backup_files "$file"
}

remove_codex_toml_block() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v start="$CODEX_TOML_MARKER_START" -v end="$CODEX_TOML_MARKER_END" '
      skip_server && /^\[/ { skip_server = 0 }
      $0 == "[mcp_servers.local-figma-port]" { skip_server = 1; next }
      $0 == "[mcp_servers.design_local]" { skip_server = 1; next }
      $0 == start { skip_marker = 1; next }
      $0 == end { skip_marker = 0; next }
      !skip_marker && !skip_server { print }
    ' "$file" > "$tmp"
  fi
  write_or_remove_with_backup "$file" "$tmp"
  remove_backup_files "$file"
}

remove_json_mcp_server() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  node - "$file" "$tmp" <<'NODE'
const fs = require("node:fs");
const [file, tmp] = process.argv.slice(2);
let data = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, "utf8").trim();
  if (raw) {
    data = JSON.parse(raw);
  }
}
if (!data || typeof data !== "object" || Array.isArray(data)) {
  data = {};
}
if (data.mcpServers && typeof data.mcpServers === "object" && !Array.isArray(data.mcpServers)) {
  delete data.mcpServers["local-figma-port"];
  delete data.mcpServers.design_local;
  if (Object.keys(data.mcpServers).length === 0) {
    delete data.mcpServers;
  }
}
if (Object.keys(data).length === 0) {
  fs.writeFileSync(tmp, "");
} else {
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
}
NODE
  write_or_remove_with_backup "$file" "$tmp"
  remove_backup_files "$file"
}

json_has_local_server() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq '"local-figma-port"' "$file"
}

codex_is_configured() {
  [[ -f "$CODEX_HOME_DIR/config.toml" ]] && grep -Eq '\[mcp_servers\.local-figma-port\]|# >>> FIGMA PORT MCP START >>>' "$CODEX_HOME_DIR/config.toml"
}

cursor_is_configured() {
  json_has_local_server "$PROJECT_ROOT/.cursor/mcp.json"
}

print_summary() {
  echo
  echo "[uninstall-linux] summary"
  [[ "$SELECT_CODEX" -eq 1 ]] && echo "  - Codex"
  [[ "$SELECT_CLAUDE" -eq 1 ]] && echo "  - Claude Code"
  [[ "$SELECT_CURSOR" -eq 1 ]] && echo "  - Cursor"
  echo "  - project root: $PROJECT_ROOT"
  echo "  - state root: $STATE_ROOT_DIR"
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    echo "  - data: purge"
  else
    echo "  - data: keep"
  fi
}

print_summary

preflight_project_json_configs
LOCAL_FIGMA_PORT_STATE_DIR="$STATE_ROOT_DIR" "$PROJECT_ROOT/scripts/runtime/stop.sh" || true

KEEP_AGENTS=0
if [[ "$SELECT_CODEX" -eq 0 ]] && codex_is_configured; then
  KEEP_AGENTS=1
fi
if [[ "$SELECT_CURSOR" -eq 0 ]] && cursor_is_configured; then
  KEEP_AGENTS=1
fi

if [[ "$SELECT_CODEX" -eq 1 ]]; then
  remove_codex_toml_block "$CODEX_HOME_DIR/config.toml"
  remove_path "$CODEX_HOME_DIR/skills/local-figma-port"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  remove_json_mcp_server "$PROJECT_ROOT/.mcp.json"
  remove_markdown_block "$PROJECT_ROOT/CLAUDE.md" "$CLAUDE_MARKER_START" "$CLAUDE_MARKER_END"
  remove_path "$CLAUDE_HOME_DIR/skills/local-figma-port"
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  remove_json_mcp_server "$PROJECT_ROOT/.cursor/mcp.json"
fi

if [[ "$KEEP_AGENTS" -eq 0 && ( "$SELECT_CODEX" -eq 1 || "$SELECT_CURSOR" -eq 1 ) ]]; then
  remove_markdown_block "$PROJECT_ROOT/AGENTS.md" "$AGENTS_MARKER_START" "$AGENTS_MARKER_END"
fi

if [[ "$PURGE_DATA" -eq 1 ]]; then
  remove_path "$STATE_ROOT_DIR"
fi

echo "[uninstall-linux] uninstall complete"
