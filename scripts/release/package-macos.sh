#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

TARGETS="all"
DO_BUILD=0
OUTPUT_DIR="$ROOT_DIR/out/release/macos"
STAGING_ROOT=""
KEEP_STAGING=0
BUNDLE_PREFIX="local-figma-port-macos"

usage() {
  cat <<EOF
usage: ./scripts/release/package-macos.sh [options]

options:
  --target LIST          package target architecture(s): arm64, x64, amd64, all (default: all)
  --build                build shared JS bundles and importer binaries before packaging
  --output-dir PATH      write ZIP archives to PATH (default: ./out/release/macos)
  --staging-root PATH    use PATH for staging instead of a temporary directory
  --keep-staging         keep the staging directory after packaging finishes
  --bundle-prefix NAME   archive prefix (default: local-figma-port-macos)
  --help                 show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|--targets)
      TARGETS="$2"
      shift 2
      ;;
    --build)
      DO_BUILD=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --staging-root)
      STAGING_ROOT="$2"
      shift 2
      ;;
    --keep-staging)
      KEEP_STAGING=1
      shift
      ;;
    --bundle-prefix)
      BUNDLE_PREFIX="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "[package-macos] unknown option: $1" >&2
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
    echo "[package-macos] missing required command: $cmd" >&2
    exit 1
  fi
}

add_unique_item() {
  local value="$1"
  local existing=""
  for existing in "${SELECTED_ARCHES[@]:-}"; do
    if [[ "$existing" == "$value" ]]; then
      return
    fi
  done
  SELECTED_ARCHES+=("$value")
}

normalize_arch() {
  local raw="$1"
  local normalized

  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    arm64|aarch64)
      printf '%s\n' "arm64"
      ;;
    x64|x86_64|amd64)
      printf '%s\n' "x64"
      ;;
    all)
      printf '%s\n' "all"
      ;;
    *)
      echo "[package-macos] unknown architecture token: $raw" >&2
      exit 2
      ;;
  esac
}

collect_arches() {
  local token=""
  local normalized=""

  SELECTED_ARCHES=()
  IFS=',' read -r -a raw_tokens <<< "$TARGETS"
  for token in "${raw_tokens[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -z "$token" ]] && continue
    normalized="$(normalize_arch "$token")"
    if [[ "$normalized" == "all" ]]; then
      add_unique_item "arm64"
      add_unique_item "x64"
    else
      add_unique_item "$normalized"
    fi
  done

  if [[ "${#SELECTED_ARCHES[@]}" -eq 0 ]]; then
    add_unique_item "arm64"
    add_unique_item "x64"
  fi
}

arch_to_rust_target() {
  case "$1" in
    arm64) printf '%s\n' "aarch64-apple-darwin" ;;
    x64) printf '%s\n' "x86_64-apple-darwin" ;;
    *)
      echo "[package-macos] unsupported package architecture: $1" >&2
      exit 1
      ;;
  esac
}

host_arch() {
  normalize_arch "$(uname -m)"
}

ensure_shared_runtime_artifacts() {
  local mcp_entry="$ROOT_DIR/packages/mcp-server/dist/mcp-stdio.js"
  local mcp_http_entry="$ROOT_DIR/packages/mcp-server/dist/index.js"
  local mcp_package="$ROOT_DIR/packages/mcp-server/package.json"
  local plugin_entry="$ROOT_DIR/packages/figma-exporter-plugin/dist/main.js"
  local plugin_manifest="$ROOT_DIR/packages/figma-exporter-plugin/manifest.json"
  local plugin_package="$ROOT_DIR/packages/figma-exporter-plugin/package.json"

  if [[ ! -f "$mcp_entry" ]]; then
    echo "[package-macos] missing MCP stdio entry: $mcp_entry" >&2
    exit 1
  fi
  if [[ ! -f "$mcp_http_entry" ]]; then
    echo "[package-macos] missing MCP HTTP entry: $mcp_http_entry" >&2
    exit 1
  fi
  if ! grep -Fq "IMPORTER_EXE" "$mcp_http_entry"; then
    echo "[package-macos] MCP HTTP entry does not support prebuilt importer execution yet: $mcp_http_entry" >&2
    echo "[package-macos] rebuild packages/mcp-server before packaging." >&2
    exit 1
  fi
  if [[ ! -f "$mcp_package" ]]; then
    echo "[package-macos] missing MCP package metadata: $mcp_package" >&2
    exit 1
  fi
  if [[ ! -f "$plugin_entry" ]]; then
    echo "[package-macos] missing Figma plugin bundle: $plugin_entry" >&2
    exit 1
  fi
  if [[ ! -f "$plugin_manifest" ]]; then
    echo "[package-macos] missing Figma plugin manifest: $plugin_manifest" >&2
    exit 1
  fi
  if [[ ! -f "$plugin_package" ]]; then
    echo "[package-macos] missing Figma plugin package metadata: $plugin_package" >&2
    exit 1
  fi
}

