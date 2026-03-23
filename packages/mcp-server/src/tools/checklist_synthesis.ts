import { one, query } from "../db.js";
import { normalizeSearchText } from "./fts_query.js";

export type CoverageChecklistInput = {
  targetType: "page" | "selection" | "node";
  targetId: string;
  nodeId?: string;
  mode?: "implementation";
  maxItems?: number;
  requestedTarget?: string;
};

export type CoverageChecklistItem = {
  itemId: string;
  role: string;
  required: boolean;
  nodeId: string;
  path: string;
  bounds: { x: number; y: number; w: number; h: number };
  requiredVisuals: string[];
  requiredText: string[];
  requiredAssets: string[];
  childrenToInspect: string[];
  status: "open";
};

export type CoverageChecklistOutput = {
  scopeType: "page" | "selection" | "node";
  scopeId: string;
  scopeBounds: { x: number; y: number; w: number; h: number } | null;
  previewUri: string | null;
  previewFileUri: string | null;
  outsideScopeWarning: string;
  majorSections: Array<{ name: string; nodeId: string; required: boolean }>;
  items: CoverageChecklistItem[];
};

type SelectionIndex = {
  selections?: Array<{
    selectionId?: string;
    name?: string;
    nodeId?: string;
    pageId?: string;
    preview?: string;
  }>;
};

type PageRow = {
  id: string;
  name: string;
};

type FlatNodeRow = {
  id: string;
  page_id: string;
  parent_id: string | null;
  type: string;
  name: string;
  x: number;
  y: number;
  w: number;
  h: number;
  path: string;
  text_content: string;
  resources_json: string | null;
};

type FlatNode = {
  id: string;
  pageId: string;
  parentId: string | null;
  type: string;
  name: string;
  bounds: { x: number; y: number; w: number; h: number };
  path: string;
  textContent: string;
  resources: Record<string, unknown> | null;
  childrenIds: string[];
  depth: number;
};

type ScopeContext = {
  scopeType: "page" | "selection" | "node";
  scopeId: string;
  pageId: string | null;
  rootNodeIds: string[];
  previewUri: string | null;
  previewFileUri: string | null;
  scopeBounds: { x: number; y: number; w: number; h: number } | null;
};

function parseJson<T>(raw: string | null | undefined): T | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

function loadSelections() {
  return parseJson<SelectionIndex>(one<{ value: string }>("SELECT value FROM meta WHERE key = ?", ["selections_index"])?.value)
    ?.selections ?? [];
}

function toPreviewUris(preview: string | null | undefined) {
  if (!preview) {
    return { previewUri: null, previewFileUri: null };
  }
  const fileName = preview.split("/").pop();
  if (!fileName) {
    return { previewUri: null, previewFileUri: null };
  }
  return {
    previewUri: `design://preview/${fileName}`,
    previewFileUri: `design://preview-file/${fileName}`,
  };
}

function loadPage(pageId: string): PageRow | null {
  return one<PageRow>("SELECT id, name FROM pages WHERE id = ?", [pageId]);
}

function loadNodeBounds(nodeId: string) {
  const row = one<{ x: number; y: number; w: number; h: number }>(
    "SELECT x, y, w, h FROM nodes WHERE id = ?",
    [nodeId]
  );
  if (!row) return null;
  return { x: Number(row.x), y: Number(row.y), w: Number(row.w), h: Number(row.h) };
}

function loadRootNodeIdsForPage(pageId: string): string[] {
  return query<{ id: string }>(
    "SELECT id FROM nodes WHERE page_id = ? AND parent_id IS NULL ORDER BY y, x, name COLLATE NOCASE",
    [pageId]
  ).map((row) => row.id);
}

