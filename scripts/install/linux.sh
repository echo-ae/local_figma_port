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
NODE_RUNTIME_PATH=""
NODE_RUNTIME_VERSION=""
CLAUDE_CLI_PATH=""
CLAUDE_DESKTOP_BUNDLE_OPEN_STATUS="not-attempted"

SELECT_CODEX=0
SELECT_CLAUDE=0
SELECT_CLAUDE_DESKTOP=0
SELECT_CURSOR=0
EXPLICIT_SELECTION=0

usage() {
  cat <<EOF
usage: ./scripts/install/linux.sh [options]

options:
  --codex                 install for Codex
  --claude-code           install for Claude Code
  --claude-desktop        install for Claude Desktop
  --cursor                install for Cursor
  --all                   install for all supported targets
  --targets LIST          install for comma-separated target numbers: 1=Codex, 2=Claude Code, 3=Claude Desktop, 4=Cursor
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
    3|claude-desktop|claude_desktop|claude-desktop-app)
      SELECT_CLAUDE_DESKTOP=1
      ;;
    4|cursor)
      SELECT_CURSOR=1
      ;;
    *)
      echo "[install-linux] unknown target token: $token" >&2
      exit 2
      ;;
  esac
}

apply_targets_csv() {
  local csv="$1"
  local token
  SELECT_CODEX=0
  SELECT_CLAUDE=0
  SELECT_CLAUDE_DESKTOP=0
  SELECT_CURSOR=0
  if [[ "$csv" == "all" || "$csv" == "ALL" ]]; then
    SELECT_CODEX=1
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
    --targets)
      apply_targets_csv "$2"
      shift 2
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
      echo "[install-linux] unknown option: $1" >&2
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
    echo "[install-linux] missing required command: $cmd" >&2
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

  echo "[install-linux] Claude Code CLI not found." >&2
  echo "[install-linux] install Claude Code so the \`claude\` command is available, then re-run the installer." >&2
  exit 1
}

ensure_sqlite_fts5() {
  require_cmd sqlite3
  if ! sqlite3 :memory: "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" >/dev/null 2>&1; then
    echo "[install-linux] sqlite3 is present, but this build does not support FTS5." >&2
    echo "[install-linux] install a sqlite3 build with FTS5 enabled and re-run the installer." >&2
    exit 1
  fi
}

validate_skill_frontmatter() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "[install-linux] missing skill file: $file" >&2
    exit 1
  fi
  if ! head -n 1 "$file" | grep -Fxq -- "---"; then
    echo "[install-linux] skill file is missing opening YAML frontmatter delimiter: $file" >&2
    exit 1
  fi
}

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
REPO_SKILL="$PROJECT_ROOT/SKILL.md"
REPO_MCP_DIR="$PROJECT_ROOT/packages/mcp-server"
REPO_CLAUDE_DESKTOP_PAYLOAD_DIR="$REPO_MCP_DIR/claude-desktop-extension-payload"
REPO_MCP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/mcp-stdio.js"
REPO_PLUGIN_MANIFEST="$PROJECT_ROOT/packages/figma-exporter-plugin/manifest.json"
PROJECT_DATA_DIR="$PROJECT_ROOT/data"
REPO_DATA="$(lfp_data_dir "$STATE_ROOT_DIR")"
REPO_SQLITE="$(lfp_sqlite_path "$STATE_ROOT_DIR")"
CLAUDE_DESKTOP_BUNDLE_PATH="$(lfp_claude_desktop_bundle_path "$STATE_ROOT_DIR")"
RUN_DIR="$(lfp_run_dir "$STATE_ROOT_DIR")"
LOG_DIR="$(lfp_log_dir "$STATE_ROOT_DIR")"
REPO_SKILL_POSIX="$REPO_SKILL"
REPO_MCP_ENTRY_POSIX="$REPO_MCP_ENTRY"
REPO_SQLITE_POSIX="$REPO_SQLITE"
REPO_DATA_POSIX="$REPO_DATA"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

CODEX_TOML_MARKER_START="# >>> FIGMA PORT MCP START >>>"
CODEX_TOML_MARKER_END="# <<< FIGMA PORT MCP END <<<"

if [[ ! -f "$REPO_SKILL" ]]; then
  echo "[install-linux] missing repo skill: $REPO_SKILL" >&2
  exit 1
fi
validate_skill_frontmatter "$REPO_SKILL"

if [[ ! -f "$REPO_MCP_DIR/package.json" ]]; then
  echo "[install-linux] missing MCP package: $REPO_MCP_DIR/package.json" >&2
  exit 1
fi