build_shared_runtime() {
  local mcp_dir="$ROOT_DIR/packages/mcp-server"
  local plugin_dir="$ROOT_DIR/packages/figma-exporter-plugin"

  require_cmd node
  require_cmd npm

  echo "[package-macos] building MCP runtime in $mcp_dir"
  (
    cd "$mcp_dir"
    if [[ -d node_modules ]]; then
      echo "[package-macos] reusing existing node_modules in $mcp_dir"
    else
      npm install --no-package-lock >/dev/null
    fi
    npm run build >/dev/null
  )

  echo "[package-macos] building Figma plugin runtime in $plugin_dir"
  (
    cd "$plugin_dir"
    if [[ -d node_modules ]]; then
      echo "[package-macos] reusing existing node_modules in $plugin_dir"
    else
      npm install --no-package-lock >/dev/null
    fi
    npm run build >/dev/null
  )

  ensure_shared_runtime_artifacts
}

build_importer_for_arch() {
  local arch="$1"
  local rust_target=""
  local manifest="$ROOT_DIR/packages/design-importer/Cargo.toml"

  require_cmd cargo
  require_cmd rustc
  rust_target="$(arch_to_rust_target "$arch")"

  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -Fxq "$rust_target"; then
      echo "[package-macos] missing Rust target: $rust_target" >&2
      echo "[package-macos] install it with: rustup target add $rust_target" >&2
      exit 1
    fi
  fi

  echo "[package-macos] building importer for $arch ($rust_target)"
  cargo build --manifest-path "$manifest" --release --target "$rust_target" >/dev/null
}

resolve_importer_source() {
  local arch="$1"
  local rust_target=""
  local current_host_arch=""
  local candidate=""

  rust_target="$(arch_to_rust_target "$arch")"
  current_host_arch="$(host_arch)"

  for candidate in \
    "$ROOT_DIR/packages/design-importer/target/$rust_target/release/design-importer" \
    "$ROOT_DIR/packages/design-importer/target/release/design-importer"
  do
    if [[ "$candidate" == "$ROOT_DIR/packages/design-importer/target/release/design-importer" && "$arch" != "$current_host_arch" ]]; then
      continue
    fi
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "[package-macos] missing importer binary for $arch." >&2
  echo "[package-macos] expected one of:" >&2
  echo "  - $ROOT_DIR/packages/design-importer/target/$rust_target/release/design-importer" >&2
  if [[ "$arch" == "$current_host_arch" ]]; then
    echo "  - $ROOT_DIR/packages/design-importer/target/release/design-importer" >&2
  fi
  exit 1
}

validate_importer_arch() {
  local arch="$1"
  local path="$2"
  local description=""

  require_cmd file
  description="$(file -b "$path")"

  case "$arch" in
    arm64)
      if [[ "$description" != *"arm64"* && "$description" != *"aarch64"* ]]; then
        echo "[package-macos] importer binary at $path is not arm64: $description" >&2
        exit 1
      fi
      ;;
    x64)
      if [[ "$description" != *"x86_64"* ]]; then
        echo "[package-macos] importer binary at $path is not x64: $description" >&2
        exit 1
      fi
      ;;
  esac
}

