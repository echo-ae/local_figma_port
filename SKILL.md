---
name: local-figma-port
description: Use when implementing UI from MCP local-figma-port where nested descendants, partial node reads, or ambiguous style ownership could cause the agent to stop early and guess instead of fully tracing the design source
short_description: Exact UI replication from the Local Figma Port MCP server
---

# Local Figma Port

## Overview

This skill is for tasks where `mcp local-figma-port` is the source of truth and the implementation must match it exactly.
Core rule: reproduce what the node data says, not what the layer name suggests.

**Core principle:** trace every visual decision to source data, implement only what was traced, and immediately loop back when any visual parameter remains ambiguous.

**Violating the letter of this process is violating the spirit of exact replication.**

## When Not To Use

Do not use this skill as the primary workflow when:

- the user explicitly wants an approximation, redesign, or adaptation instead of source parity;
- the task is not driven by `local-figma-port` data;
- the work is purely structural refactoring with no design-validation requirement.

## The Iron Law

```text
NO IMPLEMENTATION OR COMPLETION CLAIMS WITHOUT A CLOSED VISUAL TRACE
```

A visual trace is closed only when every relevant fill, stroke, radius, spacing, text style, state style, and asset in scope is either:

- traced to a specific `local-figma-port` node or descendant; or
- explicitly recorded as blocked after exhausting `style`, `styleRefs`, and relevant descendants.

If the visual trace is not closed, the task is not ready for implementation or completion.

## Target Checklist Gate

Before implementation starts, the agent MUST create a target-scoped checklist for the exact exported scope being implemented.

Mandatory chain:

1. `resolve_target`
2. if `ambiguous=true`, disambiguate with path, bounds, preview, visible text, or explicit user confirmation
3. `build_coverage_checklist`
4. inspect unresolved checklist items and keep them in `Coverage Ledger`
5. implement only after the checklist scope is understood and every required item is either traced or explicitly blocked

This chain is mandatory.

- If the target is still ambiguous, implementation is forbidden.
- If the checklist reports `outsideScopeWarning`, implementation is forbidden until the user accepts the narrower exported scope or a wider export is provided.
- If the checklist does not contain a region that exists only in the user's broader screenshot, report a scope mismatch instead of reconstructing that region from intuition.

## Implementation Mode Gate

Before implementation, apply this default mode policy:

- `presentational 1:1` — mandatory default. Recreate the exact currently exported node/scope as shown in MCP, without broadening it into a more universal, reusable, dynamic, or logic-driven component.
- `logicful` — follow-up mode allowed only when the user explicitly asks for runtime behavior, data flow, events, validation, API integration, or other application logic that cannot be inferred from the visual node alone.

Workflow policy:

- Start in `presentational 1:1` unless the user explicitly requested logic.
- Do not ask a startup question to classify the mode. Absence of an explicit logic request means the task stays `presentational 1:1`.
- For `presentational 1:1`, ask zero solution-shaping questions. Do not ask whether the component should be reusable, universal, generic, current-week-driven, contract-backed, static, or “just a mock”.
- The selected/exported node is the contract for `presentational 1:1`. Implement exactly what is shown, with no extra product interpretation and no “should I make this more flexible?” discussion.
- Do not enter `logicful` because it feels architecturally cleaner, more reusable, or more realistic. Enter it only because the user explicitly requested it.
- If the user later requests logic, treat that as a second phase layered on top of the already-implemented `presentational 1:1` result.
- If the task is `logicful`, ask only the minimum contract questions required to proceed: source of data, state/events, validation/business rules, and integration constraints.
- If logic would be useful but was not requested, finish the `presentational 1:1` implementation first and report logic hookup as an optional follow-up instead of switching modes implicitly.
- For `presentational 1:1`, further questions are allowed only for true blockers: ambiguous target selection, missing exported scope, missing source data, or an explicit user-requested deviation from source parity.

## Project Conventions Gate

Before writing code, inspect the project to learn how similar UI is normally built.

- Read the nearest relevant files/components to infer decomposition, naming, styling approach, primitives, state management, and test conventions.
- Match the project's decomposition and code style unless doing so would visibly break 1:1 parity with the traced node.
- Reuse local primitives only when they can preserve the traced geometry, spacing, styling, and states exactly.
- If the repo already answers how to decompose or style the code, do not ask the user for that guidance. Inspect the codebase and apply the local pattern yourself.

## Frontier Closure Protocol

Treat `local-figma-port` inspection as a closure problem, not a sampling problem.

**Critical tool behavior:** `get_node(nodeId, includeChildren=true)` returns the target node plus its immediate children only. It does **not** recursively expand the full subtree. If you stop after one `includeChildren` read, you are almost certainly missing deeper styling owners.

