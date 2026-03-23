import {
  extractNodeFidelity,
  normalizeName,
} from "./export/extract-node-fidelity";

type ExportPage = {
  id: string;
  name: string;
  hash: string;
  nodeChunk: string;
};

type PluginExportManifest = {
  version: "plugin-export.v1";
  manifest: {
    exportId: string;
    fileKey: string;
    exportedAt: string;
    pages: ExportPage[];
    tokensChunk?: string;
    stylesChunk?: string;
  };
  chunks: {
    nodes: string[];
    tokens?: string;
    styles?: string;
    previews?: string[];
  };
};

type ExportFile = {
  path: string;
  mime: string;
  bytesBase64: string;
  encoding?: "binary-base64" | "json-utf8";
};

type ExportMode = "design" | "uikit";

type SelectionIndexEntry = {
  selectionId: string;
  name: string;
  nodeId: string;
  pageId: string;
  preview?: string;
};

type AssetIndexEntry = {
  assetId: string;
  name: string;
  nodeId: string;
  pageId: string;
  mime: string;
  path: string;
};

type ImageAssetIndexEntry = {
  imageId: string;
  hash: string;
  name: string;
  nodeId: string;
  pageId: string;
  mime: string;
  path: string;
};

function createHash(input: string): string {
  let h = 2166136261;
  for (let i = 0; i < input.length; i += 1) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

function computeBaseSpacing(node: SceneNode): unknown {
  if (
    !("children" in node) ||
    !Array.isArray(node.children) ||
    node.children.length < 2
  ) {
    return { confidence: { spacingInference: 0 } };
  }

  const children = node.children.filter((c) => c.visible) as SceneNode[];
  if (children.length < 2) {
    return { confidence: { spacingInference: 0 } };
  }

  let axis: "x" | "y" = "x";
  if (
    "layoutMode" in node &&
    (node.layoutMode === "VERTICAL" || node.layoutMode === "HORIZONTAL")
  ) {
    axis = node.layoutMode === "HORIZONTAL" ? "x" : "y";
  } else {
    const xs = children.map((c) => c.x);
    const ys = children.map((c) => c.y);
    const sx = Math.max(...xs) - Math.min(...xs);
    const sy = Math.max(...ys) - Math.min(...ys);
    axis = sx >= sy ? "x" : "y";
  }

  const sorted = [...children].sort((a, b) =>
    axis === "x" ? a.x - b.x : a.y - b.y,
  );
  const gapsBetween = [] as Array<{
    a: string;
    b: string;
    axis: "x" | "y";
    value: number;
  }>;

  for (let i = 0; i < sorted.length - 1; i += 1) {
    const a = sorted[i];
    const b = sorted[i + 1];
    const aEnd = axis === "x" ? a.x + a.width : a.y + a.height;
    const bStart = axis === "x" ? b.x : b.y;
    gapsBetween.push({
      a: a.id,
      b: b.id,
      axis,
      value: Math.max(0, bStart - aEnd),
    });
  }

  return {
    gapsBetween,
    confidence: { spacingInference: 1 },
  };
}

function exportNode(node: SceneNode, pageId: string): any {
  let variantProps: Record<string, string> | undefined = undefined;
  if ("variantProperties" in node) {
    try {
      variantProps = (node as any).variantProperties ?? undefined;
    } catch {
      variantProps = undefined;
    }
  }

  const fidelity = extractNodeFidelity(node);
  const data: any = {
    id: node.id,
    type: node.type,
    name: normalizeName(node),
    pageId,
    parentId: node.parent ? node.parent.id : undefined,
    childrenIds:
      "children" in node
        ? (node as ChildrenMixin).children.map((c) => c.id)
        : [],
    bounds: { x: node.x, y: node.y, w: node.width, h: node.height },
    absBounds: {
      x: node.absoluteTransform[0][2],
      y: node.absoluteTransform[1][2],
      w: node.width,
      h: node.height,
    },
    componentId:
      "mainComponent" in node && (node as InstanceNode).mainComponent
        ? (node as InstanceNode).mainComponent!.id
        : undefined,
    variantProps,
    layout: fidelity.layout,
    style: fidelity.style,
    refs: fidelity.refs,
    resources: fidelity.resources,
    inspectionHints: fidelity.inspectionHints,
    computed: computeBaseSpacing(node),
  };

  if (node.type === "TEXT") {
    data.characters = node.characters;
    data.text = { content: node.characters };
  }

  return data;
}

function nextTick(): Promise<void> {
  return Promise.resolve();
}

async function exportPageFromRoots(
  page: PageNode,
  roots: SceneNode[],
): Promise<{ pageChunk: any; hash: string }> {
  const out: any[] = [];
  const stack: SceneNode[] = [];
  for (let i = roots.length - 1; i >= 0; i -= 1) {
    stack.push(roots[i]);
  }

  let processed = 0;
  while (stack.length > 0) {
    const n = stack.pop() as SceneNode;
    out.push(exportNode(n, page.id));
    if ("children" in n) {
      const children = (n as ChildrenMixin).children;
      for (let i = children.length - 1; i >= 0; i -= 1) {
        stack.push(children[i] as SceneNode);
      }
    }
    processed += 1;
    if (processed % 250 === 0) {
      await nextTick();
    }
  }

  const pageChunk = {
    pageId: page.id,
    pageName: page.name,
    nodes: out,
  };
  return {
    pageChunk,
    hash: createHash(JSON.stringify(pageChunk)),
  };
}

function exportVariables(): unknown {
  const varsApi = (figma as any).variables;
  if (!varsApi || typeof varsApi.getLocalVariableCollections !== "function") {
    return { collections: [], variables: [] };
  }
  const collections =
    varsApi.getLocalVariableCollections() as VariableCollection[];
  const variables: Array<{
    id: string;
    key: string;
    name: string;
    resolvedType: VariableResolvedDataType;
    valuesByMode: Record<string, VariableValue>;
    scopes: VariableScope[];
  }> = [];

  for (const c of collections) {
    for (const id of c.variableIds) {
      const v = varsApi.getVariableById(id) as Variable | null;
      if (!v) continue;
      variables.push({
        id: v.id,
        key: `var:${v.name}`,
        name: v.name,
        resolvedType: v.resolvedType,
        valuesByMode: v.valuesByMode,
        scopes: v.scopes,
      });
    }
  }

  return {
    collections: collections.map((c) => ({
      id: c.id,
      name: c.name,
      modes: c.modes,
      variableIds: c.variableIds,
    })),
    variables,
  };
}

function exportStyles(): unknown {
  if (typeof (figma as any).getLocalPaintStyles !== "function") {
    return { styles: [] };
  }
  const paints = figma.getLocalPaintStyles().map((s) => ({
    id: s.id,
    key: `style:${s.key || s.id}`,
    name: s.name,
    type: "PAINT",
    paints: s.paints,
  }));

  const effects = figma.getLocalEffectStyles().map((s) => ({
    id: s.id,
    key: `style:${s.key || s.id}`,
    name: s.name,
    type: "EFFECT",
    effects: s.effects,
  }));

  const grids = figma.getLocalGridStyles().map((s) => ({
    id: s.id,
    key: `style:${s.key || s.id}`,
    name: s.name,
    type: "GRID",
    layoutGrids: s.layoutGrids,
  }));

  const texts = figma.getLocalTextStyles().map((s) => ({
    id: s.id,
    key: `style:${s.key || s.id}`,
    name: s.name,
    type: "TEXT",
    fontName: s.fontName,
    fontSize: s.fontSize,
    letterSpacing: s.letterSpacing,
    lineHeight: s.lineHeight,
    textCase: s.textCase,
    textDecoration: s.textDecoration,
  }));

  return { styles: [...paints, ...effects, ...grids, ...texts] };
}

function toUtf8Bytes(value: unknown): Uint8Array {
  return encodeUtf8(JSON.stringify(value));
}

function encodeUtf8(input: string): Uint8Array {
  const escaped = unescape(encodeURIComponent(input));
  const bytes = new Uint8Array(escaped.length);
  for (let i = 0; i < escaped.length; i += 1) {
    bytes[i] = escaped.charCodeAt(i);
  }
  return bytes;
}

function toBase64(bytes: Uint8Array): string {
  const table =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += table[(n >>> 18) & 63];
    out += table[(n >>> 12) & 63];
    out += table[(n >>> 6) & 63];
    out += table[n & 63];
  }
  if (i < bytes.length) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const n = (a << 16) | (b << 8);
    out += table[(n >>> 18) & 63];
    out += table[(n >>> 12) & 63];
    out += i + 1 < bytes.length ? table[(n >>> 6) & 63] : "=";
    out += "=";
  }
  return out;
}

