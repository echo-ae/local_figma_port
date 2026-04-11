#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/local_figma_port_state.sh"

PROJECT_ROOT="$ROOT_DIR"
CONFIG_ROOT=""
STATE_ROOT_DIR="${LOCAL_FIGMA_PORT_STATE_DIR:-$(lfp_default_state_root)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_APP_DATA_DIR="${CODEX_APP_DATA_DIR:-$HOME/Library/Application Support/Codex}"
CODEX_APP_BUNDLE="${CODEX_APP_BUNDLE:-/Applications/Codex.app}"
CLAUDE_HOME_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CURSOR_HOME_DIR="${CURSOR_HOME:-$HOME/.cursor}"

SELECT_CODEX=0
SELECT_CODEX_APP=0
SELECT_CLAUDE=0
SELECT_CURSOR=0
EXPLICIT_SELECTION=0

usage() {
  cat <<EOF
usage: ./scripts/verify/macos.sh [options]

options:
  --codex                 verify Codex integration
  --codex-app             verify Codex App integration
  --claude-code           verify Claude Code integration
  --cursor                verify Cursor integration
  --all                   verify all supported targets
  --project-root PATH     override repository root
  --config-root PATH      override workspace root for project-local config files (.mcp.json, .cursor/mcp.json, CLAUDE.md, AGENTS.md)
  --state-dir PATH        override Local Figma Port state root
  --codex-home PATH       override Codex home
  --codex-app-data PATH   override Codex App data dir
  --codex-app-bundle PATH override Codex App bundle path
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
    --cursor)
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
      ;;
    --all)
      SELECT_CODEX=1
      SELECT_CODEX_APP=1
      SELECT_CLAUDE=1
      SELECT_CURSOR=1
      EXPLICIT_SELECTION=1
      shift
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
      echo "[verify-mac] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$EXPLICIT_SELECTION" -eq 0 ]]; then
  SELECT_CODEX=1
  SELECT_CODEX_APP=0
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
if [[ -z "$CONFIG_ROOT" ]]; then
  CONFIG_ROOT="$PROJECT_ROOT"
else
  CONFIG_ROOT="$(normalize_path "$CONFIG_ROOT")"
  mkdir -p "$CONFIG_ROOT"
  CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd)"
fi
STATE_ROOT_DIR="$(normalize_path "$STATE_ROOT_DIR")"
REPO_SKILL="$PROJECT_ROOT/SKILL.md"
REPO_MCP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/mcp-stdio.js"
REPO_MCP_HTTP_ENTRY="$PROJECT_ROOT/packages/mcp-server/dist/index.js"
REPO_MCP_DIR="$PROJECT_ROOT/packages/mcp-server"
REPO_MCP_PACKAGE="$REPO_MCP_DIR/package.json"
REPO_IMPORTER_EXE="$PROJECT_ROOT/packages/design-importer/target/release/design-importer"
REPO_PLUGIN_ENTRY="$PROJECT_ROOT/packages/figma-exporter-plugin/dist/main.js"
REPO_PLUGIN_MANIFEST="$PROJECT_ROOT/packages/figma-exporter-plugin/manifest.json"
REPO_SQLITE="$(lfp_sqlite_path "$STATE_ROOT_DIR")"
REPO_DATA="$(lfp_data_dir "$STATE_ROOT_DIR")"
REPO_SQLITE3_BIN="$(command -v sqlite3 2>/dev/null || true)"

AGENTS_MARKER_START="<!-- FIGMA PORT MANAGED BLOCK START -->"
AGENTS_MARKER_END="<!-- FIGMA PORT MANAGED BLOCK END -->"
CLAUDE_MARKER_START="<!-- FIGMA PORT CLAUDE BLOCK START -->"
CLAUDE_MARKER_END="<!-- FIGMA PORT CLAUDE BLOCK END -->"
CODEX_TOML_MARKER_START="# >>> FIGMA PORT MCP START >>>"
CODEX_TOML_MARKER_END="# <<< FIGMA PORT MCP END <<<"

failures=0

ok() {
  echo "[verify-mac] ok: $1"
}

