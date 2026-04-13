#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"
source "$ROOT_DIR/scripts/lib/claude_desktop_extension.sh"

PROJECT_ROOT="$ROOT_DIR"
STATE_ROOT_DIR="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_APP_DATA_DIR="${CODEX_APP_DATA_DIR:-$HOME/Library/Application Support/Codex}"
CODEX_APP_BUNDLE="${CODEX_APP_BUNDLE:-/Applications/Codex.app}"
CLAUDE_HOME_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"
NODE_RUNTIME_PATH=""
NODE_RUNTIME_VERSION=""
CLAUDE_CLI_PATH=""
CLAUDE_DESKTOP_BUNDLE_OPEN_STATUS="not-attempted"

SELECT_CODEX=0
SELECT_CODEX_APP=0
SELECT_CLAUDE=0
SELECT_CLAUDE_DESKTOP=0
SELECT_CURSOR=0
EXPLICIT_SELECTION=0
USE_PREBUILT=0
CONFIG_ROOT=""

usage() {
  cat <<EOF
usage: ./scripts/install/macos.sh [options]

options:
  --codex                 install for Codex
  --codex-app             install for Codex App
  --claude-code           install for Claude Code
  --claude-desktop        install for Claude Desktop
  --cursor                install for Cursor
  --all                   install for all supported targets
  --use-prebuilt          install from a prebuilt runtime bundle without local Rust/TypeScript builds
  --targets LIST          install for comma-separated target numbers: 1=Codex, 2=Codex App, 3=Claude Code, 4=Claude Desktop, 5=Cursor
  --project-root PATH     override repository root
  --config-root PATH      override workspace root for legacy project files that may need cleanup
  --state-dir PATH        override Local Figma Port state root
  --codex-home PATH       override Codex home (default: \$CODEX_HOME or ~/.codex)
  --codex-app-data PATH   override Codex App data dir (default: ~/Library/Application Support/Codex)
  --codex-app-bundle PATH override Codex App bundle path (default: /Applications/Codex.app)
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
    2|codex-app|codex_app)
      SELECT_CODEX_APP=1
      ;;
    3|claude|claude-code|claude_code)
      SELECT_CLAUDE=1
      ;;
    4|claude-desktop|claude_desktop|claude-desktop-app)
      SELECT_CLAUDE_DESKTOP=1
      ;;
    5|cursor)
      SELECT_CURSOR=1
      ;;
    *)
      echo "[install-mac] unknown target token: $token" >&2
      exit 2
      ;;
  esac
}

apply_targets_csv() {
  local csv="$1"
  local token
  SELECT_CODEX=0
  SELECT_CODEX_APP=0
  SELECT_CLAUDE=0
  SELECT_CLAUDE_DESKTOP=0
  SELECT_CURSOR=0
  if [[ "$csv" == "all" || "$csv" == "ALL" ]]; then
    SELECT_CODEX=1
    SELECT_CODEX_APP=1
    SELECT_CLAUDE=1
    SELECT_CLAUDE_DESKTOP=1
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
    --codex-app)
      SELECT_CODEX_APP=1
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
      SELECT_CODEX_APP=1
      SELECT_CLAUDE=1
      SELECT_CLAUDE_DESKTOP=1
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --use-prebuilt)
      USE_PREBUILT=1
      shift
      ;;
    --targets)
      apply_targets_csv "$2"
      shift 2
      ;;
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --config-root)
      CONFIG_ROOT="$2"
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
    --codex-app-data)
      CODEX_APP_DATA_DIR="$2"
      shift 2
      ;;
    --codex-app-bundle)
      CODEX_APP_BUNDLE="$2"
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
      echo "[install-mac] unknown option: $1" >&2
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
    echo "[install-mac] missing required command: $cmd" >&2
    exit 1
  fi
}

detect_node_runtime() {
  require_cmd node
  NODE_RUNTIME_PATH="$(command -v node)"
  NODE_RUNTIME_VERSION="$("$NODE_RUNTIME_PATH" --version 2>/dev/null || true)"
  if [[ -z "$NODE_RUNTIME_VERSION" ]]; then
    NODE_RUNTIME_VERSION="unknown"
  fi
}