Before coding, create the scratchpad and keep updating these tracked structures inside it:

- `Open Frontier` — visually relevant node IDs that still need deeper inspection.
- `Coverage Ledger` — rendered containers/text/icons/states with their exact source node and any still-unresolved properties.
- `Fragment Checklist` — MCP-derived rendered slices/fragments with implementation and verification status.

Required traversal algorithm:

```text
frontier = [target node + visible state nodes]
while frontier is not empty:
  inspect node with get_node(includeChildren=true)
  record what this node proves in Coverage Ledger
  for each child or descendant candidate:
    if it can own visible fill/stroke/radius/text/layout/asset/state styling:
      add it to frontier unless already resolved
  remove current node from frontier only when no visually relevant property remains ambiguous
```

Rules for closing the frontier:

- A node is not resolved just because it has a useful parent payload. It is resolved only when the rendered slice it owns has known fill, stroke, radius, spacing, text, and asset provenance or an explicit blocker.
- Treat `children` and `childrenIds` as a queue for more reads, not proof that the subtree is fully understood.
- Re-open the frontier immediately if implementation or visual verification reveals any property you did not explicitly trace.
- If the frontier is non-empty, exploration is not done and completion is forbidden.

## Reasoning Continuity Protocol

Treat reasoning continuity as a required artifact, not a convenience.

Before implementation, create a per-task scratchpad in Codex local cache at:

```text
${CODEX_HOME:-~/.codex}/cache/local-figma-port/<task-slug>.md
```

Rules:

- Create the file immediately after identifying the exact target node(s) and before starting implementation.
- If a matching scratchpad already exists for the same task, resume from it instead of creating a parallel file.
- Keep it outside the repository. Do not create or maintain this scratchpad under the project tree.
- Keep the file in Markdown and update it after every meaningful inspection or implementation change.
- Store only durable working state: decisions, traced ownership, unresolved risks, implemented slices, and next actions. Do not use it as a dump of private free-form chain-of-thought.
- Sync the file before any long coding pass, before handing off, before asking the user for a blocker decision, and before any point where context compaction could break continuity.
- After context recovery or compaction, read this file first, reconcile it with the latest MCP data and repo state, and then continue.

The scratchpad MUST contain these sections:

```markdown
# <task title>

## Scope
- user request
- target node ids / paths
- files being changed

## Current Direction
- current implementation hypothesis
- why this direction is currently believed to be correct

## Open Frontier
- [ ] <node id / path> - reason it still needs inspection

## Coverage Ledger
- slice: <rendered slice name>
  - source: <node id / path>
  - resolved: <fills / strokes / radius / text / spacing / assets / states>
  - unresolved: <list or none>
  - next: <next node to inspect or blocker>

## Fragment Checklist
- [ ] <MCP-derived fragment / rendered slice>
- [x] <implemented and verified fragment / rendered slice>
- [~] <implemented but not yet verified fragment / rendered slice>
- [-] <blocked fragment / rendered slice>

## Confirmed Decisions
- <decision with source node or file reference>

## Blockers
- <exact missing property, checked node chain, and why blocked>

## Next Step
- next MCP read, next verification step, or next code edit
```

`Fragment Checklist` rules:

- Build it from the rendered slices, containers, text blocks, icons, and state variants proven by MCP inspection.
- Mirror the practical implementation checklist that falls out of the MCP trace. Do not replace it with vague engineering tasks like "finish component" or "polish styling".
- Mark a fragment `[x]` only after it is both implemented and verified against the traced source.
- Mark a fragment `[~]` if code exists but verification is still pending.
- Do not return completed fragments to `[ ]` unless new evidence shows drift, dependency fallout, or a wrong source mapping.
- If a fragment is blocked, mark it `[-]` and record the exact blocker in `Blockers`.
- Keep `Fragment Checklist` and `Coverage Ledger` in sync. If one says a slice is complete and the other still has unresolved properties, the scratchpad is stale and must be fixed before continuing.

## Service Tool Coverage

Use the narrowest service capability that resolves the ambiguity in front of you:

- If you already have the exact node ID, start with `get_node`.
- If you know the page or frame but not the exact node, use `list_pages` -> `list_frames` -> `get_node`.
- If you only know a layer label, path fragment, or component name, use `search_nodes`.
- If you only know visible copy, use `search_text`.
- If repeated token ownership is unclear, use `find_by_token` before inventing a local token mapping.
- If several related nodes must be reasoned about together, use `get_context_bundle(maxBytes=...)` after enumerating the exact IDs you still need.
- If the client exposes MCP resources, read the minimum required `design://selection/...`, `design://preview/...`, `design://preview-file/...`, `design://asset/...`, `design://image/...`, or `design://uikit/...` resources instead of guessing or loading a full page chunk.
- For icons, logos, chevrons, and other design marks, allowed source inputs are limited to `local-figma-port` node data, `design://asset/...`, `design://image/...`, `design://preview...` resources, and already-existing exact local repo assets. Do not fetch icon geometry from the internet or other external sources.

