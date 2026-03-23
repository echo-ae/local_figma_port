import { buildTextRenderHints } from "./text_render_hints.js";
import { readNodeTree } from "./node_payload.js";

export function getNode(input: { nodeId: string; includeChildren?: boolean }) {
  const node = readNodeTree(input.nodeId, input.includeChildren ? 1 : 0);
  if (!node) {
    return { node: { id: input.nodeId, found: false } };
  }

  const renderHints = buildTextRenderHints(node.style);
  return renderHints ? { node, renderHints: [renderHints] } : { node };
}
