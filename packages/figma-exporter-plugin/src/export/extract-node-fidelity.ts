function sanitizeStableId(input: string): string {
  return input.replace(/[^a-zA-Z0-9]/g, "_");
}

function colorToHex(color: RGB): string {
  const toByte = (value: number) =>
    Math.max(0, Math.min(255, Math.round(value * 255)))
      .toString(16)
      .padStart(2, "0")
      .toUpperCase();
  return `#${toByte(color.r)}${toByte(color.g)}${toByte(color.b)}`;
}

function normalizeSolidPaint(paint: Paint | undefined): { hex: string; opacity: number } | null {
  if (!paint || paint.type !== "SOLID") return null;
  return {
    hex: colorToHex(paint.color),
    opacity: Number(((paint.opacity ?? 1) * ((paint as SolidPaint).opacity ?? 1)).toFixed(3)),
  };
}

function mapCounterAlign(value: string | undefined): "MIN" | "CENTER" | "MAX" | "STRETCH" {
  if (value === "CENTER" || value === "MAX" || value === "STRETCH") {
    return value;
  }
  return "MIN";
}

function mapSizing(value: string | undefined): "FIXED" | "HUG" | "FILL" {
  if (value === "AUTO") return "HUG";
  if (value === "FILL") return "FILL";
  return "FIXED";
}

function imageHashesFromNode(node: SceneNode): string[] {
  const hashes = new Set<string>();
  const fills = "fills" in node ? (node as any).fills : null;
  if (Array.isArray(fills)) {
    for (const fill of fills as ReadonlyArray<Paint>) {
      if (fill.type === "IMAGE" && typeof fill.imageHash === "string" && fill.imageHash) {
        hashes.add(fill.imageHash);
      }
    }
  }
  return [...hashes].sort();
}

export function normalizeName(node: SceneNode): string {
  const normalized = node.name.replace(/\s+/g, " ").trim();
  return normalized || `(unnamed:${node.type}:${node.id})`;
}

export function extractLayout(node: SceneNode): unknown {
  if (!("layoutMode" in node)) return undefined;
  const mode = node.layoutMode === "NONE" ? "NONE" : node.layoutMode;
  if (mode === "NONE") return { mode: "NONE" };

  return {
    mode,
    wrap: "layoutWrap" in node && node.layoutWrap === "WRAP" ? "WRAP" : "NO_WRAP",
    padding: {
      t: "paddingTop" in node ? Number(node.paddingTop) : 0,
      r: "paddingRight" in node ? Number(node.paddingRight) : 0,
      b: "paddingBottom" in node ? Number(node.paddingBottom) : 0,
      l: "paddingLeft" in node ? Number(node.paddingLeft) : 0,
    },
    gap: {
      primary: "itemSpacing" in node ? Number(node.itemSpacing) : 0,
      wrap:
        "counterAxisSpacing" in node
          ? Number((node as AutoLayoutMixin).counterAxisSpacing)
          : null,
    },
    align: {
      primary:
        "primaryAxisAlignItems" in node && typeof node.primaryAxisAlignItems === "string"
          ? node.primaryAxisAlignItems
          : "MIN",
      counter:
        "counterAxisAlignItems" in node && typeof node.counterAxisAlignItems === "string"
          ? mapCounterAlign(node.counterAxisAlignItems)
          : "MIN",
    },
    sizing: {
      primary:
        "primaryAxisSizingMode" in node && typeof node.primaryAxisSizingMode === "string"
          ? mapSizing(node.primaryAxisSizingMode)
          : "FIXED",
      counter:
        "counterAxisSizingMode" in node && typeof node.counterAxisSizingMode === "string"
          ? mapSizing(node.counterAxisSizingMode)
          : "FIXED",
    },
  };
}

export function extractRefs(node: SceneNode): {
  variables: string[];
  styles: string[];
} {
  const variables: string[] = [];
  const styles: string[] = [];

  if ("boundVariables" in node && (node as any).boundVariables) {
    const flat = JSON.stringify((node as any).boundVariables);
    const ids = flat.match(/[\w:;.-]+/g) || [];
    for (const id of ids) {
      if (id.startsWith("VariableID:") || id.startsWith("S:")) continue;
      variables.push(`var:${id}`);
    }
  }

  if (
    "fillStyleId" in node &&
    typeof (node as any).fillStyleId === "string" &&
    (node as any).fillStyleId
  ) {
    styles.push(`style:${(node as any).fillStyleId}`);
  }
  if (
    "strokeStyleId" in node &&
    typeof (node as any).strokeStyleId === "string" &&
    (node as any).strokeStyleId
  ) {
    styles.push(`style:${(node as any).strokeStyleId}`);
  }
  if (
    "effectStyleId" in node &&
    typeof (node as any).effectStyleId === "string" &&
    (node as any).effectStyleId
  ) {
    styles.push(`style:${(node as any).effectStyleId}`);
  }
  if (
    "textStyleId" in node &&
    typeof (node as any).textStyleId === "string" &&
    (node as any).textStyleId
  ) {
    styles.push(`style:${(node as any).textStyleId}`);
  }

  return {
    variables: Array.from(new Set(variables)).sort(),
    styles: Array.from(new Set(styles)).sort(),
  };
}