fail() {
  echo "[verify-mac] fail: $1" >&2
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
  if node - "$file" "$REPO_MCP_ENTRY" "$REPO_SQLITE3_BIN" "$REPO_SQLITE" "$REPO_DATA" <<'NODE'
const fs = require("node:fs");
const [file, entry, sqlite3Bin, sqlite, dataDir] = process.argv.slice(2);
const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
const server = parsed?.mcpServers?.["local-figma-port"];
if (!server) process.exit(1);
if (server.command !== "node") process.exit(1);
if (!Array.isArray(server.args) || server.args[0] !== entry) process.exit(1);
if (!server.env || server.env.SQLITE3_BIN !== sqlite3Bin || server.env.SQLITE_PATH !== sqlite || server.env.DATA_DIR !== dataDir) process.exit(1);
NODE
  then
    ok "$label"
  else
    fail "$label"
  fi
}

check_codex_app_skill_index() {
  local label="$1"
  local codex_bin="$CODEX_APP_BUNDLE/Contents/Resources/codex"
  if [[ ! -x "$codex_bin" ]]; then
    fail "$label (missing codex binary: $codex_bin)"
    return
  fi

  if node - "$codex_bin" "$PROJECT_ROOT" <<'NODE'
const { spawn } = require("node:child_process");

const [codexBin, cwd] = process.argv.slice(2);
const child = spawn(codexBin, ["app-server"], {
  cwd,
  stdio: ["pipe", "pipe", "inherit"],
});

let stdout = "";
let done = false;
let requestId = 0;

function send(msg) {
  child.stdin.write(JSON.stringify(msg) + "\n");
}

function finish(code, message) {
  if (done) return;
  done = true;
  if (message) console.error(message);
  child.kill("SIGTERM");
  process.exit(code);
}

child.stdout.on("data", (chunk) => {
  stdout += chunk.toString("utf8");
  let newline;
  while ((newline = stdout.indexOf("\n")) !== -1) {
    const line = stdout.slice(0, newline).trim();
    stdout = stdout.slice(newline + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id === "init" && msg.result) {
      send({
        method: "skills/list",
        id: "skills",
        params: { cwds: [cwd], forceReload: true },
      });
      continue;
    }
    if (msg.id === "init" && msg.error) {
      finish(1, `initialize failed: ${msg.error.message || "unknown error"}`);
      return;
    }
    if (msg.id === "skills" && msg.error) {
      finish(1, `skills/list failed: ${msg.error.message || "unknown error"}`);
      return;
    }
    if (msg.id === "skills" && msg.result) {
      const entry = (msg.result.data || []).find((item) => item.cwd === cwd);
      if (!entry) {
        finish(1, `skills/list missing cwd entry for ${cwd}`);
        return;
      }
      if (Array.isArray(entry.errors) && entry.errors.length > 0) {
        finish(1, `skills/list returned errors: ${entry.errors.map((e) => `${e.path}: ${e.message}`).join(" | ")}`);
        return;
      }
      const skill = (entry.skills || []).find((item) => item.name === "local-figma-port");
      if (!skill) {
        finish(1, "skills/list did not include local-figma-port");
        return;
      }
      if ((skill.interface?.displayName || null) !== "Local Figma Port") {
        finish(1, `local-figma-port displayName mismatch: ${skill.interface?.displayName ?? "null"}`);
        return;
      }
      finish(0);
    }
  }
});

child.on("error", (error) => finish(1, error.message));
child.on("exit", (code) => {
  if (!done) finish(code || 1, `codex app-server exited early with code ${code}`);
});

send({
  method: "initialize",
  id: "init",
  params: {
    clientInfo: { name: "verify-mac", title: "verify-mac", version: "1.0" },
    capabilities: { experimentalApi: true },
  },
});

setTimeout(() => finish(1, "timed out waiting for skills/list"), 10000);
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
  if [[ -n "$REPO_SQLITE3_BIN" ]]; then
    check_contains "$CODEX_HOME_DIR/config.toml" "$REPO_SQLITE3_BIN" "$label_prefix config points at sqlite3 binary"
  else
    fail "$label_prefix config points at sqlite3 binary"
  fi
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
if [[ ! -f "$REPO_MCP_HTTP_ENTRY" ]]; then
  fail "built MCP HTTP entry exists ($REPO_MCP_HTTP_ENTRY)"
elif ! grep -Fq "IMPORTER_EXE" "$REPO_MCP_HTTP_ENTRY"; then
  fail "MCP HTTP entry supports prebuilt importer execution"
else
  ok "MCP HTTP entry supports prebuilt importer execution"
fi
if [[ ! -f "$REPO_MCP_PACKAGE" ]]; then
  fail "MCP package metadata exists ($REPO_MCP_PACKAGE)"
fi
if [[ ! -d "$REPO_DATA" ]]; then
  fail "stable data dir exists ($REPO_DATA)"
fi
if [[ ! -x "$REPO_IMPORTER_EXE" && ! -f "$REPO_IMPORTER_EXE" ]]; then
  fail "importer executable exists ($REPO_IMPORTER_EXE)"
fi
if [[ ! -f "$REPO_PLUGIN_ENTRY" ]]; then
  fail "Figma plugin bundle exists ($REPO_PLUGIN_ENTRY)"
fi
if [[ ! -f "$REPO_PLUGIN_MANIFEST" ]]; then
  fail "Figma plugin manifest exists ($REPO_PLUGIN_MANIFEST)"
fi
if [[ ! -d "$REPO_MCP_DIR/node_modules" ]]; then
  fail "MCP runtime dependencies exist ($REPO_MCP_DIR/node_modules)"
fi
check_sqlite_fts5 "system sqlite3 supports FTS5"

if [[ "$SELECT_CODEX" -eq 1 ]]; then
  verify_codex_shared_config "Codex"
  check_contains "$CONFIG_ROOT/AGENTS.md" '$Local Figma Port' "AGENTS.md advertises \$Local Figma Port"
  check_contains "$CONFIG_ROOT/AGENTS.md" "$AGENTS_MARKER_START" "AGENTS.md has managed skill block"
  check_contains "$CONFIG_ROOT/AGENTS.md" "$REPO_SKILL" "AGENTS.md points at repo skill"
fi

if [[ "$SELECT_CODEX_APP" -eq 1 ]]; then
  if [[ ! -d "$CODEX_APP_DATA_DIR" && ! -d "$CODEX_APP_BUNDLE" ]]; then
    fail "Codex App installation detected (checked $CODEX_APP_DATA_DIR and $CODEX_APP_BUNDLE)"
  else
    ok "Codex App installation detected"
  fi
  verify_codex_shared_config "Codex App"
  check_codex_app_skill_index "Codex App app-server indexes local-figma-port"
  check_contains "$CONFIG_ROOT/AGENTS.md" '$Local Figma Port' "Codex App alias is exposed through AGENTS.md"
  check_contains "$CONFIG_ROOT/AGENTS.md" "$AGENTS_MARKER_START" "Codex App AGENTS.md has managed skill block"
  check_contains "$CONFIG_ROOT/AGENTS.md" "$REPO_SKILL" "Codex App AGENTS.md points at repo skill"
fi

if [[ "$SELECT_CLAUDE" -eq 1 ]]; then
  check_contains "$CLAUDE_HOME_DIR/skills/local-figma-port/SKILL.md" "name: local-figma-port" "Claude Code skill installed"
  check_json_server "$CONFIG_ROOT/.mcp.json" "Claude project MCP config points at repo build"
  check_contains "$CONFIG_ROOT/CLAUDE.md" "$CLAUDE_MARKER_START" "CLAUDE.md has managed skill block"
  check_contains "$CONFIG_ROOT/CLAUDE.md" '$Local Figma Port' "CLAUDE.md advertises \$Local Figma Port"
  check_contains "$CONFIG_ROOT/CLAUDE.md" "$REPO_SKILL" "CLAUDE.md points at repo skill"
fi

if [[ "$SELECT_CURSOR" -eq 1 ]]; then
  check_json_server "$CONFIG_ROOT/.cursor/mcp.json" "Cursor project MCP config points at repo build"
  check_contains "$CONFIG_ROOT/AGENTS.md" '$Local Figma Port' "Cursor alias is exposed through AGENTS.md"
  check_contains "$CONFIG_ROOT/AGENTS.md" "$AGENTS_MARKER_END" "AGENTS.md managed block is complete"
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[verify-mac] all checks passed"