Do not read an entire page or guess from a nearby frame when a narrower tool or resource can resolve the question directly.

## Non-Negotiable Rules

- Do not infer behavior, structure, or component choice from layer names.
- Treat names like `Calendar Popover`, `Card`, `Modal`, `Button`, `List`, `Table` as labels only.
- Build from node data: `bounds`, `layoutIntent`, `style`, `styleRefs`, `computed`, and child nodes.
- For pure `presentational 1:1` work, the currently selected/exported node is the scope. Do not reinterpret it into a more generic or logic-bearing component unless the user explicitly asked for that.
- Do not infer a request for runtime logic, data contracts, or reusability from the component type. Unless the user explicitly asked for logic, finish the exact visual implementation first.
- `get_node(..., includeChildren=true)` gives you one level, not full depth. You MUST enqueue relevant children for additional `get_node` passes until the `Open Frontier` is empty.
- For any visual parameter that can plausibly live below the current node, you MUST keep drilling down until you either find the concrete value in `style`, `styleRefs`, or a renderable descendant, or you can explicitly state that the MCP payload does not expose it.
- You MUST keep reading `local-figma-port` until all visually relevant parameters in the task scope are accounted for. Do not stop after finding “enough to implement”; stop only when every relevant fill/stroke/radius/effect/spacing/text/icon/state value has either a traced source in `local-figma-port` or a written blocker that names the exact missing parameter and node chain you checked.
- Match sizes and positioning exactly.
- Match fonts exactly: family, size, weight, line-height, letter-spacing, text case, decoration, alignment.
- Match all block parameters exactly: fill, stroke, effects, opacity, radius, padding, gap, sizing mode, alignment, overflow behavior.
- If a property is not explicitly visible in the first node payload, inspect the relevant child nodes and style-linked containers before deciding.
- Do not stop at the first parent node that “looks sufficient”. Continue through nested children and style-linked nodes until border, radius, padding, spacing, fills, strokes, and text styles are either confirmed or explicitly marked unavailable from MCP.
- Previews, screenshots, exported frame images, and `preview-file` renders are analysis aids only. They MUST NOT be shipped as a substitute for DOM/CSS implementation of the UI.
- You MUST NOT use `img`, `next/image`, CSS `background-image`, canvas, or any other bitmap embedding to fake a completed UI region that should be real markup and styles.
- “Static visual only”, “faster”, or “close enough for now” are not valid reasons to ship a screenshot of the design instead of implementing the structure.
- If an icon is not present in the project, extract or recreate it from `local-figma-port`. Do not substitute a “close enough” local icon.
- A visible icon is not closed just because you know its bounds, fill, or approximate silhouette. Icon geometry is closed only when you have exact asset-level/vector-level proof or a recorded `placeholder-blocked` unresolved-icon entry after evidence exhaustion.
- You MUST NOT search the web, browse icon libraries, copy from external repos, or otherwise leave the repo/MCP evidence boundary to obtain icon geometry for a `local-figma-port` task.
- Do not stop at approximate parity. Finish only after the remaining differences are enumerated and resolved or explicitly reported as blocked by missing source data.
- If a container visibly has a border, corner radius, inset highlight, or rounded selected state in the design, you MUST treat missing implementation of that property as a blocking defect, not a follow-up polish item.
- If you find a border for a visual container, you MUST immediately verify and implement that same container's `border-radius` in the same pass; it is not acceptable to transfer the border and leave the radius for later.
- You MUST NOT mark the task complete until you can account for every visually obvious border and radius in the rendered result, even if MCP exposed the geometry more clearly than the styling.
- If MCP data seems incomplete but the rendered design clearly shows a border/radius, you MUST explicitly record that ambiguity, inspect deeper descendants/styleRefs, and implement the visible result or report the exact blocker. Silence is failure.

## The Replication Loop

You MUST work in this loop:

1. Inspect source nodes
2. Build or update the container audit
3. Implement the smallest faithful slice
4. Verify against source data and rendered result
5. If anything is missing, ambiguous, or drifting, return to step 1 immediately

Do not treat this skill as a one-pass extraction. It is a verification loop.

## Required Workflow

### 0. Locate The Exact Target First

