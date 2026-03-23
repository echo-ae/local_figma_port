import { query } from "../db.js";

export type ListFrameRow = {
  id: string;
  pageId: string;
  name: string;
  bounds: { x: number; y: number; w: number; h: number };
  childCount: number;
  path: string;
};

export function listFrameRows(input: { pageId?: string; depth?: number; limit?: number }): ListFrameRow[] {
  const depth = input.depth ?? 1;
  const limit = input.limit ?? 200;

  const rows = query<{
    id: string;
    page_id: string;
    name: string;
    x: number;
    y: number;
    w: number;
    h: number;
    child_count: number;
    path: string;
  }>(
    `WITH RECURSIVE tree(id, parent_id, depth) AS (
      SELECT id, parent_id, 1 AS depth
      FROM nodes
      WHERE (? IS NULL OR page_id = ?) AND parent_id IS NULL
      UNION ALL
      SELECT n.id, n.parent_id, tree.depth + 1
      FROM nodes n
      JOIN tree ON n.parent_id = tree.id
      WHERE tree.depth < ?
    )
    SELECT n.id, n.page_id, n.name, n.x, n.y, n.w, n.h,
      (SELECT COUNT(*) FROM edges e WHERE e.parent_id = n.id) AS child_count,
      COALESCE((SELECT fn.path FROM fts_nodes fn WHERE fn.node_id = n.id LIMIT 1), n.name) AS path
    FROM tree
    JOIN nodes n ON n.id = tree.id
    WHERE n.type = 'FRAME'
    ORDER BY n.name COLLATE NOCASE
    LIMIT ?`,
    [input.pageId ?? null, input.pageId ?? null, depth, limit]
  );

  return rows.map((r) => ({
    id: r.id,
    pageId: r.page_id,
    name: r.name,
    bounds: { x: Number(r.x), y: Number(r.y), w: Number(r.w), h: Number(r.h) },
    childCount: Number(r.child_count || 0),
    path: r.path,
  }));
}

export function listFrames(input: { pageId?: string; depth?: number; limit?: number }) {
  const rows = listFrameRows(input);
  return {
    frames: rows.map((r) => ({
      id: r.id,
      name: r.name,
      bounds: r.bounds,
      childCount: r.childCount,
      path: r.path,
    })),
  };
}
