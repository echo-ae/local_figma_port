# design-importer CLI (Source of Truth)

## Command
`design-importer import`

## Flags
- `--input <DIR>`: directory containing plugin export artifacts
- `--sqlite <FILE>`: SQLite DB path to create or update
- `--ddl <FILE>`: SQL DDL file path
- `--write-chunks <DIR>`: output dir for normalized IR chunks (`.json.gz`)
- `--write-manifest <FILE>`: optional normalized manifest output path
- `--ui-kit-input <DIR>`: optional UI-kit export dir
- `--recompute-spacing <bool>`: default `true`
- `--incremental <bool>`: default `true`
- `--purge-missing <bool>`: default `false`
- `--log-level <level>`: `error|warn|info|debug`
- `--dry-run <bool>`: default `false`

## Exit codes
- `0` success
- `2` input validation error
- `3` sqlite or ddl error
- `4` partial import

## Persisted node metadata

Importer now preserves these node-level JSON columns in addition to existing layout/style fields:
- `resources_json`
- `inspection_hints_json`

These columns are used by MCP to expose:
- one-level traversal hints on `get_node()`
- node-linked previews/assets/images/UI-kit references
- bounded `resolve_instance()` context

## Example

```bash
design-importer import \
  --input /imports \
  --sqlite /data/design_store.sqlite \
  --ddl /app/sql/design_store.v1.sql \
  --write-chunks /data/chunks
```
