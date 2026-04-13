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

Release bundles may also contain:

- `claude-desktop-extension-payload/`
  - prepared runtime payload used to assemble the `Claude Desktop` `.mcpb` extension bundle without rebuilding dependencies locally

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

Important areas:

- `install/*`
  - agent-specific installation flows
- `uninstall/*`
  - cleanup for agent registrations and generated artifacts
- `verify/*`
  - installation validation for each target environment
- `runtime/*`
  - local HTTP/MCP server start/stop helpers
- `lib/local_figma_port_state.sh`
  - canonical runtime state-path helpers
- `lib/claude_desktop_extension.sh`
  - shared Claude Desktop extension packaging helpers
- `release/package-macos.sh`
  - macOS release packaging, including the optional prebuilt Claude Desktop extension payload

### `data/`, `imports/`, `import-ui-kit/`

Local runtime state and import staging areas.

- `imports/`
  - design-element bundles
- `import-ui-kit/`
  - UI-kit bundles
- `data/`
  - SQLite database, normalized chunks, previews, and assets

These directories are part of the runtime architecture even when their contents are generated locally.