Before the frontier walk starts:

- Resolve the exact target with `resolve_target` whenever the user describes it in natural language or when multiple plausible scopes may exist.
- Default to `presentational 1:1` unless the user explicitly asked for logicful behavior or external integration.
- Do not ask a startup question to classify the task. If the request does not explicitly ask for logic, stay in `presentational 1:1`.
- If the user already provided an exact ID, verify that it still matches the requested visible scope.
- If multiple candidate nodes exist, disambiguate by path, bounds, preview, or visible text. Do not choose by name alone.
- If the design includes visible states or alternate slices, add those node IDs to the initial `Open Frontier` up front instead of hoping they appear later.
- If preview or selection resources exist, fetch only the specific preview(s) needed for visual confirmation.
- If `design://preview-file/...` exists, prefer it over raw `design://preview/...` bytes when the client can render local images.
- Treat `design://preview/...` as the clean source screenshot for analysis. Treat `design://preview-file/...` and `previewMarkdownImage` as user-facing render variants that may add presentation aids such as checkerboard transparency background when the MCP server is configured that way.
- Use preview resources to inspect and communicate the target only. Do not turn preview output into shipped product UI.
- Compare the exported preview and root bounds against the user-visible target before implementing. If the preview omits a panel, state, footer, legend row, sidebar, or any other visibly required region, treat that as a selection-scope mismatch and stop.
- If the exported selection is narrower or shorter than the target UI the user asked for, report that the selection is incomplete. Do not reconstruct missing panels, tables, cards, or slot lists from product intuition.
- Build `build_coverage_checklist` immediately after the target is resolved and before implementation begins.
- If the checklist is for a `selection`, treat it as exact exported scope, not a hint about surrounding UI.
- If the checklist is for a `node`, implement only that subtree unless the target is explicitly widened and a wider checklist is rebuilt.
- If the checklist is for a `page`, keep implementation within that page and still resolve any ambiguous sub-fragment before coding it.
- If the resource returns `markdownImageVerbatim` or `previewMarkdownImage`, emit that string exactly as-is. Do not URL-encode spaces, normalize the path, or reconstruct markdown from `path`.
- If the user asks what the skill/server sees, what is currently selected, or asks for visual confirmation, show the latest available preview image immediately in the response instead of only describing it in text.
- When both selection metadata and a preview image are available, include the preview image first and the textual identifiers (`selectionId`, `nodeId`, `pageId`) second.

You must not start implementation while the target node identity is still ambiguous.
You must not start implementation before a target-scoped checklist exists.

### 1. Read The Design Structure First

Before writing code:

- Inspect nearby project files that solve analogous UI so you can match the repo's decomposition, naming, styling system, and code style without asking the user.
- Load the target node with `get_node(nodeId, includeChildren=true)` and seed `Open Frontier` from its `children` / `childrenIds`.
- Open or initialize the scratchpad and seed its `Open Frontier`, `Coverage Ledger`, and `Fragment Checklist` from the first MCP read.
- Inspect the immediate children, then explicitly recurse by re-running `get_node(..., includeChildren=true)` for every child that could own visible structure or styling. One `includeChildren` pass is never enough for a non-trivial subtree.
- For text nodes, inspect the full text style payload.
- For shape/icon/instance nodes, inspect nested children until the renderable geometry is clear.
- For icon/logo/chevron marks, do not stop at outer bounds or first visible fill. Keep traversing until exact geometry provenance is identified at asset level, vector-child level, or a `placeholder-blocked` unresolved-icon path.
- For containers, keep descending until visual ownership is clear for border, corner radius, fill, spacing, and selection states. If a selected state is rendered by a nested rectangle or instance child, that child is the source of truth, not the parent label.
- Use `get_context_bundle` when multiple related nodes are needed together.
- Use `layout_report` to confirm spacing and container intent when the structure is ambiguous.

Do not start implementation from a screenshot-level assumption.
Do not stop because the first payload seems “close enough”.
Do not start implementation while any visually relevant container still lacks a known owner chain for fill, stroke, radius, or state styling.
Do not start implementation while any required checklist item is still open without an explicit blocker note.

You must not consider the exploration phase complete until:

- `Open Frontier` is empty or every remaining entry is explicitly blocked with the exact node chain and missing property;
- every visually relevant container has an identified styling owner chain;
- every interactive state visible in the design has been enumerated;
- every visible border/radius/fill/stroke has either a traced source or an explicit unresolved note.

Return to this step when:

- implementation reveals a missing style decision;
- a border is found but the paired radius is not yet verified;
- the rendered result shows a visible property you did not trace;
- any state looks “almost right” but is not source-proven.

