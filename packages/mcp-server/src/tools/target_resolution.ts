import { one, query } from "../db.js";
import { normalizeSearchText } from "./fts_query.js";
import { listFrameRows } from "./list_frames.js";
import { searchNodeRows } from "./search_nodes.js";
import { searchTextRows } from "./search_text.js";

export type ResolveScopeHint = "auto" | "page" | "selection" | "node";
export type ResolveTargetType = "page" | "selection" | "node";

export type ResolveTargetInput = {
  query: string;
  scopeHint?: ResolveScopeHint;
  pageId?: string;
  types?: string[];
  limit?: number;
};

export type ResolveTargetCandidate = {
  targetType: ResolveTargetType;
  targetId: string;
  nodeId: string | null;
  pageId: string | null;
  name: string;
  path: string;
  bounds: { x: number; y: number; w: number; h: number } | null;
  previewUri?: string;
  previewFileUri?: string;
  matchReason: string[];
  confidence: number;
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

type NodeInfoRow = {
  id: string;
  parent_id?: string | null;
  page_id: string;
  type: string;
  name: string;
  x: number;
  y: number;
  w: number;
  h: number;
  path: string;
};

type InternalCandidate = ResolveTargetCandidate & {
  score: number;
};

const GENERIC_LAYER_NAMES = new Set([
  "frame",
  "text",
  "rectangle",
  "group",
  "instance",
  "component",
  "image",
  "vector",
  "line",
  "ellipse",
]);

function parseMetaJson<T>(key: string): T | null {
  const row = one<{ value: string }>("SELECT value FROM meta WHERE key = ?", [key]);
  if (!row?.value) return null;
  try {
    return JSON.parse(row.value) as T;
  } catch {
    return null;
  }
}

function toBounds(row: { x: number; y: number; w: number; h: number } | null | undefined) {
  if (!row) return null;
  return {
    x: Number(row.x),
    y: Number(row.y),
    w: Number(row.w),
    h: Number(row.h),
  };
}

function loadSelections() {
  return parseMetaJson<SelectionIndex>("selections_index")?.selections ?? [];
}

function loadPages(pageId?: string): PageRow[] {
  if (pageId) {
    return query<PageRow>("SELECT id, name FROM pages WHERE id = ? ORDER BY name COLLATE NOCASE", [pageId]);
  }
  return query<PageRow>("SELECT id, name FROM pages ORDER BY name COLLATE NOCASE");
}

function loadNodeInfo(nodeId: string): NodeInfoRow | null {
  return one<NodeInfoRow>(
    `SELECT n.id, n.parent_id, n.page_id, n.type, n.name, n.x, n.y, n.w, n.h,
      COALESCE((SELECT fn.path FROM fts_nodes fn WHERE fn.node_id = n.id LIMIT 1), n.name) AS path
     FROM nodes n
     WHERE n.id = ?`,
    [nodeId]
  );
}

function loadAncestorNodes(nodeId: string, maxDepth = 3): NodeInfoRow[] {
  return query<NodeInfoRow & { depth: number }>(
    `WITH RECURSIVE ancestors(id, parent_id, depth) AS (
      SELECT id, parent_id, 0 AS depth
      FROM nodes
      WHERE id = ?
      UNION ALL
      SELECT n.id, n.parent_id, ancestors.depth + 1
      FROM nodes n
      JOIN ancestors ON ancestors.parent_id = n.id
      WHERE ancestors.depth < ?
    )
    SELECT n.id, n.parent_id, n.page_id, n.type, n.name, n.x, n.y, n.w, n.h,
      COALESCE((SELECT fn.path FROM fts_nodes fn WHERE fn.node_id = n.id LIMIT 1), n.name) AS path,
      ancestors.depth
    FROM ancestors
    JOIN nodes n ON n.id = ancestors.id
    WHERE ancestors.depth > 0
    ORDER BY ancestors.depth`,
    [nodeId, maxDepth]
  );
}

function exactMatch(value: string | null | undefined, query: string): boolean {
  if (!value) return false;
  return normalizeSearchText(value) === normalizeSearchText(query);
}

function containsMatch(value: string | null | undefined, query: string): boolean {
  if (!value) return false;
  return normalizeSearchText(value).includes(normalizeSearchText(query));
}

function isGenericLayerName(name: string): boolean {
  return GENERIC_LAYER_NAMES.has(normalizeSearchText(name));
}

function withPreview(previewPath: string | null | undefined) {
  if (!previewPath) return {};
  const fileName = previewPath.split("/").pop();
  if (!fileName) return {};
  return {
    previewUri: `design://preview/${fileName}`,
    previewFileUri: `design://preview-file/${fileName}`,
  };
}

function scopeBonus(targetType: ResolveTargetType, scopeHint: ResolveScopeHint): number {
  if (scopeHint === "auto") return 0;
  return targetType === scopeHint ? 0.02 : 0;
}

function previewBonus(candidate: InternalCandidate): number {
  return candidate.previewUri ? 0.015 : 0;
}

function genericPenalty(name: string): number {
  return isGenericLayerName(name) ? 0.08 : 0;
}

function semanticContainerBonus(name: string, path: string): number {
  const haystack = normalizeSearchText(`${name} ${path}`);
  if (/(button|state|chip|tag|filter|slot|legend|header|control|toolbar|grid|schedule)/.test(haystack)) {
    return 0.06;
  }
  return 0;
}

function boundedScore(value: number): number {
  return Math.max(0.01, Math.min(0.999, Number(value.toFixed(3))));
}

function pushCandidate(
  bag: InternalCandidate[],
  candidate: Omit<ResolveTargetCandidate, "confidence">,
  score: number
) {
  const scopedScore = boundedScore(score);
  bag.push({
    ...candidate,
    confidence: scopedScore,
    score: scopedScore,
  });
}

function collectDirectIdCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  const trimmed = input.query.trim();
  if (!trimmed) return;

  const selection = loadSelections().find((item) => item.selectionId === trimmed);
  if (selection?.selectionId) {
    const nodeInfo = selection.nodeId ? loadNodeInfo(selection.nodeId) : null;
    pushCandidate(
      bag,
      {
        targetType: "selection",
        targetId: selection.selectionId,
        nodeId: selection.nodeId ?? null,
        pageId: selection.pageId ?? nodeInfo?.page_id ?? null,
        name: selection.name ?? selection.selectionId,
        path: nodeInfo?.path ?? selection.name ?? selection.selectionId,
        bounds: toBounds(nodeInfo),
        matchReason: ["selection-id-exact"],
        ...withPreview(selection.preview),
      },
      0.995
    );
  }

  const page = loadPages().find((item) => item.id === trimmed);
  if (page) {
    pushCandidate(
      bag,
      {
        targetType: "page",
        targetId: page.id,
        nodeId: null,
        pageId: page.id,
        name: page.name,
        path: page.name,
        bounds: null,
        matchReason: ["page-id-exact"],
      },
      0.945
    );
  }

  const nodeInfo = loadNodeInfo(trimmed);
  if (nodeInfo) {
    pushCandidate(
      bag,
      {
        targetType: "node",
        targetId: nodeInfo.id,
        nodeId: nodeInfo.id,
        pageId: nodeInfo.page_id,
        name: nodeInfo.name,
        path: nodeInfo.path,
        bounds: toBounds(nodeInfo),
        matchReason: ["node-id-exact"],
      },
      0.955
    );
  }
}

function collectSelectionCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  for (const selection of loadSelections()) {
    if (!selection.selectionId) continue;
    const exact = exactMatch(selection.name, input.query);
    const contains = !exact && containsMatch(selection.name, input.query);
    if (!exact && !contains) continue;

    const nodeInfo = selection.nodeId ? loadNodeInfo(selection.nodeId) : null;
    const baseScore = exact ? 0.98 : 0.84;
    const candidate: Omit<ResolveTargetCandidate, "confidence"> = {
      targetType: "selection",
      targetId: selection.selectionId,
      nodeId: selection.nodeId ?? null,
      pageId: selection.pageId ?? nodeInfo?.page_id ?? null,
      name: selection.name ?? selection.selectionId,
      path: nodeInfo?.path ?? selection.name ?? selection.selectionId,
      bounds: toBounds(nodeInfo),
      matchReason: [exact ? "selection-name-exact" : "selection-name-contains"],
      ...withPreview(selection.preview),
    };
    pushCandidate(
      bag,
      candidate,
      baseScore + scopeBonus("selection", input.scopeHint ?? "auto") + previewBonus({ ...candidate, confidence: 0, score: 0 })
    );
  }
}

function collectPageCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  for (const page of loadPages(input.pageId)) {
    const exact = exactMatch(page.name, input.query);
    const contains = !exact && containsMatch(page.name, input.query);
    if (!exact && !contains) continue;
    pushCandidate(
      bag,
      {
        targetType: "page",
        targetId: page.id,
        nodeId: null,
        pageId: page.id,
        name: page.name,
        path: page.name,
        bounds: null,
        matchReason: [exact ? "page-name-exact" : "page-name-contains"],
      },
      (exact ? 0.9 : 0.74) + scopeBonus("page", input.scopeHint ?? "auto")
    );
  }
}

function collectFrameCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  for (const frame of listFrameRows({ pageId: input.pageId, depth: 6, limit: Math.max(200, input.limit ?? 20) * 10 })) {
    const exact = exactMatch(frame.name, input.query);
    const contains = !exact && (containsMatch(frame.name, input.query) || containsMatch(frame.path, input.query));
    if (!exact && !contains) continue;
    const score = (exact ? 0.96 : 0.78) + scopeBonus("node", input.scopeHint ?? "auto") - genericPenalty(frame.name);
    pushCandidate(
      bag,
      {
        targetType: "node",
        targetId: frame.id,
        nodeId: frame.id,
        pageId: frame.pageId,
        name: frame.name,
        path: frame.path,
        bounds: frame.bounds,
        matchReason: [exact ? "frame-name-exact" : "frame-name-contains"],
      },
      score
    );
  }
}

function collectSearchNodeCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  for (const hit of searchNodeRows({
    query: input.query,
    pageId: input.pageId,
    types: input.types,
    limit: Math.max(50, input.limit ?? 20) * 4,
  })) {
    const exactName = exactMatch(hit.name, input.query);
    const exactPath = !exactName && exactMatch(hit.path, input.query);
    const containsName = !exactName && containsMatch(hit.name, input.query);
    const containsPath = !exactName && !exactPath && containsMatch(hit.path, input.query);
    const reason = exactName
      ? "node-name-exact"
      : exactPath
        ? "path-exact"
        : containsName
          ? "node-name-contains"
          : containsPath
            ? "path-contains"
            : "node-search-hit";
    const baseScore =
      exactName ? 0.92 :
      exactPath ? 0.86 :
      containsName ? 0.8 :
      containsPath ? 0.72 :
      0.68;
    pushCandidate(
      bag,
      {
        targetType: hit.type === "FRAME" ? "node" : "node",
        targetId: hit.nodeId,
        nodeId: hit.nodeId,
        pageId: hit.pageId,
        name: hit.name,
        path: hit.path,
        bounds: hit.bounds,
        matchReason: [reason],
      },
      baseScore + scopeBonus("node", input.scopeHint ?? "auto") - genericPenalty(hit.name)
    );
  }
}