resolve_claude_cli() {
  if [[ -n "$CLAUDE_CLI_PATH" && -x "$CLAUDE_CLI_PATH" ]]; then
    return
  fi

  local candidates=()
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CLI_PATH="$(command -v claude)"
    return
  fi

  candidates=(
    "$HOME/.local/bin/claude"
    "$HOME/.claude/local/claude"
    "/opt/homebrew/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      CLAUDE_CLI_PATH="$candidate"
      return
    fi
  done

  echo "[install-mac] Claude Code CLI not found." >&2
  echo "[install-mac] install Claude Code so the \`claude\` command is available, then re-run the installer." >&2
  exit 1
}

ensure_sqlite_fts5() {
  require_cmd sqlite3
  REPO_SQLITE3_BIN="$(command -v sqlite3)"
  if ! sqlite3 :memory: "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" >/dev/null 2>&1; then
    echo "[install-mac] sqlite3 is present, but this build does not support FTS5." >&2
    echo "[install-mac] install a sqlite3 build with FTS5 enabled and re-run the installer." >&2
    exit 1
  fi
}

validate_skill_frontmatter() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "[install-mac] missing skill file: $file" >&2
    exit 1
  fi
  if ! head -n 1 "$file" | grep -Fxq -- "---"; then
    echo "[install-mac] skill file is missing opening YAML frontmatter delimiter: $file" >&2
    exit 1
  fi
}

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
if [[ -z "$CONFIG_ROOT" ]]; then
  CONFIG_ROOT="$PROJECT_ROOT"
else
  CONFIG_ROOT="$(normalize_path "$CONFIG_ROOT")"
  mkdir -p "$CONFIG_ROOT"
  CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd)"
fi
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
REPO_SKILL="$PROJECT_ROOT/SKILL.md"
REPO_MCP_DIR="$PROJECT_ROOT/packages/mcp-server"
REPO_MCP_PACKAGE="$REPO_MCP_DIR/package.json"
REPO_CLAUDE_DESKTOP_PAYLOAD_DIR="$REPO_MCP_DIR/claude-desktop-extension-payload"
REPO_MCP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/mcp-stdio.js"
REPO_MCP_HTTP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/index.js"
PROJECT_DATA_DIR="$PROJECT_ROOT/data"
REPO_IMPORTER_EXE="$PROJECT_ROOT/packages/design-importer/target/release/design-importer"
REPO_PLUGIN_DIR="$PROJECT_ROOT/packages/figma-exporter-plugin"
REPO_PLUGIN_ENTRY="$REPO_PLUGIN_DIR/dist/main.js"
REPO_PLUGIN_MANIFEST="$REPO_PLUGIN_DIR/manifest.json"
REPO_PLUGIN_PACKAGE="$REPO_PLUGIN_DIR/package.json"
REPO_DATA="$(lfp_data_dir "$STATE_ROOT_DIR")"
REPO_SQLITE="$(lfp_sqlite_path "$STATE_ROOT_DIR")"
CLAUDE_DESKTOP_BUNDLE_PATH="$(lfp_claude_desktop_bundle_path "$STATE_ROOT_DIR")"
RUN_DIR="$(lfp_run_dir "$STATE_ROOT_DIR")"
LOG_DIR="$(lfp_log_dir "$STATE_ROOT_DIR")"
REPO_SKILL_POSIX="$REPO_SKILL"
REPO_MCP_ENTRY_POSIX="$REPO_MCP_ENTRY"
REPO_SQLITE_POSIX="$REPO_SQLITE"
REPO_DATA_POSIX="$REPO_DATA"
REPO_SQLITE3_BIN=""
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

CODEX_TOML_MARKER_START="# >>> FIGMA PORT MCP START >>>"
CODEX_TOML_MARKER_END="# <<< FIGMA PORT MCP END <<<"

if [[ ! -f "$REPO_SKILL" ]]; then
  echo "[install-mac] missing repo skill: $REPO_SKILL" >&2
  exit 1
fi
validate_skill_frontmatter "$REPO_SKILL"

if [[ ! -f "$REPO_MCP_PACKAGE" ]]; then
  echo "[install-mac] missing MCP package: $REPO_MCP_PACKAGE" >&2
  exit 1
