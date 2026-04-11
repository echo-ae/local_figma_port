#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DDL_PATH="$ROOT_DIR/sql/design_store.v1.compat.sql"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-figma-port-sqlite-compat.XXXXXX")"
DB_PATH="$TMP_DIR/design_store.sqlite"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "[sqlite-compat-test] missing required command: sqlite3" >&2
  exit 1
fi

if [[ ! -f "$DDL_PATH" ]]; then
  echo "[sqlite-compat-test] missing compatibility DDL: $DDL_PATH" >&2
  exit 1
fi

sqlite3 "$DB_PATH" < "$DDL_PATH"

has_fts_nodes="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_nodes' LIMIT 1;")"
has_compat_index="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_token_usages_pk_compat' LIMIT 1;")"

if [[ "$has_fts_nodes" != "1" ]]; then
  echo "[sqlite-compat-test] compatibility schema did not create fts_nodes" >&2
  exit 1
fi

if [[ "$has_compat_index" != "1" ]]; then
  echo "[sqlite-compat-test] compatibility schema did not create idx_token_usages_pk_compat" >&2
  exit 1
fi

echo "[sqlite-compat-test] compatibility schema applied successfully"
