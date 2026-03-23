export type ExportPage = {
  id: string;
  name: string;
  hash: string;
  nodeChunk: string;
};

export type PluginExportManifest = {
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

export type ExportFile = {
  path: string;
  mime: string;
  bytesBase64: string;
  encoding?: "binary-base64" | "json-utf8";
};

export type ExportedNodeResources = {
  previewUri?: string;
  selectionIds?: string[];
  assetIds?: string[];
  imageIds?: string[];
  uikitComponentIds?: string[];
};

export type ExportedInspectionHints = {
  requiresInstanceResolution?: boolean;
  masterComponentId?: string;
  overrideNodeIds?: string[];
  relatedStateNodeIds?: string[];
  stateGroup?: string;
  state?: string;
};

export type ExportedNode = {
  id: string;
  type: string;
  name: string;
  pageId?: string;
  parentId?: string;
  childrenIds: string[];
  bounds: { x: number; y: number; w: number; h: number };
  absBounds?: { x: number; y: number; w: number; h: number };
  componentId?: string;
  variantProps?: Record<string, string>;
  layout?: unknown;
  style?: unknown;
  refs: {
    variables: string[];
    styles: string[];
  };
  resources?: ExportedNodeResources;
  inspectionHints?: ExportedInspectionHints;
  characters?: string;
  text?: { content: string };
  computed?: unknown;
};

export type ExportedPageChunk = {
  pageId: string;
  pageName: string;
  nodes: ExportedNode[];
};