function collectSearchTextCandidates(
  input: ResolveTargetInput,
  bag: InternalCandidate[]
): void {
  for (const hit of searchTextRows({
    query: input.query,
    pageId: input.pageId,
    limit: Math.max(50, input.limit ?? 20) * 4,
  })) {
    const exact = exactMatch(hit.content, input.query);
    const contains = !exact && containsMatch(hit.content, input.query);
    const reason = exact ? "text-content-exact" : contains ? "text-content-contains" : "text-search-hit";
    const baseScore = exact ? 0.88 : contains ? 0.76 : 0.7;
    pushCandidate(
      bag,
      {
        targetType: "node",
        targetId: hit.nodeId,
        nodeId: hit.nodeId,
        pageId: hit.pageId,
        name: hit.name,
        path: hit.path,
        bounds: hit.bounds,
        matchReason: [reason],
      },
      baseScore + scopeBonus("node", input.scopeHint ?? "auto") - genericPenalty(hit.name)
    );

    const ancestors = loadAncestorNodes(hit.nodeId, 3);
    for (const [index, ancestor] of ancestors.entries()) {
      if (!["FRAME", "INSTANCE", "GROUP", "COMPONENT"].includes(ancestor.type)) continue;
      if (isGenericLayerName(ancestor.name) && index > 0) continue;

      const ancestorDepth = index + 1;
      const promotedScore =
        baseScore +
        (ancestorDepth === 1 ? 0.12 : 0.06) +
        semanticContainerBonus(ancestor.name, ancestor.path) +
        scopeBonus("node", input.scopeHint ?? "auto") -
        genericPenalty(ancestor.name);

      pushCandidate(
        bag,
        {
          targetType: "node",
          targetId: ancestor.id,
          nodeId: ancestor.id,
          pageId: ancestor.page_id,
          name: ancestor.name,
          path: ancestor.path,
          bounds: toBounds(ancestor),
          matchReason: [ancestorDepth === 1 ? "text-hit-parent-scope" : "text-hit-ancestor-scope"],
        },
        promotedScore
      );
    }
  }
}

function dedupeCandidates(candidates: InternalCandidate[]): ResolveTargetCandidate[] {
  const merged = new Map<string, InternalCandidate>();

  for (const candidate of candidates) {
    const key = `${candidate.targetType}:${candidate.targetId}:${candidate.nodeId ?? ""}:${candidate.pageId ?? ""}`;
    const existing = merged.get(key);
    if (!existing) {
      merged.set(key, { ...candidate, matchReason: [...candidate.matchReason] });
      continue;
    }

    existing.matchReason = [...new Set([...existing.matchReason, ...candidate.matchReason])];
    if (candidate.score > existing.score) {
      existing.score = candidate.score;
      existing.confidence = candidate.confidence;
      existing.name = candidate.name;
      existing.path = candidate.path;
      existing.bounds = candidate.bounds;
    }
    existing.previewUri = existing.previewUri ?? candidate.previewUri;
    existing.previewFileUri = existing.previewFileUri ?? candidate.previewFileUri;
  }

  return [...merged.values()]
    .sort((left, right) => {
      if (right.score !== left.score) return right.score - left.score;
      if (left.targetType !== right.targetType) return left.targetType.localeCompare(right.targetType);
      return left.path.localeCompare(right.path);
    })
    .map(({ score, ...candidate }) => ({
      ...candidate,
      confidence: boundedScore(candidate.confidence),
      matchReason: [...candidate.matchReason],
    }));
}

export function resolveTargetCandidates(input: ResolveTargetInput): ResolveTargetCandidate[] {
  const queryText = input.query.trim();
  if (!queryText) return [];

  const bag: InternalCandidate[] = [];
  collectDirectIdCandidates(input, bag);
  collectSelectionCandidates(input, bag);
  collectPageCandidates(input, bag);
  collectFrameCandidates(input, bag);
  collectSearchNodeCandidates(input, bag);
  collectSearchTextCandidates(input, bag);

  return dedupeCandidates(bag).slice(0, input.limit ?? 10);
}