export function extractStyle(node: SceneNode): unknown {
  const style: any = { fills: [], strokes: [], effects: [], text: null };

  if ("fills" in node && Array.isArray((node as any).fills)) {
    style.fills = (node as any).fills;
  }
  if ("strokes" in node && Array.isArray((node as any).strokes)) {
    style.strokes = (node as any).strokes;
  }
  if ("effects" in node && Array.isArray((node as any).effects)) {
    style.effects = (node as any).effects;
  }

  const box: Record<string, unknown> = {};
  if ("cornerRadius" in node && typeof (node as any).cornerRadius === "number") {
    box.cornerRadius = Number((node as any).cornerRadius);
  }
  if (
    "topLeftRadius" in node &&
    "topRightRadius" in node &&
    "bottomRightRadius" in node &&
    "bottomLeftRadius" in node
  ) {
    box.cornerRadii = {
      tl: Number((node as any).topLeftRadius ?? 0),
      tr: Number((node as any).topRightRadius ?? 0),
      br: Number((node as any).bottomRightRadius ?? 0),
      bl: Number((node as any).bottomLeftRadius ?? 0),
    };
  }
  if ("clipsContent" in node && typeof (node as any).clipsContent === "boolean") {
    box.clipsContent = (node as any).clipsContent;
  }
  if ("opacity" in node && typeof (node as any).opacity === "number") {
    box.opacity = Number((node as any).opacity);
  }
  if ("blendMode" in node && typeof (node as any).blendMode === "string") {
    box.blendMode = (node as any).blendMode;
  }
  if ("strokeWeight" in node && typeof (node as any).strokeWeight === "number") {
    box.strokeWeight = Number((node as any).strokeWeight);
  }
  if ("strokeAlign" in node && typeof (node as any).strokeAlign === "string") {
    box.strokeAlign = (node as any).strokeAlign;
  }
  if ("dashPattern" in node && Array.isArray((node as any).dashPattern)) {
    box.dashPattern = (node as any).dashPattern.map((value: unknown) => Number(value));
  }
  if (Object.keys(box).length > 0) {
    style.box = box;
  }

  if (node.type === "TEXT") {
    let textRuns: Array<{
      start: number;
      end: number;
      characters: string;
      fills: ReadonlyArray<Paint>;
      fillStyleId: string;
      color: { hex: string; opacity: number } | null;
      fontName: FontName;
      fontSize: number;
      fontWeight: number | null;
      lineHeight: LineHeight;
      letterSpacing: LetterSpacing;
      textCase: TextCase;
      textDecoration: TextDecoration;
    }> = [];
    try {
      const segments = node.getStyledTextSegments([
        "fills",
        "fillStyleId",
        "fontName",
        "fontSize",
        "fontWeight",
        "lineHeight",
        "letterSpacing",
        "textCase",
        "textDecoration",
      ]);
      textRuns = segments.map((segment) => ({
        start: segment.start,
        end: segment.end,
        characters: segment.characters,
        fills: segment.fills,
        fillStyleId: segment.fillStyleId,
        color: Array.isArray(segment.fills) ? normalizeSolidPaint(segment.fills[0]) : null,
        fontName: segment.fontName,
        fontSize: segment.fontSize,
        fontWeight: (segment as any).fontWeight ?? null,
        lineHeight: segment.lineHeight,
        letterSpacing: segment.letterSpacing,
        textCase: segment.textCase,
        textDecoration: segment.textDecoration,
      }));
    } catch {
      textRuns = [];
    }

    style.text = {
      characters: node.characters,
      fontName: node.fontName,
      fontSize: node.fontSize,
      fontWeight: (node as any).fontWeight ?? null,
      letterSpacing: node.letterSpacing,
      lineHeight: node.lineHeight,
      textCase: node.textCase,
      textDecoration: node.textDecoration,
      textRuns,
    };
    if (textRuns.length > 1) {
      style.text.renderHint =
        "Render as inline spans per text run (mixed-style text).";
    }
  }

  return style;
}

export function extractNodeFidelity(node: SceneNode): {
  layout: unknown;
  style: unknown;
  refs: { variables: string[]; styles: string[] };
  resources?: { imageIds?: string[] };
  inspectionHints?: Record<string, unknown>;
} {
  const imageIds = imageHashesFromNode(node).map((hash) => `img_${sanitizeStableId(hash)}`);
  const inspectionHints =
    "mainComponent" in node && node.mainComponent
      ? {
          requiresInstanceResolution: true,
          masterComponentId: node.mainComponent.id,
          overrideNodeIds: "children" in node ? node.children.map((child) => child.id) : [],
        }
      : undefined;

  return {
    layout: extractLayout(node),
    style: extractStyle(node),
    refs: extractRefs(node),
    resources: imageIds.length > 0 ? { imageIds } : undefined,
    inspectionHints,
  };
}