fi

print_target_menu() {
  cat <<EOF

Select targets to configure by number:
  [1] Codex
  [2] Codex App
  [3] Claude Code
  [4] Claude Desktop
  [5] Cursor

Enter numbers separated by commas (example: 1,2,5) or 'all'. Press Enter for all targets.
EOF
}

run_interactive_selection() {
  SELECT_CODEX=1
  SELECT_CODEX_APP=1
  SELECT_CLAUDE=1
  SELECT_CLAUDE_DESKTOP=1
  SELECT_CURSOR=1

  while true; do
    print_target_menu
    read -r -p "> " choice
    case "$choice" in
      "")
        break
        ;;
      *)
        apply_targets_csv "$choice"
        if [[ "$SELECT_CODEX" -eq 0 && "$SELECT_CODEX_APP" -eq 0 && "$SELECT_CLAUDE" -eq 0 && "$SELECT_CLAUDE_DESKTOP" -eq 0 && "$SELECT_CURSOR" -eq 0 ]]; then
          echo "[install-mac] select at least one target." >&2
          continue
        fi
        break
        ;;
    esac
  done
}

if [[ "$EXPLICIT_SELECTION" -eq 0 ]]; then
  if [[ -t 0 ]]; then
    run_interactive_selection
  else
    echo "[install-mac] no target selection provided and stdin is not interactive." >&2
    echo "[install-mac] use --all, --targets, or one of --codex / --codex-app / --claude-code / --claude-desktop / --cursor." >&2
    exit 2
  fi
fi

ensure_codex_app_installed() {
  if [[ "$SELECT_CODEX_APP" -ne 1 ]]; then
    return
  fi
  if [[ ! -d "$CODEX_APP_DATA_DIR" && ! -d "$CODEX_APP_BUNDLE" ]]; then
    echo "[install-mac] Codex App target selected, but no app data dir or bundle was found." >&2
    echo "[install-mac] looked for: $CODEX_APP_DATA_DIR and $CODEX_APP_BUNDLE" >&2
    exit 1
  fi
}

restart_codex_app_if_needed() {
  if [[ "$SELECT_CODEX_APP" -ne 1 ]]; then
    return
  fi

  echo "[install-mac] note: restart Codex App manually after reviewing the Figma plugin instructions so the MCP server appears in Settings."
}

show_figma_plugin_manifest_instructions() {
  if [[ ! -f "$REPO_PLUGIN_MANIFEST" ]]; then
    return
  fi

  local border="=============================================================================="
  echo
  echo "$border"
  echo "  Figma Desktop plugin manifest"
  echo "$border"
  echo "  Import this file in Figma Desktop:"
  echo
  echo "  $REPO_PLUGIN_MANIFEST"
  echo
  echo "  Figma: Plugins -> Development -> Import plugin from manifest..."
  echo "$border"
  echo
}

print_agent_mcp_diagnostic() {
  local agent_label="$1"
  local config_path="$2"

  echo "[install-mac] MCP diagnostics for $agent_label"
  echo "  - config: $config_path"
  echo "  - command: node"
  echo "  - node detected: $NODE_RUNTIME_PATH"
  echo "  - node version: $NODE_RUNTIME_VERSION"
  echo "  - server entry: $REPO_MCP_ENTRY"
}

print_claude_desktop_extension_diagnostic() {
  local border="=============================================================================="

  echo
  echo "$border"
  echo "  Claude Desktop extension"
  echo "$border"
  echo "  Bundle:"
  echo
  echo "  $CLAUDE_DESKTOP_BUNDLE_PATH"
  echo
  if [[ "$CLAUDE_DESKTOP_BUNDLE_OPEN_STATUS" == "opened" ]]; then
    echo "  The installer asked macOS to open this .mcpb file now."
    echo "  If Claude Desktop was closed, macOS may launch it for you."
    echo
    echo "  If no install dialog appeared, install it manually:"
  else
    echo "  Automatic opening did not succeed. Install it manually:"
  fi
  echo
  echo "  Claude Desktop: Settings -> Extensions -> Install extension from file..."
  echo "  Choose: $CLAUDE_DESKTOP_BUNDLE_PATH"
  echo "  Enable the extension, then start a new Claude Desktop chat."
  echo
  echo "  Diagnostics:"
  echo "    node detected: $NODE_RUNTIME_PATH"
  echo "    node version: $NODE_RUNTIME_VERSION"
  echo "    server entry: $REPO_MCP_ENTRY"
  echo "$border"
}

