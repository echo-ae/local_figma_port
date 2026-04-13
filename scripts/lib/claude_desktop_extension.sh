#!/usr/bin/env bash

lfp_cdext_pack_dir() {
  local src_dir="$1"
  local out_file="$2"
  local out_dir=""
  local out_name=""
  local out_abs=""

  mkdir -p "$(dirname "$out_file")"
  out_dir="$(cd "$(dirname "$out_file")" && pwd)"
  out_name="$(basename "$out_file")"
  out_abs="$out_dir/$out_name"

  if command -v zip >/dev/null 2>&1; then
    (
      cd "$src_dir"
      rm -f "$out_abs"
      zip -qr "$out_abs" .
    )
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$src_dir" "$out_abs" <<'PY'
import os
import sys
import zipfile

src_dir, out_file = sys.argv[1], sys.argv[2]
if os.path.exists(out_file):
    os.remove(out_file)

with zipfile.ZipFile(out_file, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for name in files:
            full_path = os.path.join(root, name)
            rel_path = os.path.relpath(full_path, src_dir)
            zf.write(full_path, rel_path)
PY
    return
  fi

  echo "[local-figma-port] missing required command: zip (or python3 for fallback packaging)" >&2
  return 1
}

lfp_cdext_install_runtime_deps() {
  local extension_root="$1"

  if ! command -v npm >/dev/null 2>&1; then
    echo "[local-figma-port] missing required command: npm" >&2
    return 1
  fi

  (
    cd "$extension_root"
    npm install --omit=dev --no-package-lock >/dev/null
  )
}

lfp_cdext_has_payload() {
  local payload_root="$1"

  [[ -f "$payload_root/package.json" ]] &&
    [[ -f "$payload_root/server/mcp-stdio.js" ]] &&
    [[ -f "$payload_root/schemas/mcp-tools.v1.schema.json" ]] &&
    [[ -d "$payload_root/node_modules" ]]
}

lfp_cdext_prepare_payload() {
  local mcp_dir="$1"
  local project_root="$2"
  local payload_root="$3"

  rm -rf "$payload_root"
  mkdir -p "$payload_root/server"
  cp -R "$mcp_dir/dist"/. "$payload_root/server/"
  cp -R "$project_root/schemas" "$payload_root/schemas"
  cp "$mcp_dir/package.json" "$payload_root/package.json"
  lfp_cdext_install_runtime_deps "$payload_root"
}

lfp_cdext_try_open_bundle() {
  local bundle_file="$1"
  local bundle_dir=""
  local bundle_abs=""

  bundle_dir="$(cd "$(dirname "$bundle_file")" && pwd)"
  bundle_abs="$bundle_dir/$(basename "$bundle_file")"

  if [[ ! -f "$bundle_abs" ]]; then
    return 1
  fi

  if command -v open >/dev/null 2>&1; then
    open "$bundle_abs" >/dev/null 2>&1
    return $?
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
      return 1
    fi
    xdg-open "$bundle_abs" >/dev/null 2>&1 &
    return 0
  fi

  return 1
}

lfp_cdext_read_file() {
  local bundle_file="$1"
  local member_path="$2"
  local bundle_dir=""
  local bundle_abs=""

  bundle_dir="$(cd "$(dirname "$bundle_file")" && pwd)"
  bundle_abs="$bundle_dir/$(basename "$bundle_file")"

  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$bundle_abs" "$member_path"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$bundle_abs" "$member_path" <<'PY'
import sys
import zipfile

bundle_file, member_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(bundle_file, "r") as zf:
    sys.stdout.buffer.write(zf.read(member_path))
PY
    return
  fi

  echo "[local-figma-port] missing required command: unzip (or python3 for fallback bundle inspection)" >&2
  return 1
}
