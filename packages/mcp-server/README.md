# mcp-server

TypeScript MCP server module for querying imported design data from SQLite and `data/chunks`.

## Runtime Modes

- HTTP server: `src/index.ts` -> `dist/index.js`
- MCP stdio server: `src/mcp-stdio.ts` -> `dist/mcp-stdio.js`

## Responsibilities

- Validate tool input/output against `schemas/mcp-tools.v1.schema.json`
- Serve base design resources:
  - `design://manifest`
  - `design://page/{pageId}`
  - `design://node/{nodeId}`
  - `design://tokens`
  - `design://styles`
  - `design://assets`
  - `design://asset/{assetId}`
  - `design://images`
  - `design://image/{imageId}`
  - `design://selections`
  - `design://selection-previews`
  - `design://selection/{selectionId}`
  - `design://previews`
  - `design://preview/{fileName}.png`
- Serve UI-kit resources:
  - `design://uikit/manifest`
  - `design://uikit/components`
  - `design://uikit/component/{componentId}`
  - `design://uikit/mappings`
  - `design://uikit/tokens`
  - `design://uikit/styles`
- Expose core tools:
  - `list_pages`, `list_frames`, `get_node`, `search_nodes`, `search_text`, `find_by_token`, `layout_report`, `get_context_bundle`, `resolve_instance`
- Accept local bundle ingestion endpoint:
  - `POST /import-bundle`
  - saves to `imports/` or `import-ui-kit/`
  - triggers `design-importer import` immediately

## Module Structure

- `src/db.ts` - SQLite query helpers (via `sqlite3` CLI)
- `src/resources/handlers.ts` - resource URI resolution
- `src/tools/*` - tool implementations
- `src/tools/node_payload.ts` - shared node hydration with traversal hints/resources
- `src/schema/validate.ts` - AJV validation layer
- `src/mcp-stdio.ts` - JSON-RPC MCP transport handler

## Build

```bash
cd <repo-root>/packages/mcp-server
# install dependencies with your preferred Node package manager
npm install --no-package-lock
npm run build
```

## Run (HTTP)

```bash
cd <repo-root>/packages/mcp-server
SQLITE_PATH=/path/to/local-figma-port-state/data/design_store.sqlite \
DATA_DIR=/path/to/local-figma-port-state/data \
MCP_PORT=7331 \
node dist/index.js
```

HTTP checks:
- `GET /healthz`
- `GET /tools`
- `GET /resource?uri=design://manifest`
- `POST /import-bundle`

### HTTP Endpoints

- `GET /healthz`
- `GET /tools`
- `GET /resource?uri=design://...`
- `POST /tools/{tool_name}`
- `POST /import-bundle`

## Run (MCP stdio)

```bash
cd <repo-root>/packages/mcp-server
SQLITE_PATH=/path/to/local-figma-port-state/data/design_store.sqlite \
DATA_DIR=/path/to/local-figma-port-state/data \
node dist/mcp-stdio.js
```
