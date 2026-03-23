import { query } from "../db.js";

export function findByToken(input: { tokenKey: string; limit?: number }) {
  const limit = input.limit ?? 200;
  const usages = query<{
    token_key: string;
    node_id: string;
    prop: string;
    mode: string | null;
    path: string;
    page_id: string;
  }>(
    `SELECT tu.token_key, tu.node_id, tu.prop, tu.mode,
      COALESCE((SELECT path FROM fts_nodes WHERE node_id = tu.node_id LIMIT 1), '') AS path,
      n.page_id
     FROM token_usages tu
     JOIN nodes n ON n.id = tu.node_id
     WHERE tu.token_key = ?
     ORDER BY n.page_id, tu.node_id
     LIMIT ?`,
    [input.tokenKey, limit]
  );

  return {
    usages: usages.map((u) => ({
      tokenKey: u.token_key,
      nodeId: u.node_id,
      prop: u.prop,
      mode: u.mode,
      pageId: u.page_id,
      path: u.path,
    })),
  };
}