function unionBounds(boundsList: Array<{ x: number; y: number; w: number; h: number } | null>) {
  const items = boundsList.filter((bounds): bounds is { x: number; y: number; w: number; h: number } => !!bounds);
  if (items.length === 0) return null;
  const minX = Math.min(...items.map((bounds) => bounds.x));
  const minY = Math.min(...items.map((bounds) => bounds.y));
  const maxX = Math.max(...items.map((bounds) => bounds.x + bounds.w));
  const maxY = Math.max(...items.map((bounds) => bounds.y + bounds.h));
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

function resolveScopeContext(input: CoverageChecklistInput): ScopeContext {
  if (input.targetType === "selection") {
    const found = loadSelections().find((selection) => selection.selectionId === input.targetId);
    if (!found?.selectionId || !found.nodeId) {
      throw new Error(`Unknown selection target: ${input.targetId}`);
    }
    const bounds = loadNodeBounds(found.nodeId);
    const preview = toPreviewUris(found.preview);
    return {
      scopeType: "selection",
      scopeId: found.selectionId,
      pageId: found.pageId ?? null,
      rootNodeIds: [input.nodeId ?? found.nodeId],
      previewUri: preview.previewUri,
      previewFileUri: preview.previewFileUri,
      scopeBounds: bounds,
    };
  }

  if (input.targetType === "page") {
    const page = loadPage(input.targetId);
    if (!page) {
      throw new Error(`Unknown page target: ${input.targetId}`);
    }
    const rootNodeIds = loadRootNodeIdsForPage(page.id);
    const scopeBounds = unionBounds(rootNodeIds.map((nodeId) => loadNodeBounds(nodeId)));
    return {
      scopeType: "page",
      scopeId: page.id,
      pageId: page.id,
      rootNodeIds,
      previewUri: null,
      previewFileUri: null,
      scopeBounds,
    };
  }

  const nodeId = input.nodeId ?? input.targetId;
  const row = one<{ page_id: string }>("SELECT page_id FROM nodes WHERE id = ?", [nodeId]);
  if (!row?.page_id) {
    throw new Error(`Unknown node target: ${input.targetId}`);
  }
  const selection = loadSelections().find((item) => item.nodeId === nodeId);
  const preview = toPreviewUris(selection?.preview);
  return {
    scopeType: "node",
    scopeId: input.targetId,
    pageId: row.page_id,
    rootNodeIds: [nodeId],
    previewUri: preview.previewUri,
    previewFileUri: preview.previewFileUri,
    scopeBounds: loadNodeBounds(nodeId),
  };
}

function loadScopeNodes(scope: ScopeContext): Map<string, FlatNode> {
  const treeRows = new Map<string, FlatNode>();

  for (const rootNodeId of scope.rootNodeIds) {
    const rows = query<FlatNodeRow & { depth: number }>(
      `WITH RECURSIVE tree(id, depth) AS (
        SELECT ? AS id, 0 AS depth
        UNION ALL
        SELECT e.child_id, tree.depth + 1
        FROM edges e
        JOIN tree ON e.parent_id = tree.id
      )
      SELECT n.id, n.page_id, n.parent_id, n.type, n.name, n.x, n.y, n.w, n.h,
        COALESCE((SELECT fn.path FROM fts_nodes fn WHERE fn.node_id = n.id LIMIT 1), n.name) AS path,
        COALESCE(t.content, '') AS text_content,
        n.resources_json,
        tree.depth
      FROM tree
      JOIN nodes n ON n.id = tree.id
      LEFT JOIN texts t ON t.node_id = n.id`,
      [rootNodeId]
    );

    for (const row of rows) {
      const existing = treeRows.get(row.id);
      if (existing) {
        existing.depth = Math.min(existing.depth, Number(row.depth));
        continue;
      }
      treeRows.set(row.id, {
        id: row.id,
        pageId: row.page_id,
        parentId: row.parent_id,
        type: row.type,
        name: row.name,
        bounds: { x: Number(row.x), y: Number(row.y), w: Number(row.w), h: Number(row.h) },
        path: row.path,
        textContent: row.text_content ?? "",
        resources: parseJson<Record<string, unknown>>(row.resources_json),
        childrenIds: [],
        depth: Number(row.depth),
      });
    }
  }

  for (const node of treeRows.values()) {
    if (node.parentId && treeRows.has(node.parentId)) {
      treeRows.get(node.parentId)?.childrenIds.push(node.id);
    }
  }

  for (const node of treeRows.values()) {
    node.childrenIds.sort((left, right) => {
      const a = treeRows.get(left);
      const b = treeRows.get(right);
      if (!a || !b) return left.localeCompare(right);
      if (a.bounds.y !== b.bounds.y) return a.bounds.y - b.bounds.y;
      if (a.bounds.x !== b.bounds.x) return a.bounds.x - b.bounds.x;
      return a.name.localeCompare(b.name);
    });
  }

  return treeRows;
}

function descendantIds(nodes: Map<string, FlatNode>, nodeId: string): string[] {
  const out: string[] = [];
  const queue = [...(nodes.get(nodeId)?.childrenIds ?? [])];
  while (queue.length > 0) {
    const next = queue.shift() as string;
    out.push(next);
    queue.push(...(nodes.get(next)?.childrenIds ?? []));
  }
  return out;
}

function descendantTexts(nodes: Map<string, FlatNode>, nodeId: string, limit = 4): string[] {
  const values = new Set<string>();
  const ids = [nodeId, ...descendantIds(nodes, nodeId)];
  for (const id of ids) {
    const text = nodes.get(id)?.textContent?.trim();
    if (text) {
      values.add(text);
      if (values.size >= limit) break;
    }
  }
  return [...values];
}

function descendantAssets(nodes: Map<string, FlatNode>, nodeId: string, limit = 6): string[] {
  const values = new Set<string>();
  const ids = [nodeId, ...descendantIds(nodes, nodeId)];
  for (const id of ids) {
    const node = nodes.get(id);
    if (!node) continue;
    for (const assetId of ((node.resources?.assetIds as string[] | undefined) ?? [])) {
      if (assetId) values.add(assetId);
    }
    for (const imageId of ((node.resources?.imageIds as string[] | undefined) ?? [])) {
      if (imageId) values.add(imageId);
    }
    if ((node.type === "INSTANCE" || node.type === "VECTOR") && !isGenericLayerName(node.name)) {
      values.add(node.name);
    }
    if (values.size >= limit) break;
  }
  return [...values].slice(0, limit);
}

function isGenericLayerName(name: string): boolean {
  return ["frame", "text", "rectangle", "instance", "group", "vector"].includes(normalizeSearchText(name));
}

function matchesTimeRange(text: string): boolean {
  return /\b\d{2}:\d{2}(?:\s*[-–]\s*|\s+)\d{2}:\d{2}\b/.test(text);
}

function childNodes(nodes: Map<string, FlatNode>, node: FlatNode): FlatNode[] {
  return node.childrenIds
    .map((childId) => nodes.get(childId))
    .filter((child): child is FlatNode => !!child);
}

function hasSmallMarker(node: FlatNode): boolean {
  return node.type === "RECTANGLE" && node.bounds.w <= 14 && node.bounds.h <= 14;
}

function isLegendRowCandidate(node: FlatNode, nodes: Map<string, FlatNode>): boolean {
  const children = childNodes(nodes, node);
  if (children.length < 3) return false;
  const labelledChildren = children.filter((child) => {
    const grandChildren = childNodes(nodes, child);
    return grandChildren.some((descendant) => hasSmallMarker(descendant)) &&
      grandChildren.some((descendant) => {
        const text = descendant.textContent.trim();
        return text.length > 0 || descendant.type === "TEXT";
      });
  });
  return labelledChildren.length >= 3;
}

function isScrollbarCandidate(node: FlatNode, nodes: Map<string, FlatNode>): boolean {
  if (normalizeSearchText(node.name).includes("scrollbar")) return true;
  if (!(node.bounds.w <= 8 && node.bounds.h >= 24 && node.bounds.h / Math.max(node.bounds.w, 1) >= 4)) {
    return false;
  }
  const parent = node.parentId ? nodes.get(node.parentId) : null;
  return (parent?.depth ?? 99) <= 1;
}

function detectRole(node: FlatNode, nodes: Map<string, FlatNode>): string {
  const haystack = [node.name, node.path, node.textContent, ...descendantTexts(nodes, node.id, 3)]
    .map((value) => normalizeSearchText(value))
    .join(" ");

  if (isLegendRowCandidate(node, nodes)) {
    return "legend-row";
  }
  if (isScrollbarCandidate(node, nodes)) {
    return "scrollbar";
  }
  if (haystack.includes("legend")) {
    return "legend-row";
  }
  if (/(забронировать|бронь|book|reserve|cta|primary cta|button)/.test(haystack)) {
    return "button";
  }
  if (/(фильтр|filter|выбрано|моя бронь|bonus|tag|chip|pill|badge)/.test(haystack)) {
    return "tag";
  }
  if (/(selected slots|slot list|slot|time range|time slot)/.test(haystack) && node.type !== "TEXT") {
    return "slot-cell";
  }
  if (/(chip|pill|badge|tag|bonus)/.test(haystack)) {
    return "tag";
  }
  if (/(schedule|calendar|grid)/.test(haystack) && node.type !== "TEXT") {
    return "grid";
  }
  if (/(control|toolbar|header|filter)/.test(haystack) && node.type !== "TEXT") {
    return "control";
  }
  if ((node.type === "INSTANCE" || node.type === "VECTOR") && !isGenericLayerName(node.name)) {
    return "icon";
  }
  if (node.type === "TEXT") {
    return "text";
  }
  if (node.depth === 1 && (node.type === "FRAME" || node.type === "INSTANCE")) {
    return "section";
  }
  return "render-slice";
}

function requiredVisualsForRole(role: string): string[] {
  switch (role) {
    case "legend-row":
      return ["legend-markers", "legend-copy"];
    case "scrollbar":
      return ["scroll-track", "scroll-thumb"];
    case "button":
      return ["button-surface", "button-copy", "button-icon"];
    case "slot-cell":
      return ["slot-surface", "slot-time-copy"];
    case "grid":
      return ["calendar-grid", "slot-columns"];
    case "control":
      return ["control-surface", "control-copy", "icon-button"];
    case "tag":
      return ["chip-surface", "chip-copy"];
    case "icon":
      return ["icon-glyph"];
    case "text":
      return ["text-copy"];
    case "section":
      return ["section-layout"];
    default:
      return ["render-slice"];
  }
}

function shouldIncludeItem(node: FlatNode, role: string, nodes: Map<string, FlatNode>, rootIds: string[]): boolean {
  if (rootIds.includes(node.id)) return false;
  if (node.depth === 1) return true;
  if (["legend-row", "scrollbar", "button", "slot-cell", "tag", "icon", "state-chip"].includes(role)) return true;
  if (node.type === "TEXT" && matchesTimeRange(node.textContent)) {
    const parentRole = node.parentId ? detectRole(nodes.get(node.parentId) as FlatNode, nodes) : "";
    return !["button", "legend-row", "slot-cell", "control", "section", "grid"].includes(parentRole);
  }
  return false;
}

function itemSort(nodes: Map<string, FlatNode>, left: CoverageChecklistItem, right: CoverageChecklistItem): number {
  const a = nodes.get(left.nodeId);
  const b = nodes.get(right.nodeId);
  if (!a || !b) return left.path.localeCompare(right.path);
  if (a.depth !== b.depth) return a.depth - b.depth;
  if (a.bounds.y !== b.bounds.y) return a.bounds.y - b.bounds.y;
  if (a.bounds.x !== b.bounds.x) return a.bounds.x - b.bounds.x;
  return a.path.localeCompare(b.path);
}

function buildMajorSections(scope: ScopeContext, nodes: Map<string, FlatNode>) {
  if (scope.scopeType === "page") {
    return scope.rootNodeIds
      .map((nodeId) => nodes.get(nodeId))
      .filter((node): node is FlatNode => !!node)
      .map((node) => ({ name: node.name, nodeId: node.id, required: true }));
  }

  const root = nodes.get(scope.rootNodeIds[0]);
  if (!root) return [];
  const sections = root.childrenIds
    .map((childId) => nodes.get(childId))
    .filter((node): node is FlatNode => !!node)
    .filter((node) => ["FRAME", "INSTANCE", "TEXT"].includes(node.type));
  const items = sections.length > 0 ? sections : [root];
  return items.map((node) => ({ name: node.name, nodeId: node.id, required: true }));
}

function detectOutsideScopeWarning(
  scope: ScopeContext,
  nodes: Map<string, FlatNode>,
  requestedTarget: string | undefined
): string {
  const requested = normalizeSearchText(requestedTarget ?? "");
  if (!requested) return "";

  const corpus = [...nodes.values()]
    .flatMap((node) => [node.name, node.path, node.textContent])
    .map((value) => normalizeSearchText(value))
    .join(" ");

  const missingPhrases = [
    "selected slots",
    "details panel",
    "lower panel",
    "sidebar",
    "footer",
    "bottom panel",
    "slot list",
  ].filter((phrase) => requested.includes(phrase) && !corpus.includes(phrase));

  if (missingPhrases.length > 0) {
    return `Requested UI mentions ${missingPhrases.join(", ")}, but the exported ${scope.scopeType} scope does not contain matching nodes or text.`;
  }

  if (
    scope.scopeType === "selection" &&
    /\b(full|whole|entire)\b/.test(requested) &&
    /\b(screen|page|view|booking)\b/.test(requested)
  ) {
    return "Requested UI sounds broader than the exported selection scope. Confirm the right selection or export a wider target before implementing.";
  }

  if (
    scope.scopeType !== "page" &&
    /\b(lower|bottom|sidebar|footer|panel|list|details)\b/.test(requested)
  ) {
    return `Requested UI implies regions outside the current ${scope.scopeType} scope. Do not invent adjacent panels before a wider export is available.`;
  }

  return "";
}

export function synthesizeCoverageChecklist(input: CoverageChecklistInput): CoverageChecklistOutput {
  const scope = resolveScopeContext(input);
  const nodes = loadScopeNodes(scope);
  const rootIds = scope.rootNodeIds.filter((nodeId) => nodes.has(nodeId));
  if (rootIds.length === 0) {
    throw new Error(`No nodes found for ${scope.scopeType} ${scope.scopeId}`);
  }

  const items: CoverageChecklistItem[] = [];

  for (const node of nodes.values()) {
    const role = detectRole(node, nodes);
    if (!shouldIncludeItem(node, role, nodes, rootIds)) continue;

    items.push({
      itemId: `${role}-${node.id.replace(/[^a-zA-Z0-9]+/g, "_")}`,
      role,
      required: true,
      nodeId: node.id,
      path: node.path,
      bounds: node.bounds,
      requiredVisuals: requiredVisualsForRole(role),
      requiredText: descendantTexts(nodes, node.id, role === "button" ? 3 : 4),
      requiredAssets: descendantAssets(nodes, node.id, 6),
      childrenToInspect: [...node.childrenIds],
      status: "open",
    });
  }

  items.sort((left, right) => itemSort(nodes, left, right));

  return {
    scopeType: scope.scopeType,
    scopeId: scope.scopeId,
    scopeBounds: scope.scopeBounds,
    previewUri: scope.previewUri,
    previewFileUri: scope.previewFileUri,
    outsideScopeWarning: detectOutsideScopeWarning(scope, nodes, input.requestedTarget),
    majorSections: buildMajorSections(scope, nodes),
    items: items.slice(0, input.maxItems ?? 200),
  };
}