### 2. Translate Node Data Into An Implementation Spec

Write down, explicitly:

- Root container size and position rules.
- All child sizes.
- All gaps, paddings, and alignment rules.
- Text styles for every unique text node.
- Fill/stroke/effect rules for every visual container.
- Corner radius rules.
- Which nodes are merely labels and which are actual shapes/text.

For every border radius, border, fill, or selected-state background you implement, you must be able to answer one of two things:

- which exact node exposed that value; or
- that you exhaustively checked the relevant `style`, `styleRefs`, and descendants and MCP did not expose it.

For every border you implement, you must also answer the same question for the paired `border-radius` of that exact visual container. Border without verified radius is incomplete.

Before implementation, create a mini audit for every visual container in scope using this exact structure:

- container name
- source node id
- fill owner
- stroke owner
- radius owner
- overflow/clipping owner
- unresolved visual risk

If any of `fill owner`, `stroke owner`, or `radius owner` is unknown for a visibly styled container, implementation must stop until it is resolved or explicitly reported as blocked.

This audit is a gate, not a note. If the audit cannot explain a visible container, implementation must loop back to inspection.

Also create a `Coverage Ledger` entry for each rendered slice in scope using this exact structure:

- rendered slice name
- source node id/path
- resolved properties
- unresolved properties
- next node to inspect or blocker

If `unresolved properties` is non-empty, that slice keeps its node in `Open Frontier` and implementation must not treat it as complete.

Also create and maintain a `Fragment Checklist` entry for each rendered slice or fragment in scope:

- fragment name
- source node id/path
- implementation status: `[ ]`, `[~]`, `[x]`, or `[-]`
- verification note or blocker

If a fragment is still `[ ]`, `[~]`, or `[-]`, it is not safely forgotten. Keep it in the scratchpad until it is either `[x]` or explicitly accepted by the user as blocked/deferred.

For every visible icon-like fragment, also record icon closure proof using this exact structure:

- icon name
- source node id/path
- proof type: `exact asset`, `exact vector children`, or `placeholder-blocked`
- implementation form: reused exact local asset / extracted asset / recreated SVG/vector / empty placeholder box
- forbidden approximations checked: `clip-path`, CSS silhouette, border triangle, pseudo-element shape, library substitute
- verification status

If `proof type` is not `exact asset`, `exact vector children`, or `placeholder-blocked`, that icon is unresolved and must stay open in `Open Frontier`.

If `proof type` is `placeholder-blocked`, the icon is still unresolved for parity, but traversal for that icon may stop only after evidence exhaustion is recorded and an `Unresolved Icons` entry exists for the final report.

If the design says:

- root `288x196`
- header `288x36`
- content `288x160`
- cell `41.14285659790039x32`

then implementation must preserve those numbers unless the runtime environment forces a deterministic equivalent. “Close enough” is failure.

### 3. Ignore Layer Names As Behavior

Examples:

- `Calendar Popover` does not mean “use a calendar library and a popover component”.
- `Button` does not mean “use the project button component”.
- `Table` does not mean “use a semantic table”.

The only valid question is: what does the node tree actually render?

Choose implementation primitives only after geometry and styling are understood.

### 4. Recreate Assets From Design When Needed

If the design contains icons or shapes not already available in the repo:

- inspect the relevant node/instance children;
- prefer original exported `design://asset/{assetId}` or `design://image/{imageId}` resources when the client exposes them;
- reproduce the vector or shape in code/assets;
- keep proportions, stroke/fill, and bounds aligned with the source.

Do not replace missing design assets with generic chevrons, calendar icons, or library icons.
Do not use exported previews, selection screenshots, or frame PNGs as if they were those assets.
Only ship image resources when the image itself is actual product content, such as an icon, illustration, logo, or photo that belongs in the UI. A screenshot of a UI region is not product content.
Do not fetch replacement icons, SVGs, or logos from the internet, external design systems, npm packages, GitHub, or search engines.

If preview resources exist, use them to confirm the final rendered silhouette before declaring an asset “close enough”.

## 4.25. Icon Closure Protocol

Treat every visible icon, logo mark, chevron, caret, glyph, or emblem as a geometry-proof problem, not a silhouette problem.

You may close an icon only when one of these is true:

- you have the exact exported asset and are using that exact asset;
- you traced exact vector geometry through the relevant node/child chain and recreated that geometry faithfully;
- you exhausted relevant MCP evidence, rendered an empty placeholder box matching the icon bounds, and recorded an explicit `Unresolved Icons` entry.

These do **not** close an icon:

- bounds only;
- fill color only;
- preview silhouette only;
- “it visually looks close enough”;
- first-level `includeChildren=true` data without deeper vector/asset proof.

