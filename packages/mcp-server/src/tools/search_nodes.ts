import { query } from "../db.js";
import { toFtsLiteralQuery } from "./fts_query.js";

export type SearchNodeRow = {
  nodeId: string;
  pageId: string;
  type: string;
  name: string;
  path: string;
  snippet: string;
  score: number;
  bounds: { x: number; y: number; w: number; h: number };
};

export function searchNodeRows(input: { query: string; pageId?: string; types?: string[]; limit?: number }): SearchNodeRow[] {
  const limit = input.limit ?? 20;
  const clauses: string[] = ["fts_nodes MATCH ?"];
  const params: unknown[] = [toFtsLiteralQuery(input.query)];

  if (input.pageId) {
    clauses.push("fts_nodes.page_id = ?");
    params.push(input.pageId);
  }

  if (input.types && input.types.length) {
    clauses.push(`n.type IN (${input.types.map(() => "?").join(",")})`);
    params.push(...input.types);
  }

  params.push(limit);

  const rows = query<{
    node_id: string;
    page_id: string;
    type: string;
    name: string;
    x: number;
    y: number;
    w: number;
    h: number;
    path: string;
    snippet: string;
    score: number;
  }>(
    `SELECT fts_nodes.node_id,
      n.page_id,
      n.type,
      n.name,
      n.x,
      n.y,
      n.w,
      n.h,
      fts_nodes.path,
      snippet(fts_nodes, 4, '[', ']', '...', 12) AS snippet,
      bm25(fts_nodes) AS score
     FROM fts_nodes
     JOIN nodes n ON n.id = fts_nodes.node_id
     WHERE ${clauses.join(" AND ")}
     ORDER BY score
     LIMIT ?`,
    params
  );

  return rows.map((r) => ({
    nodeId: r.node_id,
    pageId: r.page_id,
    type: r.type,
    name: r.name,
    path: r.path,
    snippet: r.snippet,
    score: Number(r.score),
    bounds: { x: Number(r.x), y: Number(r.y), w: Number(r.w), h: Number(r.h) },
  }));
}

export function searchNodes(input: { query: string; pageId?: string; types?: string[]; limit?: number }) {
  const rows = searchNodeRows(input);
  return {
    hits: rows.map((r) => ({
      nodeId: r.nodeId,
      path: r.path,
      snippet: r.snippet,
      score: r.score,
    })),
  };
}
