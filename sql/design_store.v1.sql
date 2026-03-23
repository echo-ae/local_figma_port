PRAGMA foreign_keys = ON;

-- Metadata
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- Pages
CREATE TABLE IF NOT EXISTS pages (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  frame_count INTEGER NOT NULL DEFAULT 0
);

-- Nodes (core)
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  page_id TEXT,
  parent_id TEXT,
  type TEXT NOT NULL,
  name TEXT NOT NULL,

  x REAL NOT NULL,
  y REAL NOT NULL,
  w REAL NOT NULL,
  h REAL NOT NULL,

  abs_x REAL,
  abs_y REAL,
  abs_w REAL,
  abs_h REAL,

  component_id TEXT,
  variant_props_json TEXT,

  layout_intent_json TEXT,
  style_json TEXT,
  style_refs_json TEXT,
  resources_json TEXT,
  inspection_hints_json TEXT,
  computed_json TEXT,

  updated_at TEXT NOT NULL,

  FOREIGN KEY(page_id) REFERENCES pages(id),
  FOREIGN KEY(parent_id) REFERENCES nodes(id)
);

-- Child order / edges
CREATE TABLE IF NOT EXISTS edges (
  parent_id TEXT NOT NULL,
  child_id TEXT NOT NULL,
  ord INTEGER NOT NULL,
  PRIMARY KEY(parent_id, child_id),
  FOREIGN KEY(parent_id) REFERENCES nodes(id),
  FOREIGN KEY(child_id) REFERENCES nodes(id)
);

-- Text indexable content (store actual text nodes here)
CREATE TABLE IF NOT EXISTS texts (
  node_id TEXT PRIMARY KEY,
  page_id TEXT,
  content TEXT NOT NULL,
  text_style_json TEXT,
  style_refs_json TEXT,
  FOREIGN KEY(node_id) REFERENCES nodes(id),
  FOREIGN KEY(page_id) REFERENCES pages(id)
);

-- Tokens / variables (raw export + convenience tables optional)
CREATE TABLE IF NOT EXISTS tokens_raw (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  json TEXT NOT NULL,
  exported_at TEXT NOT NULL
);

-- UI-kit snapshot (imported from import-ui-kit)
CREATE TABLE IF NOT EXISTS uikit_pages (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS uikit_components (
  id TEXT PRIMARY KEY,
  page_id TEXT,
  type TEXT NOT NULL,
  name TEXT NOT NULL,
  x REAL NOT NULL,
  y REAL NOT NULL,
  w REAL NOT NULL,
  h REAL NOT NULL,
  variant_props_json TEXT,
  style_json TEXT,
  style_refs_json TEXT,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(page_id) REFERENCES uikit_pages(id)
);

CREATE TABLE IF NOT EXISTS uikit_component_usages (
  component_id TEXT NOT NULL,
  node_id TEXT NOT NULL,
  page_id TEXT,
  node_name TEXT NOT NULL,
  node_type TEXT NOT NULL,
  match_strategy TEXT NOT NULL DEFAULT 'direct_id',
  PRIMARY KEY(component_id, node_id),
  FOREIGN KEY(component_id) REFERENCES uikit_components(id),
  FOREIGN KEY(node_id) REFERENCES nodes(id)
);

CREATE TABLE IF NOT EXISTS uikit_tokens_raw (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  json TEXT NOT NULL,
  exported_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS uikit_styles_raw (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  json TEXT NOT NULL,
  exported_at TEXT NOT NULL
);

-- Token usages (filled by importer)
CREATE TABLE IF NOT EXISTS token_usages (
  token_key TEXT NOT NULL,
  node_id TEXT NOT NULL,
  prop TEXT NOT NULL,
  mode TEXT,
  PRIMARY KEY(token_key, node_id, prop, COALESCE(mode, '')),
  FOREIGN KEY(node_id) REFERENCES nodes(id)
);

CREATE INDEX IF NOT EXISTS idx_nodes_page ON nodes(page_id);
CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);
CREATE INDEX IF NOT EXISTS idx_token_usages_token ON token_usages(token_key);
CREATE INDEX IF NOT EXISTS idx_token_usages_node ON token_usages(node_id);
CREATE INDEX IF NOT EXISTS idx_uikit_components_page ON uikit_components(page_id);
CREATE INDEX IF NOT EXISTS idx_uikit_usages_component ON uikit_component_usages(component_id);
CREATE INDEX IF NOT EXISTS idx_uikit_usages_node ON uikit_component_usages(node_id);

-- FTS5 for names + paths + text content
CREATE VIRTUAL TABLE IF NOT EXISTS fts_nodes USING fts5(
  node_id UNINDEXED,
  page_id UNINDEXED,
  name,
  type,
  path,
  tokenize = 'porter'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_texts USING fts5(
  node_id UNINDEXED,
  page_id UNINDEXED,
  content,
  tokenize = 'porter'
);