Forbidden icon approximations unless MCP proves that exact method is actually the source geometry:

- CSS `clip-path`
- border-triangle tricks
- pseudo-element silhouettes
- ad hoc div geometry
- icon-library substitute
- hand-drawn SVG/path made only from preview eyeballing

Forbidden icon sources for `local-figma-port` work:

- web search / search engines
- external icon sites or libraries
- copied SVGs from external repos or docs
- npm/package icons used as stand-ins
- any geometry source that is not the repo itself or `local-figma-port` evidence

If the exact icon geometry is still not proven:

- keep the icon node in `Open Frontier`;
- mark the icon fragment as unresolved in `Coverage Ledger`;
- do not guess the missing geometry;
- continue implementing the rest of the UI;
- once evidence is exhausted, replace the icon with an empty placeholder box that preserves the intended bounds and layout slot;
- add the icon to `Unresolved Icons` in the self-review and final report.

Placeholder mode is allowed only for unresolved icon geometry after evidence exhaustion. It is not allowed for text, containers, charts, screenshots, or any other non-icon UI fragment.

### 4.5. Use UI-Kit Evidence Carefully

If this service exposes `design://uikit/...` resources or imported UI-kit mappings:

- inspect them after the visual trace is already grounded in node data;
- use them to find an exact reusable primitive or token mapping;
- reject the mapped component if its real rendered structure does not match your traced geometry, fill, stroke, radius, or text rules.

UI-kit mappings are supporting evidence, not permission to skip the node walk.

### 5. Implement With Minimal Interpretation

- Prefer raw layout and styling over abstraction.
- Do not introduce extra wrappers that change spacing or radius behavior unless they are necessary.
- Do not normalize sizes to the nearest “clean” token.
- Do not replace exact typography with nearby theme presets if the preset does not match exactly.
- Do not stop after implementing only geometry and text if the design also contains visible container styling or state styling.
- Update the scratchpad immediately after each implemented fragment so the current file reflects what is already done, what is only partially done, and what remains.
- If a contemplated implementation path would rasterize a UI fragment from MCP output instead of building it as DOM/CSS, stop and return to inspection or report a blocker.

If the design requires a one-off style, implement the one-off style.

If implementation forces a visual decision that is not already covered by the audit, stop coding and return to step 1.

### 6. Verify Against Source Data

Before claiming completion, check:

- dimensions match the node data;
- spacing matches `layoutIntent`/`computed`;
- text styles match every inspected text node;
- corner radii and borders are present where the design indicates them;
- icons match the design asset, not a substitute, unless they are explicitly listed in `Unresolved Icons` as placeholder-blocked;
- every visible icon has icon-closure proof recorded as `exact asset`, `exact vector children`, or `placeholder-blocked`;
- any remaining mismatch is explicitly listed.
- every visually meaningful container has been checked against the mini audit from step 2;
- no “I assumed border-radius was 0 / default / inherited” decisions remain;
- selected, hover, focus, and disabled states were checked for their own radii/fills/strokes, not just the default state.

Final visual closure is a loop, not a note:

- Re-open the latest source preview or screenshot for the exact exported target before finishing.
- Compare the current implementation against that source for placement, sizing, spacing, hierarchy, text, colors, radii, borders, shadows, icons, legends, scrollbars, CTA, and states.
- If a material visible mismatch is inside the exported scope and MCP exposes enough evidence to resolve it, fix it immediately instead of merely reporting it.
- After each fix, compare again against the same source preview or screenshot.
- Repeat `compare -> fix -> compare again` until no material visual drift remains or you hit a real blocker.
- A real blocker means either `outsideScopeWarning` / scope mismatch or missing MCP evidence after the required deeper inspection. It does not mean “good enough”.

You must include a short self-review before finishing:

- `Confirmed:` [list of containers whose border/radius/fill/stroke were verified]
- `Blocked:` [list of containers still ambiguous, or `none`]
- `Open Frontier:` [remaining node ids, or `none`]
- `States Checked:` [default/selected/hover/focus/disabled containers verified]
- `Unresolved Icons:` [icon name + node id/path + placeholder size, or `none`]
- `Remaining Drift:` [anything still visually different, or `none`]
- `Scratchpad:` [path to `${CODEX_HOME:-~/.codex}/cache/local-figma-port/<task-slug>.md` and confirmation that `Fragment Checklist` is current]

List placeholder-backed missing icons under `Unresolved Icons`, not under `Blocked` or `Remaining Drift`, unless there is additional drift beyond the placeholder itself.

If this self-review is missing, the task is not complete.

## Stop Conditions

