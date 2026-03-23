import { query } from "../db.js";

export function listPages() {
  const pages = query<{ id: string; name: string; frame_count: number }>(
    "SELECT id, name, frame_count FROM pages ORDER BY name COLLATE NOCASE"
  ).map((r) => ({ id: r.id, name: r.name, frameCount: Number(r.frame_count || 0) }));
  return { pages };
}