show_agent_restart_notes() {
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
    echo "[install-mac] note: restart Claude Code if it was already open."
  fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then
    echo "[install-mac] note: restart Cursor if it was already open."
  fi
}

show_post_install_diagnostics() {
  echo
  if [[ "$SELECT_CODEX" -eq 1 ]]; then
    print_agent_mcp_diagnostic "Codex" "$CODEX_HOME_DIR/config.toml"
  fi
  if [[ "$SELECT_CODEX_APP" -eq 1 ]]; then
    print_agent_mcp_diagnostic "Codex App" "$CODEX_HOME_DIR/config.toml"
  fi
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
    print_agent_mcp_diagnostic "Claude Code" "user scope via $CLAUDE_CLI_PATH"
  fi
  if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then
    print_claude_desktop_extension_diagnostic
  fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then
    print_agent_mcp_diagnostic "Cursor" "$CURSOR_HOME_DIR/mcp.json"
  fi
  show_agent_restart_notes
}

open_claude_desktop_extension_bundle() {
  if [[ "$SELECT_CLAUDE_DESKTOP" -eq 0 ]]; then
    return 0
  fi

  if lfp_cdext_try_open_bundle "$CLAUDE_DESKTOP_BUNDLE_PATH"; then
    CLAUDE_DESKTOP_BUNDLE_OPEN_STATUS="opened"
  else
    CLAUDE_DESKTOP_BUNDLE_OPEN_STATUS="manual"
  fi
}

ensure_mcp_runtime() {
  detect_node_runtime
  require_cmd npm

  if [[ "$USE_PREBUILT" -eq 1 ]]; then
    ensure_prebuilt_bundle_support_files
    echo "[install-mac] bootstrapping MCP runtime in $REPO_MCP_DIR"
    (
      cd "$REPO_MCP_DIR"
      if [[ -d node_modules ]]; then
        echo "[install-mac] reusing existing node_modules in $REPO_MCP_DIR"
      else
        npm install --omit=dev --no-package-lock >/dev/null
      fi
    )
    echo "[install-mac] using prebuilt MCP runtime at $REPO_MCP_ENTRY"
    return
  fi

  echo "[install-mac] bootstrapping MCP runtime in $REPO_MCP_DIR"
  (
    cd "$REPO_MCP_DIR"
    if [[ -d node_modules ]]; then
      echo "[install-mac] reusing existing node_modules in $REPO_MCP_DIR"
    else
      npm install --no-package-lock >/dev/null
    fi
    npm run build >/dev/null
  )

  if [[ ! -f "$REPO_MCP_ENTRY" ]]; then
    echo "[install-mac] MCP build did not produce $REPO_MCP_ENTRY" >&2
    exit 1
  fi
}

ensure_importer_runtime() {
  local manifest="$PROJECT_ROOT/packages/design-importer/Cargo.toml"

  if [[ "$USE_PREBUILT" -eq 1 ]]; then
    ensure_prebuilt_bundle_support_files
    chmod +x "$REPO_IMPORTER_EXE" >/dev/null 2>&1 || true
    echo "[install-mac] using prebuilt importer runtime at $REPO_IMPORTER_EXE"
    return
  fi

  require_cmd cargo
  require_cmd rustc

  if [[ ! -f "$manifest" ]]; then
    echo "[install-mac] missing importer manifest: $manifest" >&2
    exit 1
  fi

  echo "[install-mac] bootstrapping importer runtime in $PROJECT_ROOT/packages/design-importer"
  cargo build --manifest-path "$manifest" --release >/dev/null
}

