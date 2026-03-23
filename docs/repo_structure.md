# Repository Structure

This file is a contributor navigation map. It is intentionally high-level and does not list every file in the repository.

## Top-Level Layout

```text
figma_port/
  .github/
    ISSUE_TEMPLATE/

  docs/
    README.md
    DATAFLOW.md
    IMPORTER_CLI.md
    MCP_RESOURCES.md
    NORMALIZATION.md
    repo_structure.md

  packages/
    figma-exporter-plugin/
    design-importer/
    mcp-server/

  schemas/
  scripts/
  sql/

  data/
  imports/
  import-ui-kit/

  README.md
  ARCHITECTURE.md
  SKILL.md
  SECURITY.md
```

## Key Areas

### `packages/figma-exporter-plugin`

Figma plugin source.

Important files:

- `src/main.ts`
  - plugin runtime entry point
- `src/ui.html`
  - plugin UI
- `src/export/*`
  - export logic, schema helpers, spacing/style extraction

### `packages/design-importer`

Rust importer and normalizer.

Important files:

- `src/main.rs`
  - CLI entry point and import pipeline

### `packages/mcp-server`

TypeScript MCP server.

Important files:

- `src/index.ts`
  - HTTP runtime and bundle ingestion
- `src/mcp-stdio.ts`
  - MCP stdio runtime
- `src/tools/*`
  - tool implementations
- `src/resources/handlers.ts`
  - resource URI resolution
- `src/schema/validate.ts`
  - schema validation

## Contract And Schema Files

### `schemas/`

Source-of-truth JSON schemas:

- `plugin-export.v1.schema.json`
- `plugin-export.nodes-chunk.v1.schema.json`
- `design-ir.v1.schema.json`
- `mcp-tools.v1.schema.json`

### `sql/`

- `design_store.v1.sql`
  - SQLite schema used by the importer and MCP server

## Operational Areas

### `scripts/`

Installers, start/stop helpers, and verification helpers.

### `data/`, `imports/`, `import-ui-kit/`

Local runtime state and import staging areas.

- `imports/`
  - design-element bundles
- `import-ui-kit/`
  - UI-kit bundles
- `data/`
  - SQLite database, normalized chunks, previews, and assets

These directories are part of the runtime architecture even when their contents are generated locally.