STOP and return to inspection instead of pushing forward when:

- you are about to say “close enough”;
- you copied a border but not the paired radius;
- you used a nearby theme token because the exact source was inconvenient;
- you are inferring behavior from a layer name;
- you are relying on memory of the design instead of a current node payload;
- you notice a visible mismatch after implementation;
- a property looks inherited or default but was not actually traced;
- the scratchpad no longer reflects the latest `Open Frontier`, `Coverage Ledger`, or implemented fragments.

STOP and report a blocker when:

- the needed visual value is still unavailable after checking `style`, `styleRefs`, relevant descendants, and related state nodes;
- an icon/logo/chevron would require going outside `local-figma-port` or the local repo to obtain geometry;
- the user asks for a deliberate deviation from source parity.
- the remaining visible mismatch is outside the exported scope and would require inventing UI that is not present in the current MCP data.
- the only remaining way forward would be to ship a screenshot or preview image instead of real markup/styling.

If exact icon geometry cannot be reconstructed from available design data:

- do not approximate it;
- do not leave the repo/MCP evidence boundary;
- continue the rest of the implementation;
- render an empty placeholder box in that icon slot;
- report that icon in `Unresolved Icons` instead of treating the whole task as stopped.

Completion hard gate:

- If any item in `Blocked` or `Remaining Drift` is non-empty and was not explicitly accepted by the user, the task is not complete.
- If `Open Frontier` is not `none`, the task is not complete.
- If any required checklist item is still `open`, the task is not complete.
- If the checklist reported `outsideScopeWarning` and the user did not explicitly accept the narrower exported scope, the task is not complete.
- If a region is present in the implementation but absent from the checklist and absent from exported source nodes or previews, the task is not complete.
- If there is still any visually relevant parameter that was not fully traced through `local-figma-port` and was not explicitly documented as blocked, the task is not complete.
- If the rendered result still differs in an obvious visible way from the design, the task is not complete even if the underlying logic and dimensions are correct.
- If you noticed a visible mismatch during final comparison and did not attempt an in-scope fix plus a second comparison pass, the task is not complete.
- If the scratchpad file is missing, stale, or its `Fragment Checklist` does not match the real implementation status, the task is not complete.
- If any UI region that should be markup/styling was implemented as a screenshot, exported preview, or frame bitmap, the task is not complete.
- If any visible icon was implemented from silhouette approximation without exact asset/vector proof or a `placeholder-blocked` record, the task is not complete.
- If any visible icon geometry was taken from the internet or another external source instead of `local-figma-port` evidence or an exact local repo asset, the task is not complete.
- If any visible icon lacks exact proof and also lacks an empty placeholder box matching its intended bounds plus an `Unresolved Icons` entry, the task is not complete.
- If `Unresolved Icons` is non-empty and the final report does not list each placeholder-backed icon explicitly, the task is not complete.

## Design Local Reading Checklist

For every target node, verify these fields before implementation:

- `type`
- `bounds`
- `layoutIntent`
- `style.fills`
- `style.strokes`
- `style.effects`
- `style.text`
- `styleRefs`
- `computed.contentBox`
- `computed.gapsBetween`
- `children`

If the node is an `INSTANCE`, inspect its children before treating it as opaque.

## Common Failure Modes

### Failure: inventing semantics from the name

Wrong:

- Layer says `Calendar Popover`
- Agent uses a calendar package and a generic popover

Right:

- Inspect the node tree first
- Recreate the actual rendered structure

### Failure: replacing typography with a nearby token

Wrong:

- “`typography.Text` is close enough”

Right:

- Match `Roboto`, `14`, `400`, `20px`, `0%`, original text case if that is what the node says

### Failure: dropping radii or borders because the first payload is incomplete

Wrong:

- Corner radius not obvious on the parent, so set `border-radius: 0`
- Corner radius not obvious on the parent, so guess from a screenshot
- Border seems visually obvious, so add it without tracing where the value actually lives
- Border transferred from the source, but the same container's radius was not checked and implemented immediately

Right:

- Inspect the inner styled container and `styleRefs`
- Reproduce the visible result, not only the first parsed field
- When a border is present, trace and implement the same container's radius before considering that container complete
- Keep descending through nested children until the actual visual owner is found or explicitly conclude that MCP does not expose the value

### Failure: stopping after the first `includeChildren` pass

Wrong:

- Read `get_node(target, includeChildren=true)` once and assume the subtree is covered
- Inspect only the children shown inline and invent deeper styling from the screenshot

Right:

- Treat the returned `children` / `childrenIds` as the next inspection frontier
- Run additional `get_node(..., includeChildren=true)` calls until `Open Frontier` is empty or explicitly blocked
- Keep `Coverage Ledger` entries for unresolved descendants instead of silently guessing

