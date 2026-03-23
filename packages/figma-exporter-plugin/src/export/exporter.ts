import { createHash } from "./hash";
import { computeBaseSpacing } from "./spacing";
import {
  extractNodeFidelity,
  normalizeName,
} from "./extract-node-fidelity";

function exportNode(node: SceneNode, pageId: string): any {
  const fidelity = extractNodeFidelity(node);
  const data: any = {
    id: node.id,
    type: node.type,
    name: normalizeName(node),
    pageId,
    parentId: node.parent ? node.parent.id : undefined,
    childrenIds: "children" in node ? node.children.map((child) => child.id) : [],
    bounds: { x: node.x, y: node.y, w: node.width, h: node.height },
    absBounds: {
      x: node.absoluteTransform[0][2],
      y: node.absoluteTransform[1][2],
      w: node.width,
      h: node.height,
    },
    componentId: "mainComponent" in node && node.mainComponent ? node.mainComponent.id : undefined,
    variantProps: "variantProperties" in node ? node.variantProperties : undefined,
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

function flatten(root: BaseNode & ChildrenMixin, pageId: string): any[] {
  const out: any[] = [];
  const walk = (node: SceneNode) => {
    out.push(exportNode(node, pageId));
    if ("children" in node) {
      for (const child of node.children) walk(child as SceneNode);
    }
  };
  for (const child of root.children) walk(child as SceneNode);
  return out;
}

export function exportPage(page: PageNode): { pageChunk: any; hash: string } {
  const nodes = flatten(page, page.id);
  const pageChunk = {
    pageId: page.id,
    pageName: page.name,
    nodes,
  };
  return {
    pageChunk,
    hash: createHash(JSON.stringify(pageChunk)),
  };
}