ensure_figma_plugin_runtime() {
  require_cmd npm

  if [[ "$USE_PREBUILT" -eq 1 ]]; then
    ensure_prebuilt_bundle_support_files
    echo "[install-mac] using prebuilt Figma plugin bundle at $REPO_PLUGIN_ENTRY"
    return
  fi

  if [[ ! -f "$REPO_PLUGIN_PACKAGE" ]]; then
    echo "[install-mac] missing Figma plugin package: $REPO_PLUGIN_PACKAGE" >&2
    exit 1
  fi

  echo "[install-mac] bootstrapping Figma plugin runtime in $REPO_PLUGIN_DIR"
  (
    cd "$REPO_PLUGIN_DIR"
    if [[ -d node_modules ]]; then
      echo "[install-mac] reusing existing node_modules in $REPO_PLUGIN_DIR"
    else
      npm install --no-package-lock >/dev/null
    fi
    npm run build >/dev/null
  )

  if [[ ! -f "$REPO_PLUGIN_ENTRY" ]]; then
    echo "[install-mac] Figma plugin build did not produce $REPO_PLUGIN_ENTRY" >&2
    exit 1
  fi
}

ensure_prebuilt_bundle_support_files() {
  if [[ ! -f "$REPO_MCP_ENTRY" ]]; then
    echo "[install-mac] missing prebuilt MCP stdio entry: $REPO_MCP_ENTRY" >&2
    exit 1
  fi
  if [[ ! -f "$REPO_MCP_HTTP_ENTRY" ]]; then
    echo "[install-mac] missing prebuilt MCP HTTP entry: $REPO_MCP_HTTP_ENTRY" >&2
    exit 1
  fi
  if [[ ! -f "$REPO_MCP_PACKAGE" ]]; then
    echo "[install-mac] missing prebuilt MCP package metadata: $REPO_MCP_PACKAGE" >&2
    exit 1
  fi
  if [[ ! -f "$REPO_IMPORTER_EXE" ]]; then
    echo "[install-mac] missing prebuilt importer executable: $REPO_IMPORTER_EXE" >&2
    exit 1
  fi
  if [[ ! -f "$REPO_PLUGIN_ENTRY" ]]; then
    echo "[install-mac] missing prebuilt Figma plugin bundle: $REPO_PLUGIN_ENTRY" >&2
    exit 1
  fi
  if [[ ! -f "$REPO_PLUGIN_MANIFEST" ]]; then
    echo "[install-mac] missing prebuilt Figma plugin manifest: $REPO_PLUGIN_MANIFEST" >&2
    exit 1
  fi
  if ! grep -Fq "IMPORTER_EXE" "$REPO_MCP_HTTP_ENTRY"; then
    echo "[install-mac] prebuilt MCP HTTP entry does not support prebuilt importer execution yet: $REPO_MCP_HTTP_ENTRY" >&2
    echo "[install-mac] rebuild the macOS release bundle from the updated repository before publishing it." >&2
    exit 1
  fi
  if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]] && ! lfp_cdext_has_payload "$REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"; then
    echo "[install-mac] missing prebuilt Claude Desktop extension payload: $REPO_CLAUDE_DESKTOP_PAYLOAD_DIR" >&2
    echo "[install-mac] rebuild the macOS release bundle from the updated repository before publishing it." >&2
    exit 1
  fi
}

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
    echo "[install-mac] invalid JSON in $label: $file" >&2
    exit 1
  fi
}

preflight_project_json_configs() {
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then
    validate_json_file_if_present "$CURSOR_HOME_DIR/mcp.json" "Cursor global MCP config"
  fi
}

seed_state_data_if_needed() {
  mkdir -p "$REPO_DATA" "$RUN_DIR" "$LOG_DIR"

  if [[ "$PROJECT_DATA_DIR" == "$REPO_DATA" || ! -d "$PROJECT_DATA_DIR" ]]; then
    return
  fi

  local source_sample=""
  local target_sample=""
  source_sample="$(find "$PROJECT_DATA_DIR" -mindepth 1 -print -quit 2>/dev/null || true)"
  target_sample="$(find "$REPO_DATA" -mindepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$source_sample" && -z "$target_sample" ]]; then
    cp -R "$PROJECT_DATA_DIR"/. "$REPO_DATA"/
    echo "[install-mac] seeded stable state data from $PROJECT_DATA_DIR"
  fi
}