print_target_menu() {
  cat <<EOF

Select targets to configure by number:
  [1] Codex
  [2] Claude Code
  [3] Claude Desktop
  [4] Cursor

Enter numbers separated by commas (example: 1,2,4) or 'all'. Press Enter for all targets.
EOF
}

run_interactive_selection() {
  SELECT_CODEX=1
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
        if [[ "$SELECT_CODEX" -eq 0 && "$SELECT_CLAUDE" -eq 0 && "$SELECT_CLAUDE_DESKTOP" -eq 0 && "$SELECT_CURSOR" -eq 0 ]]; then
          echo "[install-linux] select at least one target." >&2
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
    echo "[install-linux] no target selection provided and stdin is not interactive." >&2
    echo "[install-linux] use --all, --targets, or one of --codex / --claude-code / --claude-desktop / --cursor." >&2
    exit 2
  fi
fi

ensure_mcp_runtime() {
  detect_node_runtime
  require_cmd npm

  echo "[install-linux] bootstrapping MCP runtime in $REPO_MCP_DIR"
  (
    cd "$REPO_MCP_DIR"
    if [[ -d node_modules ]]; then
      echo "[install-linux] reusing existing node_modules in $REPO_MCP_DIR"
    else
      npm install --no-package-lock >/dev/null
    fi
    npm run build >/dev/null
  )

  if [[ ! -f "$REPO_MCP_ENTRY" ]]; then
    echo "[install-linux] MCP build did not produce $REPO_MCP_ENTRY" >&2
    exit 1
  fi
}

ensure_importer_runtime() {
  local manifest="$PROJECT_ROOT/packages/design-importer/Cargo.toml"

  require_cmd cargo
  require_cmd rustc

  if [[ ! -f "$manifest" ]]; then
    echo "[install-linux] missing importer manifest: $manifest" >&2
    exit 1
  fi

  echo "[install-linux] bootstrapping importer runtime in $PROJECT_ROOT/packages/design-importer"
  cargo build --manifest-path "$manifest" --release >/dev/null
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
    echo "[install-linux] invalid JSON in $label: $file" >&2
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
    echo "[install-linux] seeded stable state data from $PROJECT_DATA_DIR"
  fi
}

render_codex_toml_block() {
  cat <<EOF
[mcp_servers.local-figma-port]
command = "node"
args = ["$REPO_MCP_ENTRY_POSIX"]
env = { SQLITE_PATH = "$REPO_SQLITE_POSIX", DATA_DIR = "$REPO_DATA_POSIX" }
EOF
}

write_with_backup() {
  local file="$1"
  local tmp="$2"

  if [[ -f "$file" ]] && cmp -s "$file" "$tmp"; then
    echo "[install-linux] unchanged: $file"
    rm -f "$tmp"
    return
  fi

  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    cp "$file" "$file.local-figma-port.$TIMESTAMP.bak"
    echo "[install-linux] backup: $file.local-figma-port.$TIMESTAMP.bak"
  fi
  mv "$tmp" "$file"
  echo "[install-linux] wrote: $file"
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
      echo "[install-linux] removed: $file"
    fi
  fi
}

upsert_codex_toml_block() {
  local file="$1"
  local block="$2"
  local tmp

  if [[ -f "$file" ]] && grep -Fq "[mcp_servers.local-figma-port]" "$file" && ! grep -Fq "$CODEX_TOML_MARKER_START" "$file"; then
    echo "[install-linux] found an unmanaged [mcp_servers.local-figma-port] block in $file" >&2
    echo "[install-linux] refusing to overwrite it automatically." >&2
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
{"command":"node","args":["$REPO_MCP_ENTRY_POSIX"],"env":{"SQLITE_PATH":"$REPO_SQLITE_POSIX","DATA_DIR":"$REPO_DATA_POSIX"}}
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
      echo "[install-linux] removed: $file"
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
    --env "SQLITE_PATH=$REPO_SQLITE_POSIX" \
    --env "DATA_DIR=$REPO_DATA_POSIX" \
    -- node "$REPO_MCP_ENTRY_POSIX" >/dev/null
}

set_claude_desktop_extension_bundle() {
  local staging_root=""
  local extension_root=""
  local manifest_path=""
  local sqlite_bin=""
  local mcp_version=""

  sqlite_bin="$(command -v sqlite3)"
  mcp_version="$(node -e 'const fs = require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version);' "$REPO_MCP_DIR/package.json")"
  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/local-figma-port-claude-desktop.XXXXXX")"
  extension_root="$staging_root/extension"
  manifest_path="$extension_root/manifest.json"

  mkdir -p "$extension_root" "$(dirname "$CLAUDE_DESKTOP_BUNDLE_PATH")"
  if lfp_cdext_has_payload "$REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"; then
    cp -R "$REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"/. "$extension_root/"
    echo "[install-linux] using prebuilt Claude Desktop extension payload at $REPO_CLAUDE_DESKTOP_PAYLOAD_DIR"
  else
    lfp_cdext_prepare_payload "$REPO_MCP_DIR" "$PROJECT_ROOT" "$extension_root"
    echo "[install-linux] built Claude Desktop extension payload locally"
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
        "SQLITE3_BIN": "$sqlite_bin",
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
  echo "[install-linux] wrote: $CLAUDE_DESKTOP_BUNDLE_PATH"
}

print_summary() {
  echo
  echo "[install-linux] summary"
  if [[ "$SELECT_CODEX" -eq 1 ]]; then echo "  - Codex"; fi
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then echo "  - Claude Code"; fi
  if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then echo "  - Claude Desktop"; fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then echo "  - Cursor"; fi
  echo "  - project root: $PROJECT_ROOT"
  echo "  - state root: $STATE_ROOT_DIR"
  return 0
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

  echo "[install-linux] MCP diagnostics for $agent_label"
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
    echo "  The installer asked your desktop session to open this .mcpb file now."
    echo "  If Claude Desktop was closed, your system may launch it for you."
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
  if [[ "$SELECT_CODEX" -eq 1 ]]; then
    echo "[install-linux] note: restart any open Codex sessions if they were already running."
  fi
  if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
    echo "[install-linux] note: restart Claude Code if it was already open."
  fi
  if [[ "$SELECT_CURSOR" -eq 1 ]]; then
    echo "[install-linux] note: restart Cursor if it was already open."
  fi
}

show_post_install_diagnostics() {
  echo
  if [[ "$SELECT_CODEX" -eq 1 ]]; then
    print_agent_mcp_diagnostic "Codex" "$CODEX_HOME_DIR/config.toml"
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

print_summary

preflight_project_json_configs
ensure_sqlite_fts5
ensure_mcp_runtime
ensure_importer_runtime
seed_state_data_if_needed

if [[ "$SELECT_CODEX" -eq 1 ]]; then
  copy_skill_file "$CODEX_HOME_DIR/skills/local-figma-port"
  upsert_codex_toml_block "$CODEX_HOME_DIR/config.toml" "$(render_codex_toml_block)"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  copy_skill_file "$CLAUDE_HOME_DIR/skills/local-figma-port"
  set_claude_user_subagent
  set_claude_user_mcp_server
  remove_json_mcp_server "$HOME/.claude.json"
  remove_json_mcp_server "$PROJECT_ROOT/.mcp.json"
  remove_markdown_block "$PROJECT_ROOT/CLAUDE.md" "<!-- FIGMA PORT CLAUDE BLOCK START -->" "<!-- FIGMA PORT CLAUDE BLOCK END -->"
fi

if [[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]]; then
  set_claude_desktop_extension_bundle
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  upsert_json_mcp_file "$CURSOR_HOME_DIR/mcp.json"
  remove_json_mcp_server "$PROJECT_ROOT/.cursor/mcp.json"
fi

VERIFY_ARGS=(--project-root "$PROJECT_ROOT" --state-dir "$STATE_ROOT_DIR" --codex-home "$CODEX_HOME_DIR" --claude-home "$CLAUDE_HOME_DIR" --cursor-home "$CURSOR_HOME_DIR")
[[ "$SELECT_CODEX" -eq 1 ]] && VERIFY_ARGS+=(--codex)
[[ "$SELECT_CLAUDE" -eq 1 ]] && VERIFY_ARGS+=(--claude-code)
[[ "$SELECT_CLAUDE_DESKTOP" -eq 1 ]] && VERIFY_ARGS+=(--claude-desktop)
[[ "$SELECT_CURSOR" -eq 1 ]] && VERIFY_ARGS+=(--cursor)

"$PROJECT_ROOT/scripts/verify/linux.sh" "${VERIFY_ARGS[@]}"
LOCAL_FIGMA_PORT_STATE_DIR="$STATE_ROOT_DIR" DATA_DIR="$REPO_DATA" SQLITE_PATH="$REPO_SQLITE" "$PROJECT_ROOT/scripts/runtime/start.sh"
open_claude_desktop_extension_bundle
echo "[install-linux] plugin bundle: $PROJECT_ROOT/packages/figma-exporter-plugin"
show_figma_plugin_manifest_instructions
show_post_install_diagnostics
echo "[install-linux] install complete"
