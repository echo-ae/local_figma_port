export function buildTextRenderHints(style: any): {
  strategy: string;
  sourcePath: string;
  reason: string;
  runCount: number;
} | null {
  const runs = style?.text?.textRuns;
  if (!Array.isArray(runs)) return null;
  if (runs.length <= 1) return null;
  const signatures = new Set<string>();
  for (const run of runs) {
    const signature = JSON.stringify({
      color: run?.color ?? null,
      fills: run?.fills ?? null,
      fillStyleId: run?.fillStyleId ?? null,
      fontName: run?.fontName ?? null,
      fontSize: run?.fontSize ?? null,
      fontWeight: run?.fontWeight ?? null,
      lineHeight: run?.lineHeight ?? null,
      letterSpacing: run?.letterSpacing ?? null,
      textCase: run?.textCase ?? null,
      textDecoration: run?.textDecoration ?? null,
    });
    signatures.add(signature);
  }
  if (signatures.size <= 1) return null;
  return {
    strategy: "span-per-segment",
    sourcePath: "node.style.text.textRuns",
    reason:
      "The text node contains mixed style/color runs. Render each run as an inline <span> in order.",
    runCount: runs.length,
  };
}