function sanitizeFilePart(input: string): string {
  const trimmed = (input || "unnamed").trim();
  const safe = trimmed
    .replace(/[^a-zA-Z0-9._-]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return safe || "unnamed";
}

function detectImageType(bytes: Uint8Array): { ext: string; mime: string } {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47
  ) {
    return { ext: "png", mime: "image/png" };
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return { ext: "jpg", mime: "image/jpeg" };
  }
  if (
    bytes.length >= 6 &&
    bytes[0] === 0x47 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x38
  ) {
    return { ext: "gif", mime: "image/gif" };
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return { ext: "webp", mime: "image/webp" };
  }
  return { ext: "bin", mime: "application/octet-stream" };
}

function imageHashesFromNode(node: SceneNode): string[] {
  const out: string[] = [];
  const collectFromPaints = (arr: ReadonlyArray<Paint> | PluginAPI["mixed"] | undefined) => {
    if (!Array.isArray(arr)) return;
    for (const p of arr) {
      if (p.type === "IMAGE" && p.imageHash) out.push(p.imageHash);
    }
  };
  if ("fills" in node) {
    collectFromPaints((node as GeometryMixin).fills as any);
  }
  if ("strokes" in node) {
    collectFromPaints((node as GeometryMixin).strokes as any);
  }
  return out;
}

