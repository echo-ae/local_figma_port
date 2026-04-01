# design-importer

Rust CLI module that imports `plugin-export.v1` artifacts into:
- normalized page chunks (`design-ir.v1`, page-scoped and without embedded global tokens)
- SQLite design store
- optional UI-kit snapshot/mappings

## Entry Point

- `src/main.rs`
- command: `design-importer import`

## Responsibilities

- Validate input export against `schemas/plugin-export.v1.schema.json`
- Normalize nodes into Design IR shape (`schemas/design-ir.v1.schema.json`)
- Apply normalization logic from `docs/NORMALIZATION.md`
- Populate SQLite tables (`pages`, `nodes`, `edges`, `texts`, `token_usages`, FTS tables, raw token/style tables)
- Run incremental import via page hash keys in `meta` (`page_hash:{pageId}`)
- Ingest optional UI-kit export and build mappings (`uikit_*` tables)

## Input Modes

- Expanded export directory (`manifest.json` + chunks)
- Bundle-only export (`plugin-export.bundle.json`)

Bundle input is materialized under `--write-chunks`:
- `_import_source` for regular import
- `_uikit_source` for UI-kit import

## UI-kit Mapping

`uikit_component_usages.match_strategy` indicates how a mapping was produced:
- `direct_id` - exact `nodes.component_id == uikit_components.id`
- `name` - normalized name match (`INSTANCE` -> `COMPONENT_SET`)
- `alias` - alias rules (for common wrapper names such as `TextInput`/`Autocomplete`)

## Build

```bash
cd <repo-root>/packages/design-importer
cargo build
```

## Run

```bash
cd <repo-root>/packages/design-importer
cargo run -- import \
  --input <repo-root>/imports \
  --ui-kit-input <repo-root>/import-ui-kit \
  --sqlite /path/to/local-figma-port-state/data/design_store.sqlite \
  --ddl <repo-root>/sql/design_store.v1.sql \
  --write-chunks /path/to/local-figma-port-state/data/chunks
```

## Schema/DDL Dependencies

- `<repo-root>/schemas/plugin-export.v1.schema.json`
- `<repo-root>/schemas/design-ir.v1.schema.json`
- `<repo-root>/sql/design_store.v1.sql`
