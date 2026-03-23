import { one, query } from "../db.js";

type Row = {
  id: string;
  page_id: string;
  parent_id: string | null;
  type: string;
  name: string;
  x: number;
  y: number;
  w: number;
  h: number;
  abs_x: number | null;
  abs_y: number | null;
  abs_w: number | null;
  abs_h: number | null;
  component_id: string | null;
  variant_props_json: string | null;
  layout_intent_json: string | null;
  style_json: string | null;
  style_refs_json: string | null;
  resources_json: string | null;
  inspection_hints_json: string | null;
  computed_json: string | null;
};

type SelectionIndex = {
  selections?: Array<{
    selectionId?: string;
    nodeId?: string;
    preview?: string;
  }>;
};

type AssetIndex = {
  assets?: Array<{
    assetId?: string;
    nodeId?: string;
  }>;
};

type ImageAssetIndex = {
  images?: Array<{
    imageId?: string;
    nodeId?: string;
  }>;
};

type NodeResources = {
  previewUri?: string;
  selectionIds?: string[];
  assetIds?: string[];
  imageIds?: string[];
  uikitComponentIds?: string[];
};

function parseJson<T>(raw: string | null): T | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

const metaCache = new Map<string, unknown>();

function loadMetaJson<T>(key: string): T | null {
  if (metaCache.has(key)) {
    return (metaCache.get(key) as T | null) ?? null;
  }
  const row = one<{ value: string }>("SELECT value FROM meta WHERE key = ?", [key]);
  const parsed = parseJson<T>(row?.value ?? null);
  metaCache.set(key, parsed ?? null);
  return parsed ?? null;
}

function uniqueStrings(values: Array<string | null | undefined>): string[] {
  return [...new Set(values.filter((value): value is string => typeof value === "string" && value.length > 0))];
}

function readNodeRow(nodeId: string): Row | null {
  return one<Row>(
    `SELECT id, page_id, parent_id, type, name, x, y, w, h,
      abs_x, abs_y, abs_w, abs_h, component_id, variant_props_json,
      layout_intent_json, style_json, style_refs_json, resources_json, inspection_hints_json, computed_json
     FROM nodes WHERE id = ?`,
    [nodeId]
  );
}

function readChildRows(parentId: string): Row[] {
  return query<Row>(
    `SELECT n.id, n.page_id, n.parent_id, n.type, n.name, n.x, n.y, n.w, n.h,
      n.abs_x, n.abs_y, n.abs_w, n.abs_h, n.component_id, n.variant_props_json,
      n.layout_intent_json, n.style_json, n.style_refs_json, n.resources_json, n.inspection_hints_json, n.computed_json
      FROM nodes n
      JOIN edges e ON e.child_id = n.id
      WHERE e.parent_id = ?
      ORDER BY e.ord`,
    [parentId]
  );
}

function readChildIds(nodeId: string): string[] {
  return query<{ child_id: string }>(
    "SELECT child_id FROM edges WHERE parent_id = ? ORDER BY ord",
    [nodeId]
  ).map((row) => row.child_id);
}

function hasDescendantsBeyond(nodeId: string, expandedDepth: number): boolean {
  const threshold = Math.max(1, expandedDepth + 1);
  const row = one<{ v: number }>(
    `WITH RECURSIVE tree(id, depth) AS (
      SELECT child_id, 1 FROM edges WHERE parent_id = ?
      UNION ALL
      SELECT e.child_id, tree.depth + 1
      FROM edges e
      JOIN tree ON e.parent_id = tree.id
      WHERE tree.depth < ?
    )
    SELECT 1 AS v FROM tree WHERE depth >= ?`,
    [nodeId, threshold, threshold]
  );
  return !!row?.v;
}

function deriveNodeResources(nodeId: string): NodeResources {
  const selections = loadMetaJson<SelectionIndex>("selections_index")?.selections ?? [];
  const assets = loadMetaJson<AssetIndex>("assets_index")?.assets ?? [];
  const images = loadMetaJson<ImageAssetIndex>("image_assets_index")?.images ?? [];

  const selectionMatches = selections.filter((item) => item?.nodeId === nodeId);
  const assetMatches = assets.filter((item) => item?.nodeId === nodeId);
  const imageMatches = images.filter((item) => item?.nodeId === nodeId);
  const uikitMatches = query<{ component_id: string }>(
    "SELECT component_id FROM uikit_component_usages WHERE node_id = ? ORDER BY component_id",
    [nodeId]
  );

  const preview = selectionMatches
    .map((item) => item.preview)
    .find((previewPath) => typeof previewPath === "string");

  return {
    previewUri: preview ? `design://preview/${preview.split("/").pop()}` : undefined,
    selectionIds: uniqueStrings(selectionMatches.map((item) => item.selectionId)),
    assetIds: uniqueStrings(assetMatches.map((item) => item.assetId)),
    imageIds: uniqueStrings(imageMatches.map((item) => item.imageId)),
    uikitComponentIds: uniqueStrings(uikitMatches.map((item) => item.component_id)),
  };
}