copy_relative_path() {
  local relative_path="$1"
  local source_path="$ROOT_DIR/$relative_path"
  local destination_path="$CURRENT_BUNDLE_ROOT/$relative_path"

  mkdir -p "$(dirname "$destination_path")"
  if [[ -d "$source_path" ]]; then
    cp -R "$source_path" "$destination_path"
  else
    cp "$source_path" "$destination_path"
  fi
}

stage_bundle() {
  local arch="$1"
  local importer_source="$2"
  local bundle_root="$STAGING_ROOT/$arch"
  local archive_path="$OUTPUT_DIR/$BUNDLE_PREFIX-$arch.zip"
  local relative_path=""
  local shared_paths=(
    "README.md"
    "LICENSE.md"
    "COMMERCIAL_LICENSE.md"
    "SECURITY.md"
    "SUPPORT.md"
    "SKILL.md"
    "schemas"
    "sql/design_store.v1.sql"
    "sql/design_store.v1.compat.sql"
    "scripts/install/macos.sh"
    "scripts/runtime/start.sh"
    "scripts/runtime/stop.sh"
    "scripts/uninstall/macos.sh"
    "scripts/verify/macos.sh"
    "scripts/lib/local_figma_port_state.sh"
    "packages/mcp-server/dist"
    "packages/mcp-server/package.json"
    "packages/figma-exporter-plugin/dist"
    "packages/figma-exporter-plugin/manifest.json"
    "packages/figma-exporter-plugin/package.json"
  )

  rm -rf "$bundle_root"
  mkdir -p "$bundle_root"
  CURRENT_BUNDLE_ROOT="$bundle_root"

  for relative_path in "${shared_paths[@]}"; do
    copy_relative_path "$relative_path"
  done

  mkdir -p "$bundle_root/packages/design-importer/target/release"
  cp "$importer_source" "$bundle_root/packages/design-importer/target/release/design-importer"
  chmod +x "$bundle_root/packages/design-importer/target/release/design-importer" \
    "$bundle_root/scripts/install/macos.sh" \
    "$bundle_root/scripts/runtime/start.sh" \
    "$bundle_root/scripts/runtime/stop.sh" \
    "$bundle_root/scripts/uninstall/macos.sh" \
    "$bundle_root/scripts/verify/macos.sh" || true

  find "$bundle_root" -name '.DS_Store' -delete

  mkdir -p "$OUTPUT_DIR"
  rm -f "$archive_path"
  (
    cd "$STAGING_ROOT"
    ditto -c -k --norsrc --keepParent "$arch" "$archive_path"
  )

  echo "[package-macos] wrote $archive_path"
}

ROOT_DIR="$(normalize_path "$ROOT_DIR")"
OUTPUT_DIR="$(normalize_path "$OUTPUT_DIR")"
if [[ -n "$STAGING_ROOT" ]]; then
  STAGING_ROOT="$(normalize_path "$STAGING_ROOT")"
else
  STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-figma-port-package-macos.XXXXXX")"
fi

cleanup() {
  if [[ "$KEEP_STAGING" -eq 0 ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

collect_arches

echo
echo "[package-macos] summary"
printf '  - targets: %s\n' "${SELECTED_ARCHES[*]}"
echo "  - output dir: $OUTPUT_DIR"
echo "  - staging root: $STAGING_ROOT"
if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "  - mode: build and package"
else
  echo "  - mode: package existing artifacts"
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  build_shared_runtime
else
  ensure_shared_runtime_artifacts
fi

for arch in "${SELECTED_ARCHES[@]}"; do
  if [[ "$DO_BUILD" -eq 1 ]]; then
    build_importer_for_arch "$arch"
  fi

  importer_source="$(resolve_importer_source "$arch")"
  validate_importer_arch "$arch" "$importer_source"
  stage_bundle "$arch" "$importer_source"
done

echo "[package-macos] packaging complete"
