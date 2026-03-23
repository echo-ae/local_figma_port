import { readNodeTree } from "./node_payload.js";

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string" && item.length > 0);
}

export function resolveInstance(input: {
  nodeId: string;
  depth?: number;
  includeMaster?: boolean;
  includeOverrides?: boolean;
}) {
  const depth = Math.max(0, Math.min(4, Math.trunc(input.depth ?? 1)));
  const instance = readNodeTree(input.nodeId, depth);
  if (!instance) {
    return {
      instance: { id: input.nodeId, found: false },
      master: null,
      overrides: [],
    };
  }

  const inspectionHints =
    instance.inspectionHints && typeof instance.inspectionHints === "object"
      ? (instance.inspectionHints as Record<string, unknown>)
      : {};
  const masterComponentId =
    typeof inspectionHints.masterComponentId === "string"
      ? inspectionHints.masterComponentId
      : typeof instance.componentId === "string"
        ? instance.componentId
        : null;
  const overrideNodeIds = asStringArray(inspectionHints.overrideNodeIds ?? instance.childrenIds);

  return {
    instance,
    master:
      input.includeMaster === false || !masterComponentId
        ? null
        : readNodeTree(masterComponentId, depth),
    overrides:
      input.includeOverrides === false
        ? []
        : overrideNodeIds
            .map((nodeId) => readNodeTree(nodeId, depth))
            .filter((node): node is Record<string, unknown> => !!node),
  };
}
