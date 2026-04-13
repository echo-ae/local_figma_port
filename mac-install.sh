#!/usr/bin/env bash
set -euo pipefail

TARGET=""
SELECTED_TARGET=""
ARCHITECTURE=""
GITHUB_REPO="echo-ae/local_figma_port"
RELEASE_TAG=""
BUNDLE_URL=""
WORKSPACE_ROOT="$(pwd)"
STATE_ROOT="${LOCAL_FIGMA_PORT_STATE_DIR:-$HOME/Library/Application Support/LocalFigmaPort}"
INSTALL_ROOT=""

usage() {
  cat <<'EOF'
usage: ./mac-install.sh [options]

options:
  --target NAME          target to configure: codex, codex-app, claude-code, claude-desktop, cursor
  --architecture ARCH    override architecture: arm64, x64, amd64
  --github-repo REPO     GitHub repo slug hosting release bundles (default: echo-ae/local_figma_port)
  --release-tag TAG      install from a specific GitHub release tag instead of latest
  --bundle-url URL       install from an explicit bundle URL
  --workspace-root PATH  workspace root for Claude Code or Cursor (default: current working directory)
  --state-dir PATH       Local Figma Port state root (default: ~/Library/Application Support/LocalFigmaPort)
  --install-root PATH    extracted runtime bundle root (default: <state-dir>/bundle/current)
  --help                 show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --architecture)
      ARCHITECTURE="$2"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    --release-tag)
      RELEASE_TAG="$2"
      shift 2
      ;;
    --bundle-url)
      BUNDLE_URL="$2"
      shift 2
      ;;
    --workspace-root)
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    --state-dir)
      STATE_ROOT="$2"
      shift 2
      ;;
    --install-root)
      INSTALL_ROOT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "[mac-install] unknown option: $1" >&2
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

refresh_process_path() {
  local additions=(
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
    "/usr/local/bin"
    "/usr/local/sbin"
  )
  local prefix=""
  local package_prefix=""

  if command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
      additions+=("$prefix/bin" "$prefix/sbin")
    fi
    for package in sqlite node; do
      package_prefix="$(brew --prefix "$package" 2>/dev/null || true)"
      if [[ -n "$package_prefix" ]]; then
        additions+=("$package_prefix/bin" "$package_prefix/sbin")
      fi
    done
  fi

  for candidate in "${additions[@]}"; do
    if [[ -d "$candidate" && ":$PATH:" != *":$candidate:"* ]]; then
      PATH="$candidate:$PATH"
    fi
  done
  export PATH
}

prompt_read() {
  local __var_name="$1"
  local __prompt="$2"
  local __value=""

  if [[ -r /dev/tty ]]; then
    read -r -p "$__prompt" __value </dev/tty
  else
    echo "[mac-install] interactive input requires a terminal." >&2
    echo "[mac-install] rerun from a terminal or pass --target (or TARGET=...)." >&2
    exit 2
  fi

  printf -v "$__var_name" '%s' "$__value"
}

install_with_brew() {
  local package="$1"
  local label="$2"

  if ! command -v brew >/dev/null 2>&1; then
    echo "[mac-install] $label is required, but Homebrew is not installed." >&2
    echo "[mac-install] install Homebrew or install $label manually, then run this script again." >&2
    exit 1
  fi

  echo "[mac-install] installing $label via Homebrew"
  brew install "$package"
  refresh_process_path
}

ensure_node_runtime() {
  refresh_process_path
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return
  fi

  install_with_brew "node" "Node.js"
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "[mac-install] Node.js was installed, but node/npm are still not on PATH." >&2
    exit 1
  fi
}

sqlite_supports_fts5() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    return 1
  fi

  sqlite3 :memory: "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" >/dev/null 2>&1
}

ensure_sqlite_runtime() {
  refresh_process_path
  if sqlite_supports_fts5; then
    return
  fi

  install_with_brew "sqlite" "sqlite3 with FTS5 support"
  if ! sqlite_supports_fts5; then
    echo "[mac-install] sqlite3 is installed, but this build does not support FTS5." >&2
    exit 1
  fi
}