function mergeNodeResources(stored: unknown, derived: NodeResources): NodeResources | undefined {
  const storedObj = stored && typeof stored === "object" ? (stored as Record<string, unknown>) : {};
  const merged: NodeResources = {
    previewUri:
      typeof storedObj.previewUri === "string" ? storedObj.previewUri : derived.previewUri,
    selectionIds: uniqueStrings([
      ...((storedObj.selectionIds as string[] | undefined) ?? []),
      ...(derived.selectionIds ?? []),
    ]),
    assetIds: uniqueStrings([
      ...((storedObj.assetIds as string[] | undefined) ?? []),
      ...(derived.assetIds ?? []),
    ]),
    imageIds: uniqueStrings([
      ...((storedObj.imageIds as string[] | undefined) ?? []),
      ...(derived.imageIds ?? []),
    ]),
    uikitComponentIds: uniqueStrings([
      ...((storedObj.uikitComponentIds as string[] | undefined) ?? []),
      ...(derived.uikitComponentIds ?? []),
    ]),
  };

  if (
    !merged.previewUri &&
    !(merged.selectionIds?.length) &&
    !(merged.assetIds?.length) &&
    !(merged.imageIds?.length) &&
    !(merged.uikitComponentIds?.length)
  ) {
    return undefined;
  }
  return merged;
}

function buildInspectionHints(
  row: Row,
  childIds: string[],
  stored: unknown,
  expandedDepth: number
): Record<string, unknown> {
  const storedObj = stored && typeof stored === "object" ? { ...(stored as Record<string, unknown>) } : {};
  const hints: Record<string, unknown> = {
    ...storedObj,
    childrenExpandedDepth: expandedDepth,
    hasDeeperDescendants: hasDescendantsBeyond(row.id, expandedDepth),
  };

  if (row.type === "INSTANCE" || row.component_id) {
    if (typeof hints.requiresInstanceResolution !== "boolean") {
      hints.requiresInstanceResolution = true;
    }
    if (typeof hints.masterComponentId !== "string" && row.component_id) {
      hints.masterComponentId = row.component_id;
    }
    if (!Array.isArray(hints.overrideNodeIds) && childIds.length > 0) {
      hints.overrideNodeIds = childIds;
    }
  }

  return hints;
}

function materializeRow(row: Row, expandedDepth: number) {
  const childIds = readChildIds(row.id);
  const storedResources = parseJson<unknown>(row.resources_json);
  const storedInspectionHints = parseJson<unknown>(row.inspection_hints_json);
  const resources = mergeNodeResources(storedResources, deriveNodeResources(row.id));
  const inspectionHints = buildInspectionHints(row, childIds, storedInspectionHints, expandedDepth);

  return {
    id: row.id,
    pageId: row.page_id,
    parentId: row.parent_id,
    type: row.type,
    name: row.name,
    bounds: { x: Number(row.x), y: Number(row.y), w: Number(row.w), h: Number(row.h) },
    absBounds:
      row.abs_x === null
        ? null
        : { x: Number(row.abs_x), y: Number(row.abs_y), w: Number(row.abs_w), h: Number(row.abs_h) },
    componentId: row.component_id,
    variantProps: parseJson(row.variant_props_json) ?? {},
    layoutIntent: parseJson(row.layout_intent_json),
    style: parseJson(row.style_json),
    styleRefs: parseJson(row.style_refs_json) ?? { variables: [], styles: [] },
    resources,
    inspectionHints,
    computed: parseJson(row.computed_json),
    childrenIds: childIds,
  };
}

export function readNodeTree(nodeId: string, depth = 0): Record<string, unknown> | null {
  const row = readNodeRow(nodeId);
  if (!row) return null;
  const node = materializeRow(row, depth);
  if (depth <= 0) {
    return node;
  }
  const children = readChildRows(nodeId)
    .map((child) => readNodeTree(child.id, depth - 1))
    .filter((child): child is Record<string, unknown> => !!child);
  return { ...node, children };
}
