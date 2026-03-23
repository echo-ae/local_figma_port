export function computeBaseSpacing(node: SceneNode): unknown {
  if (!("children" in node) || !Array.isArray(node.children) || node.children.length < 2) {
    return { confidence: { spacingInference: 0 } };
  }

  const children = node.children.filter((c) => c.visible) as SceneNode[];
  if (children.length < 2) {
    return { confidence: { spacingInference: 0 } };
  }

  let axis: "x" | "y" = "x";
  if ("layoutMode" in node && (node.layoutMode === "VERTICAL" || node.layoutMode === "HORIZONTAL")) {
    axis = node.layoutMode === "HORIZONTAL" ? "x" : "y";
  } else {
    const xs = children.map((c) => c.x);
    const ys = children.map((c) => c.y);
    const sx = Math.max(...xs) - Math.min(...xs);
    const sy = Math.max(...ys) - Math.min(...ys);
    axis = sx >= sy ? "x" : "y";
  }

  const sorted = [...children].sort((a, b) => (axis === "x" ? a.x - b.x : a.y - b.y));
  const gapsBetween = [] as Array<{ a: string; b: string; axis: "x" | "y"; value: number }>;

  for (let i = 0; i < sorted.length - 1; i += 1) {
    const a = sorted[i];
    const b = sorted[i + 1];
    const aEnd = axis === "x" ? a.x + a.width : a.y + a.height;
    const bStart = axis === "x" ? b.x : b.y;
    gapsBetween.push({ a: a.id, b: b.id, axis, value: Math.max(0, bStart - aEnd) });
  }

  return {
    gapsBetween,
    confidence: { spacingInference: 1 },
  };
}
