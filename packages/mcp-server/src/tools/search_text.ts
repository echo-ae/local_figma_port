import { query } from "../db.js";
import { toFtsLiteralQuery } from "./fts_query.js";

export type SearchTextRow = {
  nodeId: string;
  pageId: string;
  name: string;
  path: string;
  content: string;
  snippet: string;
  score: number;
  bounds: { x: number; y: number; w: number; h: number };
};

export function searchTextRows(input: { query: string; pageId?: string; limit?: number }): SearchTextRow[] {
  const limit = input.limit ?? 50;
  const clauses: string[] = ["fts_texts MATCH ?"];
  const params: unknown[] = [toFtsLiteralQuery(input.query)];

  if (input.pageId) {
    clauses.push("fts_texts.page_id = ?");
    params.push(input.pageId);
  }

  params.push(limit);

  const hits = query<{
    node_id: string;
    page_id: string;
    name: string;
    content: string;
    snippet: string;
    score: number;
    path: string;
    x: number;
    y: number;
    w: number;
    h: number;
  }>(
    `SELECT fts_texts.node_id, fts_texts.page_id,
      n.name,
      fts_texts.content,
      snippet(fts_texts, 2, '[', ']', '...', 16) AS snippet,
      bm25(fts_texts) AS score,
      COALESCE((SELECT path FROM fts_nodes WHERE node_id = fts_texts.node_id LIMIT 1), '') AS path,
      n.x,
      n.y,
      n.w,
      n.h
     FROM fts_texts
     JOIN nodes n ON n.id = fts_texts.node_id
     WHERE ${clauses.join(" AND ")}
     ORDER BY score
     LIMIT ?`,
    params
  );

  return hits.map((h) => ({
    nodeId: h.node_id,
    pageId: h.page_id,
    name: h.name,
    path: h.path,
    content: h.content,
    snippet: h.snippet,
    score: Number(h.score),
    bounds: { x: Number(h.x), y: Number(h.y), w: Number(h.w), h: Number(h.h) },
  }));
}

export function searchText(input: { query: string; pageId?: string; limit?: number }) {
  const hits = searchTextRows(input);
  return {
    hits: hits.map((h) => ({
      nodeId: h.nodeId,
      pageId: h.pageId,
      path: h.path,
      snippet: h.snippet,
      score: h.score,
    })),
  };
}
