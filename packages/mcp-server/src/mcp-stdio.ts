import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { listPages } from "./tools/list_pages.js";
import { listFrames } from "./tools/list_frames.js";
import { getNode } from "./tools/get_node.js";
import { searchNodes } from "./tools/search_nodes.js";
import { searchText } from "./tools/search_text.js";
import { findByToken } from "./tools/find_by_token.js";
import { layoutReport } from "./tools/layout_report.js";
import { getContextBundle } from "./tools/get_context_bundle.js";
import { resolveInstance } from "./tools/resolve_instance.js";
import { resolveTarget } from "./tools/resolve_target.js";
import { buildCoverageChecklist } from "./tools/build_coverage_checklist.js";
import { getResource } from "./resources/handlers.js";
import { validateToolInput, validateToolOutput } from "./schema/validate.js";
import { query } from "./db.js";

type JsonRpcId = string | number | null;
type JsonRpcRequest = {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: any;
};

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");
const schemaPath = path.join(repoRoot, "schemas", "mcp-tools.v1.schema.json");
let schema: any = { properties: { tools: { properties: {} } } };
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
} catch {
  schema = { properties: { tools: { properties: {} } } };
}
const toolSchemas = (schema?.properties?.tools?.properties ?? {}) as Record<string, any>;

const toolHandlers: Record<string, (input: any) => any> = {
  list_pages: () => listPages(),
  list_frames: (input) => listFrames(input),
  get_node: (input) => getNode(input),
  search_nodes: (input) => searchNodes(input),
  search_text: (input) => searchText(input),
  find_by_token: (input) => findByToken(input),
  layout_report: (input) => layoutReport(input),
  get_context_bundle: (input) => getContextBundle(input),
  resolve_instance: (input) => resolveInstance(input),
  resolve_target: (input) => resolveTarget(input),
  build_coverage_checklist: (input) => buildCoverageChecklist(input),
};

const toolDescriptions: Record<string, string> = {
  list_pages: "List imported pages.",
  list_frames: "List frame-like nodes for a page.",
  get_node:
    "Fetch one node with normalized layout/style data. If style.text.textRuns has multiple segments, render text as inline spans per segment.",
  search_nodes: "Search nodes by name/path/type.",
  search_text: "Search text content.",
  find_by_token: "Find nodes referencing a token key.",
  layout_report: "Summarize layout intent/computed spacing for a node.",
  get_context_bundle:
    "Pack selected resources into one bounded payload. Node payloads include renderHints for mixed-style text.",
  resolve_instance:
    "Resolve an INSTANCE node into bounded instance, master, and override payloads without expanding default get_node responses.",
  resolve_target:
    "Resolve user-described design intent into ranked page/selection/node candidates. May return multiple candidates and does not auto-pick when ambiguity remains.",
  build_coverage_checklist:
    "Build a target-scoped coverage checklist for a chosen page, selection, or node. Warns when requested UI appears broader than the exported scope.",
};

function assertFtsReady(): void {
  query("SELECT COUNT(*) AS count FROM fts_nodes");
  query("SELECT COUNT(*) AS count FROM fts_texts");
}

assertFtsReady();

let outputMode: "content-length" | "line" = "content-length";

function writeMessage(msg: unknown) {
  const json = JSON.stringify(msg);
  if (outputMode === "line") {
    process.stdout.write(json + "\n", "utf8");
    return;
  }
  const header = `Content-Length: ${Buffer.byteLength(json, "utf8")}\r\n\r\n`;
  process.stdout.write(header, "utf8");
  process.stdout.write(json, "utf8");
}