### Failure: treating visual polish as optional after geometry is correct

Wrong:

- “Sizes and text already match, border radius can be added later”
- “The main logic works, so missing border is acceptable”

Right:

- Treat missing border/radius/fill parity as a correctness bug
- Refuse to close the task until visible container styling is verified and implemented

### Failure: asking unnecessary scoping questions for a pure 1:1 task

Wrong:

- “Do you want the exact current week from the exported frame, or a more universal calendar component?”
- “Should I keep this static, or make it reusable and dynamic?”
- “Do you want just the markup, or should I generalize it a bit?”

Right:

- Default to `presentational 1:1` and implement the exact selected/exported node
- Do not ask any startup mode-classification question unless the user explicitly asked for logic and real contract work must begin
- Derive decomposition and code style from neighboring project files instead of asking the user to design the engineering approach

### Failure: substituting icons from the repo

Wrong:

- Use an existing chevron because it is available

Right:

- Recreate the icon from `local-figma-port` if the project does not already contain the exact asset

### Failure: closing an icon from bounds and silhouette instead of exact geometry

Wrong:

- Inspect `Logo Icon`, see bounds/fill and a rough preview silhouette, then stop traversal
- Build the mark with `clip-path`, CSS shape tricks, or an eyeballed SVG
- Treat the icon as complete even though exact vector/asset proof was never closed

Right:

- Keep the icon node in `Open Frontier` until exact asset or exact vector-child provenance is found
- Use the exact exported asset when available; otherwise trace and recreate exact vector geometry
- If exact geometry still cannot be proven, ship an empty placeholder box that preserves the intended bounds and list the icon in `Unresolved Icons`

### Failure: going to the internet for icon geometry

Wrong:

- Search the web, GitHub, npm, or icon libraries for a logo/chevron/icon that looks similar
- Paste an external SVG because MCP traversal feels too slow or the local geometry is incomplete

Right:

- Stay inside `local-figma-port` node data, `design://asset|image|preview` resources, and exact local repo assets
- If those sources still do not prove the icon geometry, use an empty placeholder box and report the icon in `Unresolved Icons` instead of leaving the evidence boundary

### Failure: shipping a screenshot instead of building the UI

Wrong:

- Render a calendar, card, table, modal, chart, or form as `next/image`, `<img>`, or a CSS background using a Figma-exported PNG/WebP
- Justify it with “static is enough”, “faster”, or “the user did not ask for interactivity”

Right:

- Use previews only to inspect the target and validate the result
- Build the visible UI region as real DOM/CSS structure
- Use actual image assets only when the image itself is intended content, not a screenshot of the UI

## Done Criteria

The task is not done unless all of the following are true:

- visual geometry matches the inspected node data;
- typography matches the inspected text nodes;
- block styling matches fills, strokes, effects, and radii from the design;
- no border, radius, or spacing value was added from guesswork before exhausting `style`, `styleRefs`, and relevant descendants;
- no implementation choice was justified solely by a layer name;
- missing icons/assets were recreated from `local-figma-port` instead of substituted;
- a written container audit and completion self-review exist for border/radius/fill/stroke ownership;
- a target-scoped checklist was created on demand for the exact `page`, `selection`, or `node` being implemented;
- all required checklist items were either closed by source-backed implementation or explicitly blocked and accepted by the user;
- no UI region outside the checklist/export scope was invented from surrounding screenshots or product intuition;
- a current scratchpad exists at `${CODEX_HOME:-~/.codex}/cache/local-figma-port/<task-slug>.md` with up-to-date `Open Frontier`, `Coverage Ledger`, and `Fragment Checklist`;
- every visible icon has exact asset proof, exact vector-child proof, or an explicit `placeholder-blocked` record with a matching placeholder box in the UI;
- all visible states were checked and any drift was either fixed or explicitly accepted by the user;
- no screenshot, preview image, or exported frame bitmap was shipped in place of markup/styling for a UI fragment;
- no visible icon geometry was sourced from the internet or any external repository/library outside the repo and `local-figma-port` evidence;
- no unnecessary clarification question was asked for a default `presentational 1:1` task, and `logicful` mode was not entered without an explicit user request;
- any unresolved icon placeholder is explicitly listed in the final report;
- any other unresolved mismatch is explicitly called out and explicitly accepted by the user.

## Reliable Pattern

Use this compact decision rule while working:

```text
trace -> audit -> implement -> verify -> if drift or ambiguity remains, loop back
```

This skill fails when the agent treats the work as a one-pass extraction instead of a closed verification loop.
