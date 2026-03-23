import fs from "node:fs";
import path from "node:path";
import { PNG } from "pngjs";
import { one } from "../db.js";
import { readNodeTree } from "../tools/node_payload.js";

const DATA_DIR = process.env.DATA_DIR ?? "/data";
const CHUNKS_DIR = path.join(DATA_DIR, "chunks");
const PREVIEWS_DIR = path.join(DATA_DIR, "previews");
const ASSETS_DIR = path.join(DATA_DIR, "assets");
const SVG_ASSETS_DIR = path.join(ASSETS_DIR, "svg");
const IMAGE_ASSETS_DIR = path.join(ASSETS_DIR, "images");
const CODEX_HOME_DIR = process.env.CODEX_HOME ?? path.join(process.env.HOME ?? "", ".codex");
const DISPLAY_PREVIEWS_DIR =
  process.env.LOCAL_FIGMA_PORT_DISPLAY_PREVIEWS_DIR ??
  path.join(CODEX_HOME_DIR, "cache", "local-figma-port-previews");
const CHAT_PREVIEW_MODE = (process.env.LOCAL_FIGMA_PORT_CHAT_PREVIEW_MODE ?? "raw").trim().toLowerCase();
const CHECKER_TILE_SIZE = Math.max(
  2,
  Number.parseInt(process.env.LOCAL_FIGMA_PORT_CHAT_PREVIEW_CHECKER_SIZE ?? "8", 10) || 8
);

type ChatPreviewMode = "raw" | "checker";
type DisplayPreview = {
  requestedMode: ChatPreviewMode;
  effectiveMode: ChatPreviewMode;
  path: string;
};

function sanitizeId(value: string): string {
  return value.replace(/[^a-zA-Z0-9]/g, "_");
}

function resolveChatPreviewMode(): ChatPreviewMode {
  return CHAT_PREVIEW_MODE === "checker" ? "checker" : "raw";
}

function safeOne<T>(sql: string, params: unknown[] = []): T | null {
  try {
    return one<T>(sql, params);
  } catch {
    return null;
  }
}

function hasTable(name: string): boolean {
  const row = safeOne<{ v: number }>(
    "SELECT 1 AS v FROM sqlite_master WHERE type = 'table' AND name = ?",
    [name]
  );
  return !!row?.v;
}

function toMarkdownImagePath(filePath: string): string {
  return path.isAbsolute(filePath) ? filePath.split(path.sep).join("/") : filePath;
}

function hasTransparency(png: PNG): boolean {
  for (let idx = 3; idx < png.data.length; idx += 4) {
    if (png.data[idx] < 255) return true;
  }
  return false;
}

function compositeCheckerPreview(src: string, dst: string): boolean {
  const png = PNG.sync.read(fs.readFileSync(src));
  if (!hasTransparency(png)) {
    fs.copyFileSync(src, dst);
    return false;
  }

  const output = new PNG({ width: png.width, height: png.height });
  const light = [235, 235, 235, 255];
  const dark = [210, 210, 210, 255];

  for (let y = 0; y < png.height; y += 1) {
    for (let x = 0; x < png.width; x += 1) {
      const idx = (png.width * y + x) << 2;
      const tile = (Math.floor(x / CHECKER_TILE_SIZE) + Math.floor(y / CHECKER_TILE_SIZE)) % 2 === 0;
      const background = tile ? light : dark;
      const alpha = png.data[idx + 3] / 255;

      output.data[idx] = Math.round(png.data[idx] * alpha + background[0] * (1 - alpha));
      output.data[idx + 1] = Math.round(png.data[idx + 1] * alpha + background[1] * (1 - alpha));
      output.data[idx + 2] = Math.round(png.data[idx + 2] * alpha + background[2] * (1 - alpha));
      output.data[idx + 3] = 255;
    }
  }

  fs.writeFileSync(dst, PNG.sync.write(output));
  return true;
}

function ensureDisplayPreviewPath(filename: string): DisplayPreview | null {
  try {
    const src = path.join(PREVIEWS_DIR, filename);
    if (!fs.existsSync(src)) return null;

    fs.mkdirSync(DISPLAY_PREVIEWS_DIR, { recursive: true });
    const requestedMode = resolveChatPreviewMode();
    const ext = path.extname(filename) || ".png";
    const stem = path.basename(filename, ext).replace(/[^\w.-]/g, "_");
    const displayFileName =
      requestedMode === "checker" ? `${stem}__checker${ext}` : `${stem}${ext}`;
    const dst = path.join(DISPLAY_PREVIEWS_DIR, displayFileName);

    const srcStat = fs.statSync(src);
    const dstStat = fs.existsSync(dst) ? fs.statSync(dst) : null;
    const sourceHasTransparency =
      requestedMode === "checker" ? hasTransparency(PNG.sync.read(fs.readFileSync(src))) : false;
    const needsRefresh =
      !dstStat ||
      dstStat.mtimeMs < srcStat.mtimeMs ||
      (requestedMode === "raw" && dstStat.size !== srcStat.size);
    let effectiveMode: ChatPreviewMode = requestedMode === "checker" && sourceHasTransparency ? "checker" : "raw";
    if (needsRefresh) {
      if (requestedMode === "checker") {
        effectiveMode = compositeCheckerPreview(src, dst) ? "checker" : "raw";
      } else {
        fs.copyFileSync(src, dst);
      }
    }
    return { requestedMode, effectiveMode, path: dst };
  } catch {
    return null;
  }
}