function sendResult(id: JsonRpcId, result: unknown) {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function sendError(id: JsonRpcId, code: number, message: string, data?: unknown) {
  writeMessage({ jsonrpc: "2.0", id, error: { code, message, data } });
}

function toToolDefinition(name: string) {
  const def = toolSchemas[name];
  return {
    name,
    description: toolDescriptions[name] ?? `Design tool ${name}`,
    inputSchema: def?.properties?.input ?? { type: "object", additionalProperties: false },
  };
}

function bufferToStringBody(body: Buffer | string): { text?: string; blob?: string } {
  if (typeof body === "string") {
    return { text: body };
  }
  return { blob: body.toString("base64") };
}

function handleResourcesList() {
  const resources: Array<{ uri: string; name: string; mimeType: string; description: string }> = [
    {
      uri: "design://manifest",
      name: "manifest",
      mimeType: "application/json",
      description:
        "When to use: start of session to discover export metadata and page IDs. Typical next step: call list_pages or read design://page/{pageId}.",
    },
    {
      uri: "design://tokens",
      name: "tokens",
      mimeType: "application/json",
      description:
        "When to use: inspect token values referenced by nodes. Typical next step: run find_by_token or inspect mapped nodes via search_nodes.",
    },
    {
      uri: "design://styles",
      name: "styles",
      mimeType: "application/json",
      description:
        "When to use: inspect legacy styles used in imported nodes. Typical next step: read target node via get_node and compare styleRefs.",
    },
    {
      uri: "design://assets",
      name: "assets",
      mimeType: "application/json",
      description:
        "When to use: list original exported assets (for example SVG icons). Typical next step: read design://asset/{assetId} for 1:1 geometry and colors.",
    },
    {
      uri: "design://images",
      name: "images",
      mimeType: "application/json",
      description:
        "When to use: list bitmap image assets found in exported nodes. Typical next step: read design://image/{imageId} for original bytes.",
    },
    {
      uri: "design://previews",
      name: "previews",
      mimeType: "application/json",
      description:
        "When to use: discover available preview images. Typical next step: read one design://preview/{fileName}.png and then inspect related nodes.",
    },
    {
      uri: "design://selections",
      name: "selections",
      mimeType: "application/json",
      description:
        "When to use: list named entities exported from multi-selection. Typical next step: read design://selection/{selectionId} for one target entity.",
    },
    {
      uri: "design://selection-previews",
      name: "selection-previews",
      mimeType: "application/json",
      description:
        "When to use: quickly map selection IDs to preview URIs. Typical next step: open previewUri and then read design://selection/{selectionId}.",
    },
    {
      uri: "design://uikit/manifest",
      name: "uikit:manifest",
      mimeType: "application/json",
      description:
        "When to use: confirm UI-kit import metadata and scope. Typical next step: read design://uikit/components or design://uikit/mappings.",
    },
    {
      uri: "design://uikit/components",
      name: "uikit:components",
      mimeType: "application/json",
      description:
        "When to use: inspect available UI-kit components and bounds snapshot. Typical next step: read design://uikit/component/{componentId}.",
    },
    {
      uri: "design://uikit/mappings",
      name: "uikit:mappings",
      mimeType: "application/json",
      description:
        "When to use: map imported nodes to UI-kit components. Typical next step: get_node(nodeId) and compare with uikit/component details.",
    },
    {
      uri: "design://uikit/tokens",
      name: "uikit:tokens",
      mimeType: "application/json",
      description:
        "When to use: inspect UI-kit token values. Typical next step: correlate with design tokens and node styleRefs.",
    },
    {
      uri: "design://uikit/styles",
      name: "uikit:styles",
      mimeType: "application/json",
      description:
        "When to use: inspect UI-kit legacy styles. Typical next step: compare with imported node styles and mappings.",
    },
  ];

  const pages = query<{ id: string; name: string }>("SELECT id, name FROM pages ORDER BY name COLLATE NOCASE");
  for (const p of pages) {
    resources.push({
      uri: `design://page/${p.id}`,
      name: `page:${p.name}`,
      mimeType: "application/gzip",
      description: `When to use: need full normalized chunk for page '${p.name}'. Typical next step: narrow with get_node/list_frames to reduce context size.`,
    });
  }
  const selectionsRow = query<{ value: string }>(
    "SELECT value FROM meta WHERE key = 'selections_index' LIMIT 1"
  );
  if (selectionsRow.length > 0) {
    try {
      const parsed = JSON.parse(selectionsRow[0].value) as {
        selections?: Array<{ selectionId?: string; name?: string }>;
      };
      const items = Array.isArray(parsed.selections) ? parsed.selections : [];
      for (const s of items) {
        if (!s?.selectionId) continue;
        resources.push({
          uri: `design://selection/${s.selectionId}`,
          name: `selection:${s.name ?? s.selectionId}`,
          mimeType: "application/json",
          description:
            "When to use: inspect one exported selection entity. Typical next step: read nodeUri/pageUri from this resource and continue with get_node.",
        });
      }
    } catch {
      // ignore malformed selections index in meta
    }
  }
  const assetsRow = query<{ value: string }>(
    "SELECT value FROM meta WHERE key = 'assets_index' LIMIT 1"
  );
  if (assetsRow.length > 0) {
    try {
      const parsed = JSON.parse(assetsRow[0].value) as {
        assets?: Array<{ assetId?: string; name?: string; mime?: string }>;
      };
      const items = Array.isArray(parsed.assets) ? parsed.assets : [];
      for (const a of items) {
        if (!a?.assetId) continue;
        resources.push({
          uri: `design://asset/${a.assetId}`,
          name: `asset:${a.name ?? a.assetId}`,
          mimeType: a.mime ?? "application/octet-stream",
          description:
            "When to use: fetch one original exported asset file. Typical next step: compare with rendered output or embed directly.",
        });
      }
    } catch {
      // ignore malformed assets index
    }
  }
  const imageAssetsRow = query<{ value: string }>(
    "SELECT value FROM meta WHERE key = 'image_assets_index' LIMIT 1"
  );
  if (imageAssetsRow.length > 0) {
    try {
      const parsed = JSON.parse(imageAssetsRow[0].value) as {
        images?: Array<{ imageId?: string; name?: string; mime?: string }>;
      };
      const items = Array.isArray(parsed.images) ? parsed.images : [];
      for (const img of items) {
        if (!img?.imageId) continue;
        resources.push({
          uri: `design://image/${img.imageId}`,
          name: `image:${img.name ?? img.imageId}`,
          mimeType: img.mime ?? "application/octet-stream",
          description:
            "When to use: fetch one original bitmap image from export. Typical next step: render or compare against node style/image refs.",
        });
      }
    } catch {
      // ignore malformed image assets index
    }
  }
  const hasUikitTable =
    query<{ v: number }>(
      "SELECT 1 AS v FROM sqlite_master WHERE type = 'table' AND name = 'uikit_components' LIMIT 1"
    ).length > 0;

  let uikitComponents: Array<{ id: string; name: string }> = [];
  if (hasUikitTable) {
    uikitComponents = query<{ id: string; name: string }>(
      "SELECT id, name FROM uikit_components ORDER BY name COLLATE NOCASE LIMIT 500"
    );
  }
  for (const c of uikitComponents) {
    resources.push({
      uri: `design://uikit/component/${c.id}`,
      name: `uikit:component:${c.name}`,
      mimeType: "application/json",
      description: `When to use: inspect UI-kit component '${c.name}' with usages. Typical next step: open mapped node IDs with get_node.`,
    });
  }

  return { resources };
}

function negotiatedProtocolVersion(req: JsonRpcRequest): string {
  const p = req.params?.protocolVersion;
  if (typeof p === "string" && p.length > 0) {
    return p;
  }
  return "2025-06-18";
}

function handleRequest(req: JsonRpcRequest) {
  const id: JsonRpcId = req.id ?? null;

  try {
    if (req.method === "initialize") {
      return sendResult(id, {
        protocolVersion: negotiatedProtocolVersion(req),
        capabilities: {
          tools: {},
          resources: {},
        },
        serverInfo: {
          name: "Local Figma Port",
          version: "0.1.0",
        },
      });
    }

    if (req.method === "notifications/initialized") {
      return;
    }

    if (req.method === "ping") {
      return sendResult(id, {});
    }

    if (req.method === "tools/list") {
      return sendResult(id, { tools: Object.keys(toolHandlers).map(toToolDefinition) });
    }

    if (req.method === "tools/call") {
      const name = req.params?.name as string;
      const args = req.params?.arguments ?? {};
      const handler = toolHandlers[name];
      if (!handler) {
        return sendResult(id, {
          isError: true,
          content: [{ type: "text", text: `Unknown tool: ${name}` }],
        });
      }

      try {
        validateToolInput(name, args);
        const output = handler(args);
        validateToolOutput(name, output);
        return sendResult(id, {
          content: [{ type: "text", text: JSON.stringify(output) }],
          structuredContent: output,
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : "tool execution failed";
        return sendResult(id, {
          isError: true,
          content: [{ type: "text", text: message }],
        });
      }
    }

    if (req.method === "resources/list") {
      return sendResult(id, handleResourcesList());
    }

    if (req.method === "resources/templates/list") {
      return sendResult(id, {
        resourceTemplates: [
          {
            uriTemplate: "design://page/{pageId}",
            name: "page",
            description:
              "When to use: need complete page chunk by ID. Typical next step: query list_frames/get_node for focused analysis.",
            mimeType: "application/gzip",
          },
          {
            uriTemplate: "design://node/{nodeId}",
            name: "node",
            description:
              "When to use: inspect one node deeply (layout/style/refs). Typical next step: if style.text.textRuns has multiple segments, render text as ordered <span> segments.",
            mimeType: "application/json",
          },
          {
            uriTemplate: "design://preview/{frameId}.png",
            name: "preview",
            description:
              "When to use: need visual grounding for a frame/selection. Typical next step: use design://previews first, then read one preview URI.",
            mimeType: "image/png",
          },
          {
            uriTemplate: "design://preview-file/{frameId}.png",
            name: "preview-file",
            description:
              "When to use: need an app-friendly preview for chat/UI rendering. Typical next step: embed markdownImageVerbatim; use design://preview/{fileName}.png for the clean source PNG.",
            mimeType: "application/json",
          },
          {
            uriTemplate: "design://selection/{selectionId}",
            name: "selection",
            description:
              "When to use: inspect one named selection entity from design://selections. Typical next step: open nodeUri with get_node and previewUri for visual check.",
            mimeType: "application/json",
          },
          {
            uriTemplate: "design://asset/{assetId}",
            name: "asset",
            description:
              "When to use: fetch one original asset file by ID. Typical next step: use it as canonical icon/vector source instead of reconstructed SVG.",
            mimeType: "application/octet-stream",
          },
          {
            uriTemplate: "design://image/{imageId}",
            name: "image",
            description:
              "When to use: fetch one exported bitmap image by ID. Typical next step: use it directly in rendering or visual diff checks.",
            mimeType: "application/octet-stream",
          },
          {
            uriTemplate: "design://selection-previews",
            name: "selection-previews",
            description:
              "When to use: get a compact list of preview URIs for exported selections. Typical next step: read one preview and resolve selection details.",
            mimeType: "application/json",
          },
          {
            uriTemplate: "design://uikit/component/{componentId}",
            name: "uikit-component",
            description:
              "When to use: inspect one UI-kit component and linked imported nodes. Typical next step: get_node on returned node IDs.",
            mimeType: "application/json",
          },
        ],
      });
    }

    if (req.method === "resources/read") {
      const uri = req.params?.uri as string;
      if (!uri) {
        return sendError(id, -32602, "resources/read requires uri");
      }
      const resource = getResource(uri);
      if (!resource) {
        return sendError(id, -32602, `Resource not found: ${uri}`);
      }
      const body = bufferToStringBody(resource.body as Buffer | string);
      return sendResult(id, {
        contents: [
          {
            uri,
            mimeType: resource.mime,
            ...body,
          },
        ],
      });
    }

    return sendError(id, -32601, `Method not found: ${req.method}`);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal error";
    return sendError(id, -32603, message);
  }
}

let incoming = Buffer.alloc(0);

function findHeaderEnd(buf: Buffer): { index: number; sepLen: number } | null {
  const crlf = buf.indexOf("\r\n\r\n");
  const lf = buf.indexOf("\n\n");
  if (crlf === -1 && lf === -1) return null;
  if (crlf === -1) return { index: lf, sepLen: 2 };
  if (lf === -1) return { index: crlf, sepLen: 4 };
  return crlf < lf ? { index: crlf, sepLen: 4 } : { index: lf, sepLen: 2 };
}

process.stdin.on("data", (chunk: Buffer) => {
  incoming = Buffer.concat([incoming, chunk]);

  while (true) {
    const header = findHeaderEnd(incoming);
    if (!header) {
      outputMode = "line";
      const nl = incoming.indexOf("\n");
      if (nl === -1) break;
      const line = incoming.slice(0, nl).toString("utf8").trim();
      incoming = incoming.slice(nl + 1);
      if (!line) continue;
      try {
        const req = JSON.parse(line) as JsonRpcRequest;
        if (req && req.jsonrpc === "2.0" && typeof req.method === "string") {
          handleRequest(req);
        }
      } catch {
        // ignore malformed line
      }
      continue;
    }

    const headerEnd = header.index;
    const sepLen = header.sepLen;
    outputMode = "content-length";
    const headerText = incoming.slice(0, headerEnd).toString("utf8");
    const lines = headerText.split(/\r?\n/);
    let contentLength = 0;

    for (const line of lines) {
      const idx = line.indexOf(":");
      if (idx === -1) continue;
      const key = line.slice(0, idx).trim().toLowerCase();
      const value = line.slice(idx + 1).trim();
      if (key === "content-length") {
        contentLength = Number(value);
      }
    }

    const totalLen = headerEnd + sepLen + contentLength;
    if (incoming.length < totalLen) break;

    const body = incoming.slice(headerEnd + sepLen, totalLen).toString("utf8");
    incoming = incoming.slice(totalLen);

    try {
      const req = JSON.parse(body) as JsonRpcRequest;
      if (req && req.jsonrpc === "2.0" && typeof req.method === "string") {
        handleRequest(req);
      }
    } catch {
      // ignore malformed message
    }
  }
});

process.stdin.resume();
