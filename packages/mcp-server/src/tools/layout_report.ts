import { one } from "../db.js";

function parse(raw: string | null): any {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export function layoutReport(input: { nodeId: string; mode?: "intent" | "computed" | "intent+computed" }) {
  const mode = input.mode ?? "intent+computed";
  const row = one<{
    id: string;
    type: string;
    name: string;
    layout_intent_json: string | null;
    computed_json: string | null;
  }>(
    "SELECT id, type, name, layout_intent_json, computed_json FROM nodes WHERE id = ?",
    [input.nodeId]
  );

  if (!row) {
    return { summary: { nodeId: input.nodeId, found: false } };
  }

  const intent = parse(row.layout_intent_json);
  const computed = parse(row.computed_json);
  const summary: Record<string, unknown> = {
    nodeId: row.id,
    nodeType: row.type,
    nodeName: row.name,
    found: true,
  };

  if (mode === "intent" || mode === "intent+computed") {
    summary.intent = intent;
  }
  if (mode === "computed" || mode === "intent+computed") {
    summary.computed = computed;
  }

  return { summary };
}