render_codex_toml_block() {
  cat <<EOF
[mcp_servers.local-figma-port]
command = "node"
args = ["$REPO_MCP_ENTRY_POSIX"]
env = { SQLITE3_BIN = "$REPO_SQLITE3_BIN", SQLITE_PATH = "$REPO_SQLITE_POSIX", DATA_DIR = "$REPO_DATA_POSIX" }
EOF
}

write_with_backup() {
  local file="$1"
  local tmp="$2"

  if [[ -f "$file" ]] && cmp -s "$file" "$tmp"; then
    echo "[install-mac] unchanged: $file"
    rm -f "$tmp"
    return
  fi

  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    cp "$file" "$file.local-figma-port.$TIMESTAMP.bak"
    echo "[install-mac] backup: $file.local-figma-port.$TIMESTAMP.bak"
  fi
  mv "$tmp" "$file"
  echo "[install-mac] wrote: $file"
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

  if [[ -s "$tmp" ]]; then
    awk '
      { lines[NR] = $0 }
      NF { last_nonempty = NR }
      END {
        for (i = 1; i <= last_nonempty; i++) {
          print lines[i]
        }
      }
    ' "$tmp" > "$tmp.cleaned"
    mv "$tmp.cleaned" "$tmp"
    printf '\n' >> "$tmp"
    write_with_backup "$file" "$tmp"
  else
    rm -f "$tmp"
    if [[ -f "$file" ]]; then
      rm -f "$file"
      echo "[install-mac] removed: $file"
    fi
  fi
}

upsert_codex_toml_block() {
  local file="$1"
  local block="$2"
  local tmp

  if [[ -f "$file" ]] && grep -Fq "[mcp_servers.local-figma-port]" "$file" && ! grep -Fq "$CODEX_TOML_MARKER_START" "$file"; then
    echo "[install-mac] found an unmanaged [mcp_servers.local-figma-port] block in $file" >&2
    echo "[install-mac] refusing to overwrite it automatically." >&2
    exit 1
  fi

  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v start="$CODEX_TOML_MARKER_START" -v end="$CODEX_TOML_MARKER_END" '
      skip_legacy && /^\[/ { skip_legacy = 0 }
      $0 == "[mcp_servers.design_local]" { skip_legacy = 1; next }
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip && !skip_legacy { print }
    ' "$file" > "$tmp"
  fi

  if [[ -s "$tmp" ]]; then
    printf '\n' >> "$tmp"
  fi
  printf '%s\n' "$CODEX_TOML_MARKER_START" >> "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  printf '%s\n' "$CODEX_TOML_MARKER_END" >> "$tmp"
  write_with_backup "$file" "$tmp"
}

upsert_json_mcp_file() {
  local file="$1"
  local tmp
  local server_json

  server_json="$(cat <<EOF
{"command":"node","args":["$REPO_MCP_ENTRY_POSIX"],"env":{"SQLITE3_BIN":"$REPO_SQLITE3_BIN","SQLITE_PATH":"$REPO_SQLITE_POSIX","DATA_DIR":"$REPO_DATA_POSIX"}}
EOF
)"

  tmp="$(mktemp)"
  node - "$file" "$tmp" "$server_json" <<'NODE'
const fs = require("node:fs");
const [file, tmp, serverJson] = process.argv.slice(2);
let data = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, "utf8").trim();
  if (raw) {
    data = JSON.parse(raw);
  }
}
if (!data.mcpServers || typeof data.mcpServers !== "object" || Array.isArray(data.mcpServers)) {
  data.mcpServers = {};
}
delete data.mcpServers.design_local;
data.mcpServers["local-figma-port"] = JSON.parse(serverJson);
fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
NODE
  write_with_backup "$file" "$tmp"
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

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    if [[ -f "$file" ]]; then
      rm -f "$file"
      echo "[install-mac] removed: $file"
    fi
    return
  fi

  write_with_backup "$file" "$tmp"
}

