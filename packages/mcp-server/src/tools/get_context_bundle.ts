import fs from "node:fs";
import path from "node:path";
import { one, query } from "../db.js";
import { buildTextRenderHints } from "./text_render_hints.js";

const DATA_DIR = process.env.DATA_DIR ?? "/data";
const CHUNKS_DIR = path.join(DATA_DIR, "chunks");
const PREVIEWS_DIR = path.join(DATA_DIR, "previews");

function sanitizeId(value: string): string {
  return value.replace(/[^a-zA-Z0-9]/g, "_");
}

function b64(bytes: Buffer): string {
  return bytes.toString("base64");
}

function parseJson(raw: string | null): any {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export function getContextBundle(input: { targetIds: string[]; maxBytes?: number }) {
  const maxBytes = input.maxBytes ?? 200000;
  let used = 0;
  const items: Array<{ uri: string; mime: string; bytesBase64: string }> = [];

  const tryPush = (uri: string, mime: string, bytes: Buffer) => {
    if (!bytes.length) return;
    if (used + bytes.length > maxBytes) return;
    used += bytes.length;
    items.push({ uri, mime, bytesBase64: b64(bytes) });
  };

  for (const target of input.targetIds) {
    if (target === "design://manifest") {
      const p = path.join(CHUNKS_DIR, "manifest.json.gz");
      if (fs.existsSync(p)) tryPush(target, "application/gzip", fs.readFileSync(p));
      continue;
    }
    if (target === "design://tokens" || target === "tokens") {
      const p = path.join(CHUNKS_DIR, "tokens.json.gz");
      if (fs.existsSync(p)) tryPush("design://tokens", "application/gzip", fs.readFileSync(p));
      continue;
    }
    if (target === "design://styles" || target === "styles") {
      const p = path.join(CHUNKS_DIR, "styles.json.gz");
      if (fs.existsSync(p)) tryPush("design://styles", "application/gzip", fs.readFileSync(p));
      continue;
    }

    const nodeId = target.startsWith("design://node/") ? target.slice("design://node/".length) : target;
    const pageId = target.startsWith("design://page/") ? target.slice("design://page/".length) : target;

    const node = one<{
      id: string;
      page_id: string;
      parent_id: string | null;
      type: string;
      name: string;
      x: number;
      y: number;
      w: number;
      h: number;
      style_refs_json: string | null;
      style_json: string | null;
      layout_intent_json: string | null;
      computed_json: string | null;
    }>(
      `SELECT id, page_id, parent_id, type, name, x, y, w, h,
        style_refs_json, style_json, layout_intent_json, computed_json
       FROM nodes WHERE id = ?`,
      [nodeId]
    );
    if (node) {
      const style = parseJson(node.style_json);
      const renderHint = buildTextRenderHints(style);
      const payload = {
        id: node.id,
        pageId: node.page_id,
        parentId: node.parent_id,
        type: node.type,
        name: node.name,
        bounds: { x: Number(node.x), y: Number(node.y), w: Number(node.w), h: Number(node.h) },
        styleRefs: parseJson(node.style_refs_json) ?? {},
        style,
        layoutIntent: parseJson(node.layout_intent_json),
        computed: parseJson(node.computed_json),
        renderHints: renderHint ? [renderHint] : [],
      };
      tryPush(
        `design://node/${nodeId}`,
        "application/json",
        Buffer.from(JSON.stringify(payload), "utf8")
      );
      continue;
    }

    const page = one<{ id: string }>("SELECT id FROM pages WHERE id = ?", [pageId]);
    if (page) {
      const p = path.join(CHUNKS_DIR, `page_${sanitizeId(pageId)}.json.gz`);
      if (fs.existsSync(p)) {
        tryPush(`design://page/${pageId}`, "application/gzip", fs.readFileSync(p));
      }
      continue;
    }

    if (target.startsWith("design://preview/")) {
      const file = target.replace("design://preview/", "");
      const p = path.join(PREVIEWS_DIR, file);
      if (fs.existsSync(p)) {
        tryPush(target, "image/png", fs.readFileSync(p));
      }
      continue;
    }
  }

  return { items };
}