resolve_macos_architecture() {
  local raw="$ARCHITECTURE"
  local normalized=""
  if [[ -z "$raw" ]]; then
    raw="$(uname -m)"
  fi

  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    arm64|aarch64)
      printf '%s\n' "arm64"
      ;;
    x64|x86_64|amd64)
      printf '%s\n' "x64"
      ;;
    *)
      echo "[mac-install] unsupported macOS architecture: $raw" >&2
      exit 1
      ;;
  esac
}

select_target() {
  local normalized=""
  if [[ -n "$TARGET" ]]; then
    SELECTED_TARGET="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')"
    return
  fi

  while true; do
    echo
    echo "Choose the coding agent to configure:"
    echo "  [1] Codex"
    echo "  [2] Codex App"
    echo "  [3] Claude Code"
    echo "  [4] Claude Desktop"
    echo "  [5] Cursor"
    echo
    prompt_read choice "> "
    normalized="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
      1|codex)
        SELECTED_TARGET="codex"
        return
        ;;
      2|codex-app|codex_app)
        SELECTED_TARGET="codex-app"
        return
        ;;
      3|claude|claude-code|claude_code)
        SELECTED_TARGET="claude-code"
        return
        ;;
      4|claude-desktop|claude_desktop|claude-desktop-app)
        SELECTED_TARGET="claude-desktop"
        return
        ;;
      5|cursor)
        SELECTED_TARGET="cursor"
        return
        ;;
      *)
        echo "[mac-install] unknown choice: $choice" >&2
        ;;
    esac
  done
}

target_token() {
  case "$1" in
    codex) printf '%s\n' "1" ;;
    codex-app|codex_app) printf '%s\n' "2" ;;
    claude-code|claude_code|claude) printf '%s\n' "3" ;;
    claude-desktop|claude_desktop|claude-desktop-app) printf '%s\n' "4" ;;
    cursor) printf '%s\n' "5" ;;
    *)
      echo "[mac-install] unknown target: $1" >&2
      exit 1
      ;;
  esac
}

bundle_candidate_urls() {
  local arch="$1"
  local base=""
  local alias=""
  local aliases=()

  case "$arch" in
    arm64)
      aliases=("arm64")
      ;;
    x64)
      aliases=("x64" "amd64")
      ;;
    *)
      echo "[mac-install] unsupported architecture alias set: $arch" >&2
      exit 1
      ;;
  esac

  if [[ -n "$RELEASE_TAG" ]]; then
    base="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG"
  else
    base="https://github.com/$GITHUB_REPO/releases/latest/download"
  fi

  for alias in "${aliases[@]}"; do
    printf '%s\n' \
      "$base/local-figma-port-macos-$alias.zip" \
      "$base/macos-$alias.zip" \
      "$base/$alias-macos.zip" \
      "$base/$alias.zip"
  done
}

download_file() {
  local destination="$1"
  shift
  local url=""
  local errors=()

  for url in "$@"; do
    echo "[mac-install] downloading bundle from $url"
    if curl -fsSL "$url" -o "$destination"; then
      return
    fi
    errors+=("$url")
  done

  echo "[mac-install] failed to download bundle." >&2
  for url in "${errors[@]}"; do
    echo "[mac-install] attempted: $url" >&2
  done
  exit 1
}

find_bundle_root() {
  local extract_dir="$1"
  local direct="$extract_dir/scripts/install/macos.sh"
  local child=""

  if [[ -f "$direct" ]]; then
    printf '%s\n' "$extract_dir"
    return
  fi

  while IFS= read -r -d '' child; do
    if [[ -f "$child/scripts/install/macos.sh" ]]; then
      printf '%s\n' "$child"
      return
    fi
  done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print0)

  echo "[mac-install] could not find a macOS installer inside the downloaded bundle." >&2
  exit 1
}