copy_skill_file() {
  local target_dir="$1"
  local target_file="$target_dir/SKILL.md"
  local interface_file="$target_dir/agents/openai.yaml"
  local tmp
  local interface_tmp

  tmp="$(mktemp)"
  cp "$REPO_SKILL" "$tmp"
  write_with_backup "$target_file" "$tmp"

  interface_tmp="$(mktemp)"
  cat > "$interface_tmp" <<'EOF'
interface:
  display_name: Local Figma Port
  short_description: Exact UI replication from the Local Figma Port MCP server
  default_prompt: Use the Local Figma Port MCP server as the source of truth and implement the target UI with exact traced fidelity.
EOF
  write_with_backup "$interface_file" "$interface_tmp"
}

set_claude_user_subagent() {
  local agent_file="$CLAUDE_HOME_DIR/agents/local-figma-port.md"
  local tmp

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
---
name: local-figma-port
description: Use proactively when implementing UI from Local Figma Port MCP context or when troubleshooting this MCP workflow.
---

You are the Local Figma Port specialist for Claude Code.

When the user asks for Local Figma Port, Figma implementation fidelity, or MCP troubleshooting:
- Follow the skill at \`$CLAUDE_HOME_DIR/skills/local-figma-port/SKILL.md\`.
- Prefer the \`local-figma-port\` MCP server over guessing from partial context.
- Use the exported design context end-to-end before concluding work.
EOF
  write_with_backup "$agent_file" "$tmp"
}

set_claude_user_mcp_server() {
  resolve_claude_cli

  "$CLAUDE_CLI_PATH" mcp remove local-figma-port --scope user >/dev/null 2>&1 || true
  "$CLAUDE_CLI_PATH" mcp add local-figma-port --scope user \
    --env "SQLITE3_BIN=$REPO_SQLITE3_BIN" \
    --env "SQLITE_PATH=$REPO_SQLITE_POSIX" \
    --env "DATA_DIR=$REPO_DATA_POSIX" \
    -- node "$REPO_MCP_ENTRY_POSIX" >/dev/null
}

set_claude_desktop_extension_bundle() {
  local staging_root=""
  local extension_root=""
  local manifest_path=""
  local mcp_version=""

  mcp_version="$(node -e 'const fs = require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version);' "$REPO_MCP_PACKAGE")"
  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/local-figma-port-claude-desktop.XXXXXX")"
  extension_root="$staging_root/extension"
  manifest_path="$extension_root/manifest.json"

  mkdir -p "$extension_root" "$(dirname "$CLAUDE_DESKTOP_BUNDLE_PATH")"
  if lfp_cdext_has_payload "$REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"; then
    cp -R "$REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"/. "$extension_root/"
    echo "[install-mac] using prebuilt Claude Desktop extension payload at $REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"
  else
    lfp_cdext_prepare_payload "$REPO_MCP_DIR" "$PROJECT_ROOT" "$extension_root"
    echo "[install-mac] built Claude Desktop extension payload locally"
  fi

  cat > "$manifest_path" <<EOF
{
  "manifest_version": "0.3",
  "name": "local-figma-port",
  "display_name": "Local Figma Port",
  "version": "$mcp_version",
  "description": "Read Local Figma Port design exports from Claude Desktop.",
  "long_description": "Local-first MCP access to the Local Figma Port design store. Start the Local Figma Port runtime, export from the Figma Desktop plugin, then use this extension inside Claude Desktop.",
  "author": {
    "name": "echo-ae"
  },
  "documentation": "https://github.com/echo-ae/local_figma_port#readme",
  "support": "https://github.com/echo-ae/local_figma_port/issues",
  "repository": {
    "type": "git",
    "url": "https://github.com/echo-ae/local_figma_port.git"
  },
  "tools_generated": true,
  "server": {
    "type": "node",
    "entry_point": "server/mcp-stdio.js",
    "mcp_config": {
      "command": "node",
      "args": ["\${__dirname}/server/mcp-stdio.js"],
      "env": {
        "SQLITE3_BIN": "$REPO_SQLITE3_BIN",
        "SQLITE_PATH": "$REPO_SQLITE_POSIX",
        "DATA_DIR": "$REPO_DATA_POSIX"
      }
    }
  }
}
EOF

  rm -f "$CLAUDE_DESKTOP_BUNDLE_PATH"
  lfp_cdext_pack_dir "$extension_root" "$CLAUDE_DESKTOP_BUNDLE_PATH"
  rm -rf "$staging_root"
  echo "[install-mac] wrote: $CLAUDE_DESKTOP_BUNDLE_PATH"
}

print_summary() {
  echo
  echo "[install-mac] summary"
  if [[ "$SELECT_CODEX" -eq 1 ]]; then echo "  - Codex"; fi
  if [[ "$SELECT_CODEX_APP" -eq 1 ]]; then echo "  - Codex App"; fi
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then echo "  - Claude Code"; fi
  if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then echo "  - Claude Desktop"; fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then echo "  - Cursor"; fi
  echo "  - project root: $PROJECT_ROOT"
  echo "  - config root: $CONFIG_ROOT"
  echo "  - state root: $STATE_ROOT_DIR"
  if [[ "$USE_PREBUILT" -eq 1 ]]; then echo "  - mode: prebuilt bundle"; fi
  if [[ "$SELECT_CODEX_APP" -eq 1 ]]; then echo "  - codex app data: $CODEX_APP_DATA_DIR"; fi
  return 0
}

print_summary

preflight_project_json_configs
ensure_codex_app_installed
ensure_sqlite_fts5
ensure_mcp_runtime
ensure_importer_runtime
ensure_figma_plugin_runtime
seed_state_data_if_needed

if [[ "$SELECT_CODEX" -eq 1 || "$SELECT_CODEX_APP" -eq 1 ]]; then
  copy_skill_file "$CODEX_HOME_DIR/skills/local-figma-port"
  upsert_codex_toml_block "$CODEX_HOME_DIR/config.toml" "$(render_codex_toml_block)"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  copy_skill_file "$CLAUDE_HOME_DIR/skills/local-figma-port"
  set_claude_user_subagent
  set_claude_user_mcp_server
  remove_json_mcp_server "$HOME/.claude.json"
  remove_json_mcp_server "$CONFIG_ROOT/.mcp.json"
  remove_markdown_block "$CONFIG_ROOT/CLAUDE.md" "<!-- FIGMA PORT CLAUDE BLOCK START -->" "<!-- FIGMA PORT CLAUDE BLOCK END -->"
fi

if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then
  set_claude_desktop_extension_bundle
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  upsert_json_mcp_file "$CURSOR_HOME_DIR/mcp.json"
  remove_json_mcp_server "$CONFIG_ROOT/.cursor/mcp.json"
fi

VERIFY_ARGS=(--project-root "$PROJECT_ROOT" --config-root "$CONFIG_ROOT" --state-dir "$STATE_ROOT_DIR" --codex-home "$CODEX_HOME_DIR" --claude-home "$CLAUDE_HOME_DIR" --cursor-home "$CURSOR_HOME_DIR")
[[ "$SELECT_CODEX" -eq 1 ]] && VERIFY_ARGS+=(--codex)
[[ "$SELECT_CODEX_APP" -eq 1 ]] && VERIFY_ARGS+=(--codex-app --codex-app-data "$CODEX_APP_DATA_DIR" --codex-app-bundle "$CODEX_APP_BUNDLE")
[[ "$SELECT_CLAUDE" -eq 1 ]] && VERIFY_ARGS+=(--claude-code)
[[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]] && VERIFY_ARGS+=(--claude-desktop)
[[ "$SELECT_CURSOR" -eq 1 ]] && VERIFY_ARGS+=(--cursor)

"$PROJECT_ROOT/scripts/verify/macos.sh" "${VERIFY_ARGS[@]}"
LOCAL_FIGMA_PORT_STATE_DIR="$STATE_ROOT_DIR" DATA_DIR="$REPO_DATA" SQLITE_PATH="$REPO_SQLITE" SQLITE3_BIN="$REPO_SQLITE3_BIN" IMPORTER_EXE="$REPO_IMPORTER_EXE" "$PROJECT_ROOT/scripts/runtime/start.sh"
if [[ "$SELECT_CODEX_APP" -eq 1 ]]; then
  restart_codex_app_if_needed
fi
open_claude_desktop_extension_bundle
show_figma_plugin_manifest_instructions
show_post_install_diagnostics
echo "[install-mac] install complete"