export function getResource(uri: string): { mime: string; body: Buffer | string } | null {
  if (uri === "design://images") {
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'image_assets_index'");
    if (row?.value) return { mime: "application/json", body: row.value };
    const p = path.join(CHUNKS_DIR, "image_assets.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    return { mime: "application/json", body: "{\"images\":[]}" };
  }

  if (uri.startsWith("design://image/")) {
    const imageId = uri.slice("design://image/".length);
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'image_assets_index'");
    if (row?.value) {
      try {
        const parsed = JSON.parse(row.value) as {
          images?: Array<{ imageId?: string; mime?: string; path?: string }>;
        };
        const images = Array.isArray(parsed.images) ? parsed.images : [];
        const found = images.find((x) => x.imageId === imageId);
        if (found?.imageId) {
          const ext = found.path ? path.extname(found.path) : "";
          const p = path.join(IMAGE_ASSETS_DIR, `${found.imageId}${ext}`);
          if (fs.existsSync(p)) {
            return { mime: found.mime || "application/octet-stream", body: fs.readFileSync(p) };
          }
        }
      } catch {
        // fallback below
      }
    }
    const fallbackCandidates = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bin"];
    for (const ext of fallbackCandidates) {
      const p = path.join(IMAGE_ASSETS_DIR, `${imageId}${ext}`);
      if (fs.existsSync(p)) {
        return { mime: "application/octet-stream", body: fs.readFileSync(p) };
      }
    }
    return null;
  }

  if (uri === "design://assets") {
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'assets_index'");
    if (row?.value) return { mime: "application/json", body: row.value };
    const p = path.join(CHUNKS_DIR, "assets.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    return { mime: "application/json", body: "{\"assets\":[]}" };
  }

  if (uri.startsWith("design://asset/")) {
    const rawId = uri.slice("design://asset/".length);
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'assets_index'");
    if (row?.value) {
      try {
        const parsed = JSON.parse(row.value) as {
          assets?: Array<{
            assetId?: string;
            mime?: string;
            path?: string;
          }>;
        };
        const assets = Array.isArray(parsed.assets) ? parsed.assets : [];
        const found = assets.find((a) => a.assetId === rawId);
        if (found?.assetId) {
          const ext = found.path ? path.extname(found.path) : ".svg";
          const filename = `${found.assetId}${ext || ".svg"}`;
          const p = path.join(SVG_ASSETS_DIR, filename);
          if (fs.existsSync(p)) {
            return {
              mime: found.mime || "image/svg+xml",
              body: fs.readFileSync(p),
            };
          }
        }
      } catch {
        // fallback below
      }
    }
    const svgPath = path.join(SVG_ASSETS_DIR, `${rawId}.svg`);
    if (fs.existsSync(svgPath)) {
      return { mime: "image/svg+xml", body: fs.readFileSync(svgPath) };
    }
    const legacyPath = path.join(ASSETS_DIR, `${rawId}.svg`);
    if (fs.existsSync(legacyPath)) {
      return { mime: "image/svg+xml", body: fs.readFileSync(legacyPath) };
    }
    return null;
  }

  if (uri === "design://selection-previews") {
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'selections_index'");
    if (!row?.value) return { mime: "application/json", body: "{\"items\":[]}" };
    try {
      const parsed = JSON.parse(row.value) as {
        selections?: Array<{
          selectionId?: string;
          name?: string;
          preview?: string;
        }>;
      };
      const selections = Array.isArray(parsed.selections) ? parsed.selections : [];
      const items = selections
        .filter((s) => !!s.selectionId && !!s.preview)
        .map((s) => {
          const file = path.basename(s.preview as string);
          return {
            selectionId: s.selectionId,
            name: s.name ?? s.selectionId,
            previewUri: `design://preview/${file}`,
            previewFileUri: `design://preview-file/${file}`,
          };
        });
      return { mime: "application/json", body: JSON.stringify({ items }) };
    } catch {
      return { mime: "application/json", body: "{\"items\":[]}" };
    }
  }

  if (uri === "design://selections") {
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'selections_index'");
    if (row?.value) return { mime: "application/json", body: row.value };
    const p = path.join(CHUNKS_DIR, "selections.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    return { mime: "application/json", body: "{\"selections\":[]}" };
  }

  if (uri.startsWith("design://selection/")) {
    const selectionId = uri.slice("design://selection/".length);
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'selections_index'");
    if (!row?.value) return null;
    try {
      const parsed = JSON.parse(row.value) as {
        selections?: Array<{
          selectionId?: string;
          name?: string;
          nodeId?: string;
          pageId?: string;
          preview?: string;
        }>;
      };
      const selections = Array.isArray(parsed.selections) ? parsed.selections : [];
      const found = selections.find((s) => s.selectionId === selectionId);
      if (!found) return null;
      return {
        mime: "application/json",
        body: JSON.stringify({
          selectionId: found.selectionId,
          name: found.name,
          nodeId: found.nodeId,
          pageId: found.pageId,
          nodeUri: found.nodeId ? `design://node/${found.nodeId}` : null,
          pageUri: found.pageId ? `design://page/${found.pageId}` : null,
          previewUri: found.preview
            ? `design://preview/${path.basename(found.preview)}`
            : null,
          previewFileUri: found.preview
            ? `design://preview-file/${path.basename(found.preview)}`
            : null,
          previewMarkdownImage: found.preview
            ? (() => {
                const displayPreview = ensureDisplayPreviewPath(path.basename(found.preview));
                return displayPreview
                  ? `![${path.basename(found.preview)}](${toMarkdownImagePath(displayPreview.path)})`
                  : null;
              })()
            : null,
        }),
      };
    } catch {
      return null;
    }
  }

  if (uri === "design://previews") {
    if (!fs.existsSync(PREVIEWS_DIR)) {
      return { mime: "application/json", body: "{\"previews\":[]}" };
    }
    const files = fs
      .readdirSync(PREVIEWS_DIR, { withFileTypes: true })
      .filter((e) => e.isFile())
      .map((e) => e.name)
      .filter((name) => name.toLowerCase().endsWith(".png"))
      .sort((a, b) => a.localeCompare(b));
    return {
      mime: "application/json",
      body: JSON.stringify({
        previews: files.map((name) => ({
          name,
          uri: `design://preview/${name}`,
        })),
      }),
    };
  }

  if (uri === "design://manifest") {
    const p = path.join(CHUNKS_DIR, "manifest.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    const row = one<{ value: string }>("SELECT value FROM meta WHERE key = 'project_manifest'");
    if (row?.value) return { mime: "application/json", body: row.value };
    return null;
  }

  if (uri === "design://tokens") {
    const p = path.join(CHUNKS_DIR, "tokens.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    const row = one<{ json: string }>("SELECT json FROM tokens_raw ORDER BY id DESC LIMIT 1");
    if (row?.json) return { mime: "application/json", body: row.json };
    return null;
  }

  if (uri === "design://styles") {
    const p = path.join(CHUNKS_DIR, "styles.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    return null;
  }

  if (uri === "design://uikit/manifest") {
    if (!hasTable("uikit_pages")) return null;
    const p = path.join(CHUNKS_DIR, "uikit", "manifest.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    const row = safeOne<{ value: string }>("SELECT value FROM meta WHERE key = 'uikit_manifest'");
    if (row?.value) return { mime: "application/json", body: row.value };
    return null;
  }

  if (uri === "design://uikit/tokens") {
    if (!hasTable("uikit_tokens_raw")) return null;
    const p = path.join(CHUNKS_DIR, "uikit", "tokens.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    const row = safeOne<{ json: string }>("SELECT json FROM uikit_tokens_raw ORDER BY id DESC LIMIT 1");
    if (row?.json) return { mime: "application/json", body: row.json };
    return null;
  }

  if (uri === "design://uikit/styles") {
    if (!hasTable("uikit_styles_raw")) return null;
    const p = path.join(CHUNKS_DIR, "uikit", "styles.json.gz");
    if (fs.existsSync(p)) return { mime: "application/gzip", body: fs.readFileSync(p) };
    const row = safeOne<{ json: string }>("SELECT json FROM uikit_styles_raw ORDER BY id DESC LIMIT 1");
    if (row?.json) return { mime: "application/json", body: row.json };
    return null;
  }

  if (uri === "design://uikit/components") {
    if (!hasTable("uikit_components")) return { mime: "application/json", body: "{\"components\":[]}" };
    const row = safeOne<{ json: string }>(
      `SELECT json_object(
         'components',
         COALESCE(json_group_array(
           json_object(
             'id', c.id,
             'pageId', c.page_id,
             'type', c.type,
             'name', c.name,
             'bounds', json_object('x', c.x, 'y', c.y, 'w', c.w, 'h', c.h),
             'variantProps', COALESCE(c.variant_props_json, '{}'),
             'style', COALESCE(c.style_json, 'null'),
             'styleRefs', COALESCE(c.style_refs_json, '{}')
           )
         ), '[]')
       ) AS json
       FROM uikit_components c`
    );
    if (!row?.json) return { mime: "application/json", body: "{\"components\":[]}" };
    return { mime: "application/json", body: row.json };
  }

  if (uri === "design://uikit/mappings") {
    if (!hasTable("uikit_component_usages")) return { mime: "application/json", body: "{\"mappings\":[]}" };
    const row = safeOne<{ json: string }>(
      `SELECT json_object(
         'mappings',
         COALESCE(json_group_array(
           json_object(
             'componentId', u.component_id,
             'componentName', c.name,
             'nodeId', u.node_id,
             'nodeName', u.node_name,
             'nodeType', u.node_type,
             'pageId', u.page_id,
             'matchStrategy', COALESCE(u.match_strategy, 'direct_id')
           )
         ), '[]')
       ) AS json
       FROM uikit_component_usages u
       LEFT JOIN uikit_components c ON c.id = u.component_id`
    );
    if (!row?.json) return { mime: "application/json", body: "{\"mappings\":[]}" };
    return { mime: "application/json", body: row.json };
  }

  if (uri.startsWith("design://page/")) {
    const pageId = uri.slice("design://page/".length);
    const p = path.join(CHUNKS_DIR, `page_${sanitizeId(pageId)}.json.gz`);
    if (!fs.existsSync(p)) return null;
    return { mime: "application/gzip", body: fs.readFileSync(p) };
  }

  if (uri.startsWith("design://node/")) {
    const nodeId = uri.slice("design://node/".length);
    const node = readNodeTree(nodeId, 0);
    if (!node) return null;
    return { mime: "application/json", body: JSON.stringify(node) };
  }

  if (uri.startsWith("design://uikit/component/")) {
    if (!hasTable("uikit_components")) return null;
    const componentId = uri.slice("design://uikit/component/".length);
    const row = one<{ json: string }>(
      `SELECT json_object(
        'component', json_object(
          'id', c.id,
          'pageId', c.page_id,
          'type', c.type,
          'name', c.name,
          'bounds', json_object('x', c.x, 'y', c.y, 'w', c.w, 'h', c.h),
          'variantProps', COALESCE(c.variant_props_json, '{}'),
          'style', COALESCE(c.style_json, 'null'),
          'styleRefs', COALESCE(c.style_refs_json, '{}')
        ),
        'usages', COALESCE((
          SELECT json_group_array(
            json_object(
              'nodeId', u.node_id,
              'pageId', u.page_id,
              'nodeName', u.node_name,
              'nodeType', u.node_type,
              'matchStrategy', COALESCE(u.match_strategy, 'direct_id')
            )
          )
          FROM uikit_component_usages u
          WHERE u.component_id = c.id
        ), '[]')
      ) AS json
      FROM uikit_components c
      WHERE c.id = ?`,
      [componentId]
    );
    if (!row?.json) return null;
    return { mime: "application/json", body: row.json };
  }

  if (uri.startsWith("design://preview/")) {
    const filename = uri.slice("design://preview/".length);
    const p = path.join(PREVIEWS_DIR, filename);
    if (!fs.existsSync(p)) return null;
    return { mime: "image/png", body: fs.readFileSync(p) };
  }

  if (uri.startsWith("design://preview-file/")) {
    const filename = uri.slice("design://preview-file/".length);
    const p = path.join(PREVIEWS_DIR, filename);
    if (!fs.existsSync(p)) return null;
    const displayPreview = ensureDisplayPreviewPath(filename);
    const requestedDisplayMode = resolveChatPreviewMode();
    const displayPath = displayPreview?.path ?? p;
    const effectiveDisplayMode = displayPreview?.effectiveMode ?? "raw";
    return {
      mime: "application/json",
      body: JSON.stringify({
        path: p,
        displayPath,
        requestedDisplayMode,
        effectiveDisplayMode,
        mime: "image/png",
        markdownImage: `![${filename}](${toMarkdownImagePath(displayPath)})`,
        markdownImageVerbatim: `![${filename}](${toMarkdownImagePath(displayPath)})`,
        useMarkdownImageVerbatim: true,
        instructions:
          "Use markdownImageVerbatim exactly as returned. Do not URL-encode spaces or rebuild the markdown from path.",
      }),
    };
  }

  return null;
}