stop_existing_mcp() {
  local pid_file="$STATE_ROOT/run/mcp-server.pid"
  local old_pid=""

  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  old_pid="$(cat "$pid_file" || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    kill "$old_pid" >/dev/null 2>&1 || true
    echo "[mac-install] stopped previous MCP process pid=$old_pid"
  fi
  rm -f "$pid_file"
}

copy_bundle_contents() {
  local source_root="$1"
  local destination_root="$2"

  rm -rf "$destination_root"
  mkdir -p "$destination_root"
  cp -R "$source_root"/. "$destination_root"/
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[mac-install] this installer only supports macOS." >&2
  exit 1
fi

refresh_process_path
select_target
TARGET_TOKEN="$(target_token "$SELECTED_TARGET")"
RESOLVED_ARCH="$(resolve_macos_architecture)"
STATE_ROOT="$(normalize_path "$STATE_ROOT")"
WORKSPACE_ROOT="$(normalize_path "$WORKSPACE_ROOT")"
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"
if [[ -z "$INSTALL_ROOT" ]]; then
  INSTALL_ROOT="$STATE_ROOT/bundle/current"
else
  INSTALL_ROOT="$(normalize_path "$INSTALL_ROOT")"
fi

echo
echo "[mac-install] summary"
echo "  - target: $SELECTED_TARGET"
echo "  - architecture: $RESOLVED_ARCH"
echo "  - state root: $STATE_ROOT"
echo "  - install root: $INSTALL_ROOT"
if [[ "$SELECTED_TARGET" == "claude-code" || "$SELECTED_TARGET" == "cursor" ]]; then
  echo "  - workspace root: $WORKSPACE_ROOT"
fi

ensure_node_runtime
ensure_sqlite_runtime

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-figma-port-mac-install.XXXXXX")"
DOWNLOAD_ZIP="$TEMP_ROOT/bundle.zip"
EXTRACT_DIR="$TEMP_ROOT/extract"
mkdir -p "$EXTRACT_DIR"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ -n "$BUNDLE_URL" ]]; then
  download_file "$DOWNLOAD_ZIP" "$BUNDLE_URL"
else
  CANDIDATE_URLS=()
  while IFS= read -r candidate_url; do
    [[ -n "$candidate_url" ]] && CANDIDATE_URLS+=("$candidate_url")
  done < <(bundle_candidate_urls "$RESOLVED_ARCH")
  download_file "$DOWNLOAD_ZIP" "${CANDIDATE_URLS[@]}"
fi

ditto -x -k "$DOWNLOAD_ZIP" "$EXTRACT_DIR"
BUNDLE_ROOT="$(find_bundle_root "$EXTRACT_DIR")"

stop_existing_mcp
copy_bundle_contents "$BUNDLE_ROOT" "$INSTALL_ROOT"

INSTALL_SCRIPT="$INSTALL_ROOT/scripts/install/macos.sh"
INSTALL_ARGS=(
  --use-prebuilt
  --targets "$TARGET_TOKEN"
  --project-root "$INSTALL_ROOT"
  --state-dir "$STATE_ROOT"
)

if [[ "$SELECTED_TARGET" == "claude-code" || "$SELECTED_TARGET" == "cursor" ]]; then
  INSTALL_ARGS+=(--config-root "$WORKSPACE_ROOT")
fi

bash "$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}"

echo "[mac-install] plugin bundle: $INSTALL_ROOT/packages/figma-exporter-plugin"
MANIFEST_PATH="$INSTALL_ROOT/packages/figma-exporter-plugin/manifest.json"
BORDER="=============================================================================="
echo
echo "$BORDER"
echo "  Figma Desktop plugin manifest"
echo "$BORDER"
echo "  Import this file in Figma Desktop:"
echo
echo "  $MANIFEST_PATH"
echo
echo "  Figma: Plugins -> Development -> Import plugin from manifest..."
echo "$BORDER"
echo
if [[ "$SELECTED_TARGET" == "codex-app" ]]; then
  echo "[mac-install] note: restart Codex App to see the MCP server in Settings."
fi
echo "[mac-install] install complete"