function collectImageNodesFromRoots(roots: SceneNode[]): SceneNode[] {
  const out: SceneNode[] = [];
  const stack = [...roots];
  while (stack.length) {
    const n = stack.pop() as SceneNode;
    out.push(n);
    if ("children" in n) {
      for (const c of (n as ChildrenMixin).children) {
        stack.push(c as SceneNode);
      }
    }
  }
  return out;
}

async function exportPreviewFile(
  node: SceneNode,
  path: string,
): Promise<ExportFile> {
  const bytes = await node.exportAsync({ format: "PNG" });
  return {
    path,
    mime: "image/png",
    bytesBase64: toBase64(bytes),
    encoding: "binary-base64",
  };
}

async function exportSvgFile(
  node: SceneNode,
  outPath: string,
): Promise<ExportFile> {
  const raw = await node.exportAsync({ format: "SVG" });
  const bytes =
    typeof raw === "string" ? encodeUtf8(raw) : (raw as Uint8Array);
  return {
    path: outPath,
    mime: "image/svg+xml",
    bytesBase64: toBase64(bytes),
    encoding: "binary-base64",
  };
}

const UI_HTML = `
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <style>
      :root {
        --bg: #f3f5ef;
        --ink: #252a24;
        --muted: #55614c;
        --card: #fbfcf7;
        --line: #d3dcc7;
        --brand: #2d6a4f;
        --brand-ink: #f5fff9;
        --accent: #d7f4d2;
        --shadow: 0 14px 40px rgba(24, 34, 21, 0.12);
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        min-height: 100vh;
        font-family: "Avenir Next", "Segoe UI Variable", "Helvetica Neue", sans-serif;
        color: var(--ink);
        background:
          radial-gradient(1100px 560px at -8% -20%, #dff6d2 0%, rgba(223, 246, 210, 0) 70%),
          radial-gradient(860px 420px at 102% 4%, #faeec8 0%, rgba(250, 238, 200, 0) 72%),
          var(--bg);
        padding: 16px;
      }
      .app {
        background: color-mix(in srgb, var(--card) 90%, white 10%);
        border: 1px solid var(--line);
        border-radius: 16px;
        box-shadow: var(--shadow);
        overflow: hidden;
      }
      .hero {
        padding: 20px 20px 14px;
        border-bottom: 1px solid var(--line);
        background: linear-gradient(135deg, #f8fff0 0%, #eef8ff 100%);
      }
      .eyebrow {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.12em;
        text-transform: uppercase;
        color: #426151;
      }
      .brand-line {
        margin: 4px 0 0;
        font-size: 14px;
        font-weight: 800;
        letter-spacing: 0.05em;
        text-transform: uppercase;
        color: #2d6a4f;
      }
      .subtitle {
        margin: 8px 0 0;
        font-size: 15px;
        line-height: 1.38;
        color: var(--muted);
        max-width: 42ch;
      }
      .content { padding: 16px; }
      .actions {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 10px;
        margin-bottom: 12px;
      }
      .controls {
        display: grid;
        grid-template-columns: 1fr;
        gap: 8px;
        margin-bottom: 12px;
      }
      .control {
        display: grid;
        gap: 4px;
      }
      .control label {
        font-size: 12px;
        font-weight: 700;
        color: #466049;
      }
      .control select,
      .control input {
        width: 100%;
        border: 1px solid var(--line);
        border-radius: 10px;
        background: #fff;
        color: var(--ink);
        font: inherit;
        font-size: 13px;
        padding: 8px 10px;
      }
      .control select {
        appearance: none;
        -webkit-appearance: none;
        -moz-appearance: none;
        padding-right: 36px;
        background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12' fill='none'%3E%3Cpath d='M3 4.5 6 7.5l3-3' stroke='%23466049' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
        background-repeat: no-repeat;
        background-position: right 12px center;
        background-size: 12px 12px;
      }
      button {
        appearance: none;
        border: 1px solid var(--line);
        border-radius: 12px;
        background: #fff;
        color: var(--ink);
        font: inherit;
        font-weight: 700;
        padding: 10px 12px;
        cursor: pointer;
        transition: transform 80ms ease, background-color 120ms ease, border-color 120ms ease;
      }
      button:hover { transform: translateY(-1px); border-color: #bdccb0; }
      button:active { transform: translateY(0); }
      button.primary {
        background: var(--brand);
        border-color: #215c42;
        color: var(--brand-ink);
      }
      button.primary:hover { background: #245e45; }
      button.warn {
        background: #2e3530;
        color: #f6fffd;
        border-color: #252b27;
      }
      button.muted {
        background: #f0f6e8;
        border-color: #c7d7b8;
      }
      button[disabled] { opacity: 0.6; cursor: default; transform: none; }
      .log {
        margin: 0;
        white-space: pre-wrap;
        height: 10px;
        max-height: 200px;
        overflow-x: hidden;
        overflow-y: auto;
        font-family: "SF Mono", "JetBrains Mono", "Menlo", monospace;
        font-size: 12px;
        line-height: 1.45;
        background: #2b332c;
        color: #def0d9;
        border: 1px solid #3d4a3f;
        border-radius: 12px;
        padding: 5px 8px;
      }
      .status {
        display: none;
        align-items: center;
        gap: 8px;
        margin: 10px 0 0;
        font-size: 12px;
        font-weight: 700;
        color: #3d5a43;
      }
      .status.active { display: inline-flex; }
      .spinner {
        width: 14px;
        height: 14px;
        border-radius: 999px;
        border: 2px solid #b8cfb3;
        border-top-color: #2d6a4f;
        animation: spin 650ms linear infinite;
      }
      @keyframes spin {
        from { transform: rotate(0deg); }
        to { transform: rotate(360deg); }
      }
      .downloads {
        margin-top: 12px;
        padding: 12px;
        border-radius: 12px;
        border: 1px solid #c8dbb7;
        background: linear-gradient(180deg, #f7fff3 0%, #f0f9eb 100%);
      }
      .downloads-title {
        font-size: 13px;
        font-weight: 800;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: #385742;
        margin: 0 0 8px;
      }
      .downloads-list {
        display: grid;
        grid-template-columns: 1fr;
        gap: 8px;
      }
      .downloads-list button {
        width: 100%;
        text-align: center;
        font-size: 18px;
        line-height: 1.2;
        padding: 9px 12px;
        white-space: normal;
        overflow-wrap: anywhere;
        word-break: break-word;
      }
    </style>
  </head>
  <body>
    <div class="app">
      <header class="hero">
        <div class="eyebrow">Local Figma Port</div>
        <div class="brand-line">Design Exporter</div>
        <p class="subtitle">Export data and send the bundle directly to your local MCP server. If delivery fails, you can download the bundle manually.</p>
      </header>
      <main class="content">
        <section class="controls">
          <div class="control">
            <label for="mode">Export mode</label>
            <select id="mode">
              <option value="design">Design element</option>
              <option value="uikit">UI-kit</option>
            </select>
          </div>
          <div class="control">
            <label for="endpoint">MCP endpoint</label>
            <input id="endpoint" type="text" value="http://127.0.0.1:7331/import-bundle" />
          </div>
        </section>
        <section class="actions">
          <button class="primary" id="run-selection">Export Selection</button>
          <button class="muted" id="run-current">Export Current Page</button>
          <button class="muted" id="run-all">Export All Pages</button>
          <button class="warn" id="close">Close</button>
        </section>
        <pre class="log" id="log"></pre>
        <div class="status" id="status"><span class="spinner"></span><span id="status-text">Working...</span></div>
        <div class="downloads" id="downloads" style="display:none"></div>
      </main>
    </div>
    <script>
      const log = document.getElementById('log');
      const downloads = document.getElementById('downloads');
      const runSelectionBtn = document.getElementById('run-selection');
      const runCurrentBtn = document.getElementById('run-current');
      const runAllBtn = document.getElementById('run-all');
      const closeBtn = document.getElementById('close');
      const modeSelect = document.getElementById('mode');
      const endpointInput = document.getElementById('endpoint');
      const status = document.getElementById('status');
      const statusText = document.getElementById('status-text');
      const resizeLog = () => {
        const min = 110;
        const max = 320;
        log.style.height = min + 'px';
        const next = Math.min(max, Math.max(min, log.scrollHeight + 2));
        log.style.height = next + 'px';
      };
      const append = (m) => {
        log.textContent += m + '\\n';
        resizeLog();
        log.scrollTop = log.scrollHeight;
      };
      const setBusy = (busy) => {
        runSelectionBtn.disabled = busy;
        runCurrentBtn.disabled = busy;
        runAllBtn.disabled = busy;
        closeBtn.disabled = busy;
        modeSelect.disabled = busy;
        endpointInput.disabled = busy;
        if (!busy) {
          status.classList.remove('active');
          statusText.textContent = 'Working...';
        }
      };
      const setStatus = (text) => {
        status.classList.add('active');
        statusText.textContent = text;
      };
      const b64ToBytes = (base64) => {
        const s = atob(base64);
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
      };
      const toGzip = async (bytes) => {
        if (typeof CompressionStream === 'undefined') {
          throw new Error('CompressionStream is not available in this Figma UI runtime');
        }
        const cs = new CompressionStream('gzip');
        const writer = cs.writable.getWriter();
        await writer.write(bytes);
        await writer.close();
        const ab = await new Response(cs.readable).arrayBuffer();
        return new Uint8Array(ab);
      };
      const download = async (path, base64, mime, encoding) => {
        let bytes = b64ToBytes(base64);
        if (encoding === 'json-utf8' && path.endsWith('.gz')) {
          bytes = await toGzip(bytes);
        }
        const blob = new Blob([bytes], { type: mime || 'application/octet-stream' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = path;
        document.body.appendChild(a);
        a.click();
        a.remove();
      };
      const clearDownloads = () => {
        downloads.innerHTML = '';
        downloads.style.display = 'none';
      };
      const renderDownloads = (payload) => {
        clearDownloads();
        if (!payload || !Array.isArray(payload.files) || payload.files.length === 0) return;
        downloads.style.display = 'block';
        const info = document.createElement('p');
        info.className = 'downloads-title';
        info.textContent = 'Export Complete';
        downloads.appendChild(info);
        const list = document.createElement('div');
        list.className = 'downloads-list';
        downloads.appendChild(list);

        const bundleBtn = document.createElement('button');
        bundleBtn.className = 'primary';
        bundleBtn.textContent = 'Download Bundle JSON';
        bundleBtn.onclick = () => {
          const raw = JSON.stringify(payload, null, 2);
          const blob = new Blob([raw], { type: 'application/json' });
          const a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = 'plugin-export.bundle.json';
          document.body.appendChild(a);
          a.click();
          a.remove();
        };
        list.appendChild(bundleBtn);
      };
      const endpoint = () => (endpointInput.value || '').trim();
      const selectedMode = () => modeSelect.value === 'uikit' ? 'uikit' : 'design';
      const sendBundle = async (payload, mode) => {
        const url = endpoint();
        if (!url) throw new Error('MCP endpoint URL is empty');
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ mode, payload }),
        });
        const raw = await res.text();
        let body = null;
        try { body = raw ? JSON.parse(raw) : null; } catch (_) {}
        if (!res.ok) {
          const detail = body && body.error ? body.error : ('HTTP ' + res.status);
          throw new Error(detail);
        }
        return body || { ok: true };
      };
      runSelectionBtn.onclick = () => {
        setBusy(true);
        setStatus('Exporting...');
        clearDownloads();
        append('--- Export Selection ---');
        parent.postMessage({ pluginMessage: { type: 'export', scope: 'selection', mode: selectedMode() } }, '*');
      };
      runCurrentBtn.onclick = () => {
        setBusy(true);
        setStatus('Exporting...');
        clearDownloads();
        append('--- Export Current Page ---');
        parent.postMessage({ pluginMessage: { type: 'export', scope: 'current', mode: selectedMode() } }, '*');
      };
      runAllBtn.onclick = () => {
        setBusy(true);
        setStatus('Exporting...');
        clearDownloads();
        append('--- Export All Pages ---');
        parent.postMessage({ pluginMessage: { type: 'export', scope: 'all', mode: selectedMode() } }, '*');
      };
      closeBtn.onclick = () => {
        parent.postMessage({ pluginMessage: { type: 'close' } }, '*');
      };
      onmessage = async (event) => {
        const msg = event.data.pluginMessage;
        if (!msg) return;
        if (msg.type === 'export-error') {
          append('Error: ' + msg.error);
          setBusy(false);
          return;
        }
        if (msg.type === 'export-progress') {
          setStatus('Exporting...');
          append(msg.message);
          return;
        }
        if (msg.type === 'export-ready') {
          append('Export ID: ' + msg.payload.manifest.manifest.exportId);
          try {
            setStatus('Sending to MCP...');
            append('Sending bundle to ' + endpoint() + ' ...');
            const result = await sendBundle(msg.payload, msg.mode || selectedMode());
            const imported = result && result.import && result.import.success;
            append(imported
              ? 'Bundle delivered and imported successfully.'
              : 'Bundle delivered successfully.');
          } catch (e) {
            append('Auto-send failed: ' + (e && e.message ? e.message : e));
            append('Fallback enabled: download bundle manually.');
            renderDownloads(msg.payload);
          }
          setBusy(false);
        }
      };
    </script>
  </body>
</html>
`;

