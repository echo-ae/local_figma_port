# Normalization Rules (Source of Truth)

This document defines the normalization rules to convert `plugin-export.v1` artifacts into `design-ir.v1`
and populate `design_store.sqlite`. These rules are binding for `design-importer`.

## Goals
- LLM-friendly: compact, stable, explainable
- Separate explicit intent (Auto Layout, variable refs) from inferred computed spacing
- Avoid duplication: instances do not expand component bodies by default
- Stable navigation: deterministic `path` for FTS and UI
- Preserve enough node-linked metadata so agents can continue inspection without guessing

---

## A) Node Identity and Canonical Keys

### A1. Node ID
- Use Figma node ID as primary key (`nodes.id`).
- Preserve exactly as exported by plugin.

### A2. Component Canonical Key
- For `COMPONENT` definitions: `canonicalKey` is the node ID itself (optionally store Figma public key if exported later).
- For `INSTANCE`: store `component_id` as the master component node ID.

---

## B) Component / Instance Deduplication

### B1. Do NOT duplicate component subtree inside instances
- `INSTANCE` nodes must not copy children of the master component into their own `childrenIds`.
- `INSTANCE.childrenIds` should contain only:
  - Children that are actually present inside the instance
  - Explicit override nodes exported from the instance

### B2. Master component stays as definition
- `COMPONENT` (and `COMPONENT_SET`) remain as real nodes with their own children and layout.
- Instances reference masters via `component_id`.

### B3. Runtime resolution is explicit
- Default `get_node()` stays compact.
- MCP provides `resolve_instance(nodeId, depth, includeMaster, includeOverrides)` for bounded expansion.
- `inspectionHints.requiresInstanceResolution` and `inspectionHints.masterComponentId` must tell the agent when to use it.

---

## C) Styles, Variables, Tokens

### C1. Always keep both
- `styleRefs`: references (variables/styles)
- `style`: resolved payload (fills/strokes/effects/typography), normalized

### C2. Normalized color representation
- Color stored as `#RRGGBB`.
- Opacity stored separately as numeric `opacity`.
- Do not store `rgba(...)` strings.

### C3. Typography normalization
Store numeric px values:
- `fontFamily`, `fontWeight`, `fontSizePx`, `lineHeightPx`, `letterSpacingPx`
- `textCase`, `textDecoration`
- mixed-style text runs in `style.text.textRuns`

### C4. Box-style normalization
When available, preserve these visual ownership fields under `style.box`:
- `cornerRadius`
- `cornerRadii.tl/tr/br/bl`
- `clipsContent`
- `opacity`
- `blendMode`
- `strokeWeight`
- `strokeAlign`
- `dashPattern`

### C5. Token usages
Populate `token_usages` table:
- `token_key`: for example `var:color/surface/primary`
- `prop`: semantic property name, for example `fill`, `stroke`, `text.fill`, `stroke.weight`
- `mode`: optional, if variable modes are exported

---

## D) Layout Intent (Auto Layout)

### D1. layoutIntent is explicit intent
Write `layoutIntent` only for nodes that are Auto Layout containers:
- `mode`
- `wrap`
- `padding`
- `gap.primary`, `gap.wrap`
- `align.primary`, `align.counter`
- `sizing.primary`, `sizing.counter`

### D2. Preserve real Figma alignment and sizing
- Do not hardcode `align` or `sizing`.
- Map primary/counter-axis alignment from Figma container properties.
- Map container sizing from exported Figma sizing modes.

### D3. Gap AUTO
If the plugin cannot reliably export `AUTO` vs numeric:
- store numeric gap
- avoid inventing `AUTO`

---

## E) Node-Linked Resources

### E1. resources
Nodes may carry `resources` with links that help agents continue deterministically:
- `previewUri`
- `selectionIds`
- `assetIds`
- `imageIds`
- `uikitComponentIds`

### E2. Source precedence
- Preserve explicit `resources` exported by the plugin when present.
- MCP may merge in links derived from selection, asset, image, or UI-kit indexes.
- Derived links may add missing IDs, but should not overwrite an explicit `previewUri`.

---

## F) Inspection Hints

### F1. Traversal hints
`inspectionHints` should expose:
- `childrenExpandedDepth`
- `hasDeeperDescendants`

For `get_node(includeChildren=true)`, `childrenExpandedDepth` must be `1`, because only one child level is expanded.

### F2. State hints
When exported or derivable, preserve:
- `relatedStateNodeIds`
- `stateGroup`
- `state`

### F3. Instance hints
When node is an `INSTANCE`, preserve or derive:
- `requiresInstanceResolution`
- `masterComponentId`
- `overrideNodeIds`

---

## G) Computed Spacing

Computed spacing exists to make spacing and margin-like gaps clear to agents even outside Auto Layout.

### G1. contentBox
- If node has Auto Layout padding: `contentBox = bounds - padding`
- Else: `contentBox = bounds`

### G2. edgeGaps
For each child inside a container:
- `l = child.x - contentBox.x`
- `t = child.y - contentBox.y`
- `r = (contentBox.x + contentBox.w) - (child.x + child.w)`
- `b = (contentBox.y + contentBox.h) - (child.y + child.h)`

### G3. gapsBetween
For each container:
1. Determine axis from explicit layout intent when possible.
2. Otherwise infer axis from child distribution.
3. Sort children by axis start.
4. `gap = next.start - prev.end`
5. Clamp overlap to `0`.

### G4. Filtering rules
Exclude from computed spacing:
- invisible nodes
- zero-area nodes

### G5. Confidence scoring
- `3`: explicit Auto Layout and clear ordering
- `2`: non-auto layout but clear ordering
- `1`: some weak signal
- `0`: cannot infer reliably

---

## H) Path Construction for FTS

### H1. Deterministic path
`path = PageName / Ancestor1 / Ancestor2 / NodeName`

Normalization:
- trim whitespace
- collapse multiple spaces
- if name empty => `(unnamed:{type}:{id})`

### H2. Max length
If path length > 768 chars:
- truncate from the left
- preserve page name and final node segment if possible

---

## I) Compactness Pattern

Use `fig2json` only as a style reference for:
- compact payloads
- stable ordering
- low-noise fields

Do not parse `.fig` files and do not depend on fig2json code.
