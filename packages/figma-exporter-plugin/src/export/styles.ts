export function exportStyles(): unknown {
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
