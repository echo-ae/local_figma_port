import http from "node:http";
import { URL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
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
import { getResource } from "./resources/handlers.js";
import { validateToolInput, validateToolOutput } from "./schema/validate.js";

const PORT = Number(process.env.MCP_PORT ?? 7331);
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = process.env.PROJECT_ROOT ?? path.resolve(MODULE_DIR, "..", "..", "..");
const IMPORTS_DIR = process.env.IMPORTS_DIR ?? path.join(ROOT_DIR, "imports");
const UIKIT_IMPORTS_DIR = process.env.UIKIT_IMPORTS_DIR ?? path.join(ROOT_DIR, "import-ui-kit");
const DATA_DIR = process.env.DATA_DIR ?? path.join(ROOT_DIR, "data");
const CHUNKS_DIR = process.env.CHUNKS_DIR ?? path.join(DATA_DIR, "chunks");
const SQLITE_PATH = process.env.SQLITE_PATH ?? path.join(DATA_DIR, "design_store.sqlite");
const DDL_PATH = process.env.DDL_PATH ?? path.join(ROOT_DIR, "sql", "design_store.v1.sql");
const IMPORTER_MANIFEST = process.env.IMPORTER_MANIFEST ?? path.join(ROOT_DIR, "packages", "design-importer", "Cargo.toml");
const IMPORT_INCREMENTAL = process.env.IMPORT_INCREMENTAL ?? "false";
let importInProgress = false;

type ToolName =
  | "list_pages"
  | "list_frames"
  | "get_node"
  | "search_nodes"
  | "search_text"
  | "find_by_token"
  | "layout_report"
  | "get_context_bundle"
  | "resolve_instance";

const handlers: Record<ToolName, (input: any) => any> = {
  list_pages: () => listPages(),
  list_frames: (input) => listFrames(input),
  get_node: (input) => getNode(input),
  search_nodes: (input) => searchNodes(input),
  search_text: (input) => searchText(input),
  find_by_token: (input) => findByToken(input),
  layout_report: (input) => layoutReport(input),
  get_context_bundle: (input) => getContextBundle(input),
  resolve_instance: (input) => resolveInstance(input),
};

function json(res: http.ServerResponse, status: number, body: unknown) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function withCors(res: http.ServerResponse): void {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
}

function readBody(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function routeToolName(url: URL): ToolName | null {
  const m = url.pathname.match(/^\/tools\/([a-z_]+)$/);
  if (!m) return null;
  const name = m[1] as ToolName;
  if (!handlers[name]) return null;
  return name;
}

type IncomingBundleRequest = {
  mode?: "design" | "uikit";
  payload?: unknown;
  manifest?: unknown;
  files?: unknown;
};

type BundlePayload = {
  manifest: unknown;
  files: unknown[];
};

function asBundlePayload(body: unknown): { mode: "design" | "uikit"; payload: BundlePayload } {
  const req = (body ?? {}) as IncomingBundleRequest;
  const mode = req.mode === "uikit" ? "uikit" : "design";
  const src = req.payload && typeof req.payload === "object" ? req.payload as Record<string, unknown> : req as unknown as Record<string, unknown>;
  const manifest = src.manifest;
  const files = src.files;
  if (!manifest || typeof manifest !== "object") {
    throw new Error("Invalid bundle: missing manifest");
  }
  if (!Array.isArray(files)) {
    throw new Error("Invalid bundle: missing files[]");
  }
  return { mode, payload: { manifest, files } };
}

function runImporter(): { success: boolean; stderr?: string } {
  try {
    fs.mkdirSync(CHUNKS_DIR, { recursive: true });
    execFileSync(
      "cargo",
      [
        "run",
        "--manifest-path",
        IMPORTER_MANIFEST,
        "--",
        "import",
        "--input",
        IMPORTS_DIR,
        "--ui-kit-input",
        UIKIT_IMPORTS_DIR,
        "--sqlite",
        SQLITE_PATH,
        "--ddl",
        DDL_PATH,
        "--write-chunks",
        CHUNKS_DIR,
        "--incremental",
        IMPORT_INCREMENTAL,
        "--recompute-spacing",
        "true",
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    return { success: true };
  } catch (e) {
    const err = e as { message?: string; stderr?: string | Buffer };
    const stderr = typeof err?.stderr === "string"
      ? err.stderr
      : Buffer.isBuffer(err?.stderr)
        ? err.stderr.toString("utf8")
        : "";
    const detail = [
      err?.message ?? "importer failed",
      stderr.trim(),
    ].filter(Boolean).join("\n");
    return { success: false, stderr: detail };
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (!req.url || !req.method) {
      return json(res, 400, { error: "Malformed request" });
    }

    const url = new URL(req.url, `http://127.0.0.1:${PORT}`);

    if (req.method === "OPTIONS") {
      withCors(res);
      res.writeHead(204);
      res.end();
      return;
    }

    if (req.method === "GET" && url.pathname === "/healthz") {
      return json(res, 200, { ok: true });
    }

    if (req.method === "GET" && url.pathname === "/tools") {
      return json(res, 200, {
        version: "mcp-tools.v1",
        tools: Object.keys(handlers),
      });
    }

    if (req.method === "GET" && url.pathname === "/resource") {
      const uri = url.searchParams.get("uri");
      if (!uri) return json(res, 400, { error: "Missing uri query parameter" });
      const resource = getResource(uri);
      if (!resource) return json(res, 404, { error: "Resource not found" });

      if (typeof resource.body === "string") {
        withCors(res);
        res.writeHead(200, { "Content-Type": resource.mime });
        res.end(resource.body);
      } else {
        withCors(res);
        res.writeHead(200, { "Content-Type": resource.mime });
        res.end(resource.body);
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/import-bundle") {
      if (importInProgress) {
        return json(res, 409, { ok: false, error: "Import is already in progress" });
      }
      const body = await readBody(req);
      const { mode, payload } = asBundlePayload(body);
      const targetDir = mode === "uikit" ? UIKIT_IMPORTS_DIR : IMPORTS_DIR;
      fs.mkdirSync(targetDir, { recursive: true });
      const target = path.join(targetDir, "plugin-export.bundle.json");
      fs.writeFileSync(target, JSON.stringify(payload, null, 2), "utf8");
      importInProgress = true;
      let importResult: { success: boolean; stderr?: string };
      try {
        importResult = runImporter();
      } finally {
        importInProgress = false;
      }
      if (!importResult.success) {
        return json(res, 500, {
          ok: false,
          error: `Bundle saved, but importer failed${importResult.stderr ? `: ${importResult.stderr}` : ""}`,
          mode,
          target,
          import: importResult,
        });
      }
      return json(res, 200, {
        ok: true,
        mode,
        target,
        import: importResult,
      });
    }

    if (req.method === "POST") {
      const tool = routeToolName(url);
      if (!tool) {
        return json(res, 404, { error: "Unknown tool endpoint" });
      }
      const body = await readBody(req);
      const input = (body && typeof body === "object" && "input" in body) ? body.input : body;
      validateToolInput(tool, input);
      const output = handlers[tool](input);
      validateToolOutput(tool, output);
      return json(res, 200, output);
    }

    return json(res, 404, { error: "Not found" });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Internal server error";
    return json(res, 400, { error: message });
  }
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[mcp-server] listening on :${PORT}`);
});
