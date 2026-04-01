# MCP Resources and Tools

MCP access model:
- Tools: primary interface for navigation, search, and bounded analysis.
- Resources: raw artifacts and snapshots.

Recommended workflow for coding agents:
- `resolve_target` -> if ambiguous, disambiguate -> `build_coverage_checklist` -> `get_node` / `layout_report` / `get_context_bundle`
- if `inspectionHints.hasDeeperDescendants=true`, continue traversal instead of guessing
- if `inspectionHints.requiresInstanceResolution=true`, call `resolve_instance`
- when the user describes a target in natural language, resolve the exact scope first and then build a checklist only for that chosen scope

## Resource URI Scheme

- `design://manifest`
  - project summary manifest
- `design://page/{pageId}`
  - normalized page chunk (gzip JSON)
  - page-scoped nodes and metadata only; tokens are intentionally not embedded
- `design://node/{nodeId}`
  - single normalized node JSON, including merged `resources` and `inspectionHints`
- `design://tokens`
  - raw tokens export
- `design://styles`
  - raw legacy styles export
- `design://assets`
  - JSON index of exported assets
- `design://asset/{assetId}`
  - one asset file by ID
- `design://images`
  - JSON index of bitmap image assets
- `design://image/{imageId}`
  - one bitmap image by ID
- `design://previews`
  - JSON index of available preview files
- `design://selections`
  - JSON index of named selection entities
- `design://selection-previews`
  - compact mapping of `selectionId -> previewUri` and `previewFileUri`
- `design://selection/{selectionId}`
  - one selection entity with references to node/page/preview, including `previewFileUri`
- `design://preview/{fileName}.png`
  - single preview PNG
- `design://preview-file/{fileName}.png`
  - JSON wrapper with absolute local preview path and ready-to-embed markdown image
  - controlled by `LOCAL_FIGMA_PORT_CHAT_PREVIEW_MODE=raw|checker`
  - `checker` only affects user-facing display rendering; `design://preview/...` stays the canonical clean PNG for agent analysis
  - if `markdownImageVerbatim` is present, clients should emit it literally instead of rebuilding markdown from `path`
- `design://uikit/manifest`
  - UI-kit import manifest
- `design://uikit/components`
  - UI-kit component snapshot
- `design://uikit/component/{componentId}`
  - one UI-kit component plus usage mappings
- `design://uikit/mappings`
  - node-to-UI-kit mapping table
- `design://uikit/tokens`
  - raw UI-kit tokens export
- `design://uikit/styles`
  - raw UI-kit styles export

## Tools

- Navigation: `list_pages`, `list_frames`, `get_node`, `resolve_instance`
- Search: `search_nodes`, `search_text`, `find_by_token`
- Analysis: `layout_report`
- Context pack: `get_context_bundle`
- Targeting: `resolve_target`, `build_coverage_checklist`

## Usage rules

- Prefer tools over full-resource reads.
- `get_node(includeChildren=true)` expands one level only. Use `inspectionHints.childrenExpandedDepth` and `inspectionHints.hasDeeperDescendants` to continue traversal deliberately.
- For selection-heavy workflows: `design://selection-previews` -> `design://selection/{selectionId}` -> `get_node(nodeId)`.
- Use `design://previews` first, then load only required `design://preview/...` files.
- If the client can render local images, prefer `design://preview-file/...` so the agent can embed the returned absolute path directly instead of decoding PNG bytes manually.
- Avoid whole-page reads unless truly needed.
- If you need design tokens, read `design://tokens` explicitly instead of assuming they are embedded in page chunks.
- Keep context bounded with `get_context_bundle(maxBytes)`.
- For mixed text, if `node.style.text.textRuns` has multiple segments, render ordered inline spans.
- `build_coverage_checklist` is on-demand. Do not precompute or assume whole-page checklist coverage at import time.
- `resolve_target` must not silently guess when multiple candidates remain plausible. Ambiguity should be returned to the caller.
- If the checklist warns that requested UI extends outside exported scope, implementation must stop instead of inventing missing panels or neighboring structures.
- Build the checklist for the exact scope you intend to implement:
  - `page`: whole imported page only
  - `selection`: exact exported selection only
  - `node`: exact subtree only
- If the desired scope changes, rebuild the checklist instead of widening the implementation informally from screenshots.