figma.showUI(UI_HTML, { width: 520, height: 760 });

function fileKeyFromUrl(): string {
  const m = figma.fileKey;
  if (m) return m;
  return "local-file";
}

async function buildExport(
  scope: "selection" | "current" | "all",
  mode: ExportMode,
): Promise<{ manifest: PluginExportManifest; files: ExportFile[] }> {
  let step = "init";
  try {
    const exportId = `export-${Date.now()}`;
    const exportedAt = new Date().toISOString();
    const fileKey = fileKeyFromUrl();

    const files: ExportFile[] = [];
    const pageEntries: PluginExportManifest["manifest"]["pages"] = [];
    const nodeChunks: string[] = [];
    const previewChunks: string[] = [];
    const selectionIndex: SelectionIndexEntry[] = [];
    const assetIndex: AssetIndexEntry[] = [];
    const imageAssetIndex: ImageAssetIndexEntry[] = [];
    const seenImageHashes = new Set<string>();

    if (scope === "selection") {
      step = "selection:collect";
      const selection = figma.currentPage.selection.filter(
        (n): n is SceneNode => n.type !== "SLICE",
      );
      if (selection.length === 0) {
        throw new Error(
          "Nothing selected. Select at least one node on canvas.",
        );
      }
      figma.ui.postMessage({
        type: "export-progress",
        message: `Exporting selection (${selection.length} node(s)) on page: ${figma.currentPage.name}`,
      });
      step = "selection:walk";
      const { pageChunk, hash } = await exportPageFromRoots(
        figma.currentPage,
        selection,
      );
      const chunkPath = `nodes/page_${figma.currentPage.id.replace(/[^a-zA-Z0-9]/g, "_")}.json.gz`;
      nodeChunks.push(chunkPath);
      pageEntries.push({
        id: figma.currentPage.id,
        name: figma.currentPage.name,
        hash,
        nodeChunk: chunkPath,
      });
      step = "selection:serialize";
      files.push({
        path: chunkPath,
        mime: "application/gzip",
        bytesBase64: toBase64(toUtf8Bytes(pageChunk)),
        encoding: "json-utf8",
      });
      if (mode === "design") {
        const imageNodes = collectImageNodesFromRoots(selection);
        for (const node of imageNodes) {
          const hashes = imageHashesFromNode(node);
          for (const hash of hashes) {
            if (seenImageHashes.has(hash)) continue;
            seenImageHashes.add(hash);
            const img = figma.getImageByHash(hash);
            if (!img) continue;
            try {
              const bytes = await img.getBytesAsync();
              const kind = detectImageType(bytes);
              const imageId = `img_${sanitizeFilePart(hash)}`;
              const imagePath = `assets/images/${imageId}.${kind.ext}`;
              files.push({
                path: imagePath,
                mime: kind.mime,
                bytesBase64: toBase64(bytes),
                encoding: "binary-base64",
              });
              imageAssetIndex.push({
                imageId,
                hash,
                name: normalizeName(node),
                nodeId: node.id,
                pageId: figma.currentPage.id,
                mime: kind.mime,
                path: imagePath,
              });
            } catch (e) {
              figma.ui.postMessage({
                type: "export-progress",
                message: `Image asset skipped (${hash}): ${e instanceof Error ? e.message : "unknown error"}`,
              });
            }
          }
        }

        for (let i = 0; i < selection.length; i += 1) {
          const node = selection[i];
          const selectionId = `sel_${sanitizeFilePart(node.id)}`;
          const previewPath = `previews/${selectionId}_${sanitizeFilePart(node.name)}.png`;
          const assetId = `svg_${sanitizeFilePart(node.id)}`;
          const assetPath = `assets/${assetId}.svg`;
          let exportedSvg = false;
          try {
            files.push(await exportSvgFile(node, assetPath));
            assetIndex.push({
              assetId,
              name: normalizeName(node),
              nodeId: node.id,
              pageId: figma.currentPage.id,
              mime: "image/svg+xml",
              path: assetPath,
            });
            exportedSvg = true;
          } catch (e) {
            figma.ui.postMessage({
              type: "export-progress",
              message: `SVG skipped for ${node.name}: ${e instanceof Error ? e.message : "unknown error"}`,
            });
          }
          try {
            files.push(await exportPreviewFile(node, previewPath));
            previewChunks.push(previewPath);
            selectionIndex.push({
              selectionId,
              name: normalizeName(node),
              nodeId: node.id,
              pageId: figma.currentPage.id,
              preview: previewPath,
            });
          } catch (e) {
            figma.ui.postMessage({
              type: "export-progress",
              message: `Preview skipped for ${node.name}: ${e instanceof Error ? e.message : "unknown error"}`,
            });
            selectionIndex.push({
              selectionId,
              name: normalizeName(node),
              nodeId: node.id,
              pageId: figma.currentPage.id,
            });
          }
          if (!exportedSvg) {
            // keep list deterministic even when SVG export failed
            assetIndex.push({
              assetId,
              name: normalizeName(node),
              nodeId: node.id,
              pageId: figma.currentPage.id,
              mime: "image/svg+xml",
              path: "",
            });
          }
          await nextTick();
        }
        files.push({
          path: "selection_index.json.gz",
          mime: "application/gzip",
          bytesBase64: toBase64(toUtf8Bytes({ selections: selectionIndex })),
          encoding: "json-utf8",
        });
        files.push({
          path: "asset_index.json.gz",
          mime: "application/gzip",
          bytesBase64: toBase64(toUtf8Bytes({ assets: assetIndex.filter((a) => !!a.path) })),
          encoding: "json-utf8",
        });
        files.push({
          path: "image_asset_index.json.gz",
          mime: "application/gzip",
          bytesBase64: toBase64(toUtf8Bytes({ images: imageAssetIndex })),
          encoding: "json-utf8",
        });
      }
      await nextTick();
    } else {
      const pages =
        scope === "current"
          ? [figma.currentPage]
          : figma.root.children.filter((p): p is PageNode => p.type === "PAGE");

      for (let i = 0; i < pages.length; i += 1) {
        const page = pages[i];
        figma.ui.postMessage({
          type: "export-progress",
          message: `Exporting page ${i + 1}/${pages.length}: ${page.name}`,
        });
        step = `page:${i + 1}:walk`;
        const { pageChunk, hash } = await exportPageFromRoots(
          page,
          page.children as SceneNode[],
        );
        const chunkPath = `nodes/page_${page.id.replace(/[^a-zA-Z0-9]/g, "_")}.json.gz`;
        nodeChunks.push(chunkPath);
        pageEntries.push({
          id: page.id,
          name: page.name,
          hash,
          nodeChunk: chunkPath,
        });
        step = `page:${i + 1}:serialize`;
        files.push({
          path: chunkPath,
          mime: "application/gzip",
          bytesBase64: toBase64(toUtf8Bytes(pageChunk)),
          encoding: "json-utf8",
        });
        if (mode === "design") {
          const imageNodes = collectImageNodesFromRoots(page.children as SceneNode[]);
          for (const node of imageNodes) {
            const hashes = imageHashesFromNode(node);
            for (const hash of hashes) {
              if (seenImageHashes.has(hash)) continue;
              seenImageHashes.add(hash);
              const img = figma.getImageByHash(hash);
              if (!img) continue;
              try {
                const bytes = await img.getBytesAsync();
                const kind = detectImageType(bytes);
                const imageId = `img_${sanitizeFilePart(hash)}`;
                const imagePath = `assets/images/${imageId}.${kind.ext}`;
                files.push({
                  path: imagePath,
                  mime: kind.mime,
                  bytesBase64: toBase64(bytes),
                  encoding: "binary-base64",
                });
                imageAssetIndex.push({
                  imageId,
                  hash,
                  name: normalizeName(node),
                  nodeId: node.id,
                  pageId: page.id,
                  mime: kind.mime,
                  path: imagePath,
                });
              } catch (e) {
                figma.ui.postMessage({
                  type: "export-progress",
                  message: `Image asset skipped (${hash}): ${e instanceof Error ? e.message : "unknown error"}`,
                });
              }
            }
          }

          const previewTarget =
            (page.children.find((n) => n.visible) as SceneNode | undefined) ??
            null;
          if (previewTarget) {
            const previewPath = `previews/${sanitizeFilePart(page.name)}.png`;
            try {
              files.push(await exportPreviewFile(previewTarget, previewPath));
              previewChunks.push(previewPath);
            } catch (e) {
              figma.ui.postMessage({
                type: "export-progress",
                message: `Preview skipped for page ${page.name}: ${e instanceof Error ? e.message : "unknown error"}`,
              });
            }
          }
        }
        await nextTick();
      }
      if (mode === "design") {
        files.push({
          path: "image_asset_index.json.gz",
          mime: "application/gzip",
          bytesBase64: toBase64(toUtf8Bytes({ images: imageAssetIndex })),
          encoding: "json-utf8",
        });
      }
    }

    const tokensPath = "tokens.json.gz";
    const stylesPath = "styles.json.gz";
    let tokensPayload: unknown = { collections: [], variables: [] };
    let stylesPayload: unknown = { styles: [] };

    try {
      step = "tokens";
      tokensPayload = exportVariables();
    } catch (e) {
      figma.ui.postMessage({
        type: "export-progress",
        message: `Tokens export skipped: ${e instanceof Error ? e.message : "unknown error"}`,
      });
    }
    try {
      step = "styles";
      stylesPayload = exportStyles();
    } catch (e) {
      figma.ui.postMessage({
        type: "export-progress",
        message: `Styles export skipped: ${e instanceof Error ? e.message : "unknown error"}`,
      });
    }

    files.push({
      path: tokensPath,
      mime: "application/gzip",
      bytesBase64: toBase64(toUtf8Bytes(tokensPayload)),
      encoding: "json-utf8",
    });

    files.push({
      path: stylesPath,
      mime: "application/gzip",
      bytesBase64: toBase64(toUtf8Bytes(stylesPayload)),
      encoding: "json-utf8",
    });

    step = "manifest";
    const manifest: PluginExportManifest = {
      version: "plugin-export.v1",
      manifest: {
        exportId,
        fileKey,
        exportedAt,
        pages: pageEntries,
        tokensChunk: tokensPath,
        stylesChunk: stylesPath,
      },
      chunks: {
        nodes: nodeChunks,
        tokens: tokensPath,
        styles: stylesPath,
        previews: previewChunks,
      },
    };

    files.push({
      path: "manifest.json",
      mime: "application/json",
      bytesBase64: toBase64(encodeUtf8(JSON.stringify(manifest, null, 2))),
      encoding: "binary-base64",
    });

    return { manifest, files };
  } catch (e) {
    const err = e instanceof Error ? e : new Error(String(e));
    throw new Error(`[buildExport:${step}] ${err.message}`);
  }
}

figma.ui.onmessage = async (msg) => {
  if (msg && msg.type === "export") {
    try {
      const scope =
        msg.scope === "all"
          ? "all"
          : msg.scope === "selection"
            ? "selection"
            : "current";
      const mode: ExportMode = msg.mode === "uikit" ? "uikit" : "design";
      const data = await buildExport(scope, mode);
      figma.ui.postMessage({ type: "export-ready", payload: data, mode });
    } catch (error) {
      const detail =
        error instanceof Error
          ? `${error.message}${error.stack ? `\\n${error.stack}` : ""}`
          : "Unknown export error";
      figma.ui.postMessage({
        type: "export-error",
        error: detail,
      });
    }
  }

  if (msg && msg.type === "close") {
    figma.closePlugin();
  }
};
