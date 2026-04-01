use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chrono::Utc;
use clap::{Args, Parser, Subcommand};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use jsonschema::JSONSchema;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process;

#[derive(Parser)]
#[command(name = "design-importer")]
#[command(about = "Import Figma plugin-export.v1 into normalized IR + SQLite")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Import(ImportArgs),
}

#[derive(Args, Debug)]
struct ImportArgs {
    #[arg(long)]
    input: PathBuf,
    #[arg(long)]
    sqlite: PathBuf,
    #[arg(long)]
    ddl: PathBuf,
    #[arg(long)]
    write_chunks: Option<PathBuf>,
    #[arg(long)]
    write_manifest: Option<PathBuf>,
    #[arg(long)]
    ui_kit_input: Option<PathBuf>,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set, num_args = 1, value_parser = clap::builder::BoolishValueParser::new())]
    recompute_spacing: bool,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set, num_args = 1, value_parser = clap::builder::BoolishValueParser::new())]
    incremental: bool,
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 1, value_parser = clap::builder::BoolishValueParser::new())]
    purge_missing: bool,
    #[arg(long, default_value = "info")]
    log_level: String,
    #[arg(long, default_value_t = false, action = clap::ArgAction::Set, num_args = 1, value_parser = clap::builder::BoolishValueParser::new())]
    dry_run: bool,
}

#[derive(Debug, Deserialize)]
struct PluginExport {
    version: String,
    manifest: ExportManifest,
    chunks: ExportChunks,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct ExportManifest {
    #[serde(rename = "exportId")]
    export_id: String,
    #[serde(rename = "fileKey")]
    file_key: String,
    #[serde(rename = "exportedAt")]
    exported_at: String,
    pages: Vec<ManifestPage>,
    #[serde(rename = "tokensChunk")]
    tokens_chunk: Option<String>,
    #[serde(rename = "stylesChunk")]
    styles_chunk: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct ManifestPage {
    id: String,
    name: String,
    hash: String,
    #[serde(rename = "nodeChunk")]
    node_chunk: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct ExportChunks {
    nodes: Option<Vec<String>>,
    tokens: Option<String>,
    styles: Option<String>,
    previews: Option<Vec<String>>,
}

#[derive(Debug, Deserialize, Clone)]
struct ChunkPage {
    #[serde(rename = "pageId")]
    page_id: Option<String>,
    #[serde(rename = "pageName")]
    page_name: Option<String>,
    nodes: Vec<ChunkNode>,
}

#[derive(Debug, Deserialize, Clone)]
struct ChunkNode {
    id: String,
    #[serde(rename = "type")]
    node_type: String,
    name: Option<String>,
    #[serde(rename = "pageId")]
    page_id: Option<String>,
    #[serde(rename = "parentId")]
    parent_id: Option<String>,
    #[serde(rename = "childrenIds")]
    children_ids: Option<Vec<String>>,
    bounds: Option<Rect>,
    #[serde(rename = "absBounds")]
    abs_bounds: Option<Rect>,
    #[serde(rename = "componentId")]
    component_id: Option<String>,
    #[serde(rename = "variantProps")]
    variant_props: Option<Map<String, Value>>,
    layout: Option<Value>,
    style: Option<Value>,
    refs: Option<Refs>,
    resources: Option<Value>,
    #[serde(rename = "inspectionHints")]
    inspection_hints: Option<Value>,
    visible: Option<bool>,
}

#[derive(Debug, Deserialize, Clone, Serialize)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[derive(Debug, Deserialize, Clone)]
struct Refs {
    variables: Option<Vec<String>>,
    styles: Option<Vec<String>>,
    #[serde(rename = "variableProps")]
    variable_props: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IrNode {
    id: String,
    #[serde(rename = "type")]
    node_type: String,
    name: String,
    #[serde(rename = "pageId", skip_serializing_if = "Option::is_none")]
    page_id: Option<String>,
    #[serde(rename = "parentId", skip_serializing_if = "Option::is_none")]
    parent_id: Option<String>,
    #[serde(rename = "childrenIds")]
    children_ids: Vec<String>,
    bounds: Rect,
    #[serde(rename = "absBounds", skip_serializing_if = "Option::is_none")]
    abs_bounds: Option<Rect>,
    #[serde(rename = "componentId", skip_serializing_if = "Option::is_none")]
    component_id: Option<String>,
    #[serde(rename = "variantProps", skip_serializing_if = "Option::is_none")]
    variant_props: Option<Map<String, Value>>,
    #[serde(rename = "layoutIntent", skip_serializing_if = "Option::is_none")]
    layout_intent: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    style: Option<Value>,
    #[serde(rename = "styleRefs")]
    style_refs: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    resources: Option<Value>,
    #[serde(rename = "inspectionHints", skip_serializing_if = "Option::is_none")]
    inspection_hints: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    computed: Option<Value>,
}

#[derive(Debug)]
struct ImportContext {
    project: ExportManifest,
    tokens: Value,
    styles: Value,
}

#[derive(Debug, Deserialize)]
struct BundleFile {
    path: String,
    mime: String,
    #[serde(rename = "bytesBase64")]
    bytes_base64: String,
    encoding: Option<String>,
}

#[derive(Debug, Deserialize)]
struct BundlePayload {
    files: Vec<BundleFile>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct SelectionIndex {
    selections: Vec<SelectionItem>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct SelectionItem {
    #[serde(rename = "selectionId")]
    selection_id: String,
    name: String,
    #[serde(rename = "nodeId")]
    node_id: String,
    #[serde(rename = "pageId")]
    page_id: String,
    preview: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct AssetIndex {
    assets: Vec<AssetItem>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct AssetItem {
    #[serde(rename = "assetId")]
    asset_id: String,
    name: String,
    #[serde(rename = "nodeId")]
    node_id: String,
    #[serde(rename = "pageId")]
    page_id: String,
    mime: String,
    path: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct ImageAssetIndex {
    images: Vec<ImageAssetItem>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct ImageAssetItem {
    #[serde(rename = "imageId")]
    image_id: String,
    hash: String,
    name: String,
    #[serde(rename = "nodeId")]
    node_id: String,
    #[serde(rename = "pageId")]
    page_id: String,
    mime: String,
    path: String,
}

fn main() {
    let cli = Cli::parse();
    let code = match run(cli) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("error: {err:#}");
            3
        }
    };
    process::exit(code);
}

fn run(cli: Cli) -> Result<i32> {
    match cli.command {
        Commands::Import(args) => run_import(args),
    }
}

fn run_import(args: ImportArgs) -> Result<i32> {
    let _ = &args.log_level;
    let write_chunks = args
        .write_chunks
        .clone()
        .unwrap_or_else(|| args.sqlite.parent().unwrap_or(Path::new(".")).join("chunks"));
    fs::create_dir_all(&write_chunks).context("failed to create --write-chunks directory")?;

    let plugin_schema = read_json(&find_repo_file("schemas/plugin-export.v1.schema.json")?)?;
    let design_ir_schema = read_json(&find_repo_file("schemas/design-ir.v1.schema.json")?)?;
    let validator = compile_schema(&plugin_schema)?;
    let ir_validator = compile_schema(&design_ir_schema)?;

    let source_dir = materialize_bundle_if_needed(&args.input, &write_chunks, "_import_source")?;
    let manifest_path = source_dir.join("manifest.json");
    if !manifest_path.exists() {
        return Ok(2);
    }

    let manifest_raw = read_json(&manifest_path)?;
    if let Err(errors) = validator.validate(&manifest_raw) {
        for e in errors {
            eprintln!("schema error: {e}");
        }
        return Ok(2);
    }

    let mut export: PluginExport = serde_json::from_value(manifest_raw.clone())
        .context("manifest.json does not match plugin-export.v1 shape")?;
    if export.version != "plugin-export.v1" {
        return Ok(2);
    }
    if !validate_chunk_contract(&source_dir, &export) {
        return Ok(2);
    }
    let preview_chunks = export.chunks.previews.clone().unwrap_or_default();
    let mut selections_index = load_selection_index(&source_dir)?;
    let mut assets_index = load_asset_index(&source_dir)?;
    let mut image_assets_index = load_image_asset_index(&source_dir)?;
    let selection_scope = apply_selection_scope_rewrite(
        &mut export.manifest,
        &mut selections_index,
        &mut assets_index,
        &mut image_assets_index,
    );

    let tokens = load_optional_gz_json(&source_dir, export.manifest.tokens_chunk.as_deref())?;
    let styles = load_optional_gz_json(&source_dir, export.manifest.styles_chunk.as_deref())?;

    let import_ctx = ImportContext {
        project: export.manifest,
        tokens,
        styles,
    };

    if args.dry_run {
        return Ok(0);
    }

    if let Some(parent) = args.sqlite.parent() {
        fs::create_dir_all(parent).context("failed to create sqlite directory")?;
    }

    let mut conn = Connection::open(&args.sqlite).map_err(|e| anyhow!(e)).context("failed to open sqlite")?;
    let ddl = fs::read_to_string(&args.ddl).context("failed to read ddl")?;
    apply_ddl_with_compat(&conn, &ddl)?;
    clear_uikit_usages_if_exists(&conn)?;

    let mut changed_pages = Vec::new();
    let mut failed_pages = Vec::new();
    let now = Utc::now().to_rfc3339();

    for page in &import_ctx.project.pages {
        let key = format!("page_hash:{}", page.id);
        let prev_hash: Option<String> = conn
            .query_row("SELECT value FROM meta WHERE key = ?1", [key.as_str()], |r| r.get(0))
            .optional()
            .map_err(|e| anyhow!(e))?;

        if args.incremental && prev_hash.as_deref() == Some(page.hash.as_str()) {
            continue;
        }

        match process_page(
            &mut conn,
            &source_dir,
            &write_chunks,
            &import_ctx,
            page,
            &ir_validator,
            args.recompute_spacing,
            &now,
        ) {
            Ok(()) => {
                changed_pages.push(page.id.clone());
                conn.execute(
                    "INSERT INTO meta(key, value) VALUES(?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![key, page.hash],
                )
                .map_err(|e| anyhow!(e))?;
            }
            Err(err) => {
                eprintln!("page {} failed: {err:#}", page.id);
                failed_pages.push(page.id.clone());
            }
        }
    }

    if args.purge_missing || selection_scope.is_some() {
        purge_missing_pages(&conn, &import_ctx.project.pages)?;
    }

    conn.execute(
        "INSERT INTO meta(key, value) VALUES('project_manifest', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [serde_json::to_string(&json!({
            "version": "design-ir.v1",
            "project": {
                "fileKey": import_ctx.project.file_key.clone(),
                "exportId": import_ctx.project.export_id.clone(),
                "exportedAt": import_ctx.project.exported_at.clone()
            },
            "pages": import_ctx.project.pages.clone(),
            "changedPages": changed_pages,
            "failedPages": failed_pages
        }))?],
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        "INSERT INTO meta(key, value) VALUES('selections_index', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [serde_json::to_string(&selections_index)?],
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        "INSERT INTO meta(key, value) VALUES('assets_index', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [serde_json::to_string(&assets_index)?],
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        "INSERT INTO meta(key, value) VALUES('image_assets_index', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [serde_json::to_string(&image_assets_index)?],
    )
    .map_err(|e| anyhow!(e))?;

    conn.execute("DELETE FROM tokens_raw", [])
        .map_err(|e| anyhow!(e))?;
    conn.execute(
        "INSERT INTO tokens_raw(json, exported_at) VALUES(?1, ?2)",
        params![serde_json::to_string(&import_ctx.tokens)?, import_ctx.project.exported_at.clone()],
    )
    .map_err(|e| anyhow!(e))?;

    import_uikit(&mut conn, &args, &write_chunks, &validator, &now)?;

    if let Some(path) = &args.write_manifest {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(
            path,
            serde_json::to_vec_pretty(&json!({
                "version": "design-ir.v1",
                "project": {
                    "fileKey": import_ctx.project.file_key.clone(),
                    "exportId": import_ctx.project.export_id.clone(),
                    "exportedAt": import_ctx.project.exported_at.clone()
                },
                "pages": import_ctx.project.pages.clone()
            }))?,
        )?;
    }

    write_gzip_json(
        &write_chunks.join("manifest.json.gz"),
        &json!({
            "version": "design-ir.v1",
            "project": {
                "fileKey": import_ctx.project.file_key.clone(),
                "exportId": import_ctx.project.export_id.clone(),
                "exportedAt": import_ctx.project.exported_at.clone()
            },
            "pages": import_ctx.project.pages.clone()
        }),
    )?;
    write_gzip_json(&write_chunks.join("tokens.json.gz"), &import_ctx.tokens)?;
    write_gzip_json(&write_chunks.join("styles.json.gz"), &import_ctx.styles)?;
    write_gzip_json(
        &write_chunks.join("selections.json.gz"),
        &serde_json::to_value(&selections_index)?,
    )?;
    write_gzip_json(
        &write_chunks.join("assets.json.gz"),
        &serde_json::to_value(&assets_index)?,
    )?;
    write_gzip_json(
        &write_chunks.join("image_assets.json.gz"),
        &serde_json::to_value(&image_assets_index)?,
    )?;
    sync_previews(&source_dir, &preview_chunks, &write_chunks)?;
    sync_assets(&source_dir, &assets_index, &write_chunks)?;
    sync_image_assets(&source_dir, &image_assets_index, &write_chunks)?;

    if failed_pages.is_empty() {
        Ok(0)
    } else {
        Ok(4)
    }
}

fn process_page(
    conn: &mut Connection,
    input_dir: &Path,
    write_chunks: &Path,
    ctx: &ImportContext,
    page: &ManifestPage,
    ir_validator: &JSONSchema,
    recompute_spacing: bool,
    now: &str,
) -> Result<()> {
    let chunk_path = input_dir.join(&page.node_chunk);
    if !chunk_path.exists() {
        return Err(anyhow!("missing chunk {}", chunk_path.display()));
    }

    let chunk_value = read_gzip_json(&chunk_path)?;
    let mut chunk: ChunkPage = serde_json::from_value(chunk_value.clone())
        .with_context(|| format!("invalid nodes chunk for page {}", page.id))?;

    if chunk.page_id.as_deref() != Some(page.id.as_str()) {
        chunk.page_id = Some(page.id.clone());
    }
    if chunk.page_name.is_none() {
        chunk.page_name = Some(page.name.clone());
    }
    for raw in &mut chunk.nodes {
        if raw.page_id.as_deref() != Some(page.id.as_str()) {
            raw.page_id = Some(page.id.clone());
        }
    }

    let ir_nodes = normalize_nodes(&chunk, page.id.as_str(), page.name.as_str(), recompute_spacing);

    let ir_obj = json!({
        "version": "design-ir.v1",
        "project": {
            "fileKey": ctx.project.file_key.clone(),
            "exportId": ctx.project.export_id.clone(),
            "exportedAt": ctx.project.exported_at.clone()
        },
        "pages": [{"id": page.id.clone(), "name": page.name.clone()}],
        "nodes": ir_nodes.clone()
    });

    if let Err(errors) = ir_validator.validate(&ir_obj) {
        for e in errors {
            eprintln!("IR schema error: {e}");
        }
        return Err(anyhow!("IR validation failed for page {}", page.id));
    }

    let tx = conn.unchecked_transaction().map_err(|e| anyhow!(e))?;

    tx.execute(
        "INSERT INTO pages(id, name, frame_count) VALUES(?1, ?2, 0)
         ON CONFLICT(id) DO UPDATE SET name = excluded.name",
        params![page.id.clone(), page.name.clone()],
    )
    .map_err(|e| anyhow!(e))?;

    clear_page(&tx, page.id.as_str())?;

    let mut frame_count = 0_i64;

    let mut ordered_node_ids: Vec<String> = ir_nodes.keys().cloned().collect();
    ordered_node_ids.sort();
    let mut prepared: Vec<(String, IrNode, Value)> = Vec::new();

    for node_id in ordered_node_ids {
        let Some(node_value) = ir_nodes.get(&node_id).cloned() else {
            continue;
        };
        let node: IrNode = serde_json::from_value(node_value.clone())?;
        if node.node_type == "FRAME" {
            frame_count += 1;
        }
        prepared.push((node_id, node, node_value));
    }

    let prepared_node_ids: Vec<String> = prepared.iter().map(|(node_id, _, _)| node_id.clone()).collect();
    clear_conflicting_nodes(&tx, &prepared_node_ids)?;

    let mut inserted: HashSet<String> = HashSet::new();
    let mut pending: Vec<usize> = (0..prepared.len()).collect();
    while !pending.is_empty() {
        let mut progressed = false;
        let mut next_pending: Vec<usize> = Vec::new();
        for idx in pending {
            let (_, node, _) = &prepared[idx];
            let parent_ready = node
                .parent_id
                .as_ref()
                .map(|pid| inserted.contains(pid))
                .unwrap_or(true);
            if !parent_ready {
                next_pending.push(idx);
                continue;
            }

            tx.execute(
                "INSERT INTO nodes(
                  id, page_id, parent_id, type, name,
                  x, y, w, h,
                  abs_x, abs_y, abs_w, abs_h,
                  component_id, variant_props_json,
                  layout_intent_json, style_json, style_refs_json, resources_json, inspection_hints_json, computed_json,
                  updated_at
                ) VALUES(
                  ?1, ?2, ?3, ?4, ?5,
                  ?6, ?7, ?8, ?9,
                  ?10, ?11, ?12, ?13,
                  ?14, ?15,
                  ?16, ?17, ?18, ?19, ?20, ?21,
                  ?22
                )",
                params![
                    node.id.clone(),
                    node.page_id.clone(),
                    node.parent_id.clone(),
                    node.node_type.clone(),
                    node.name.clone(),
                    node.bounds.x,
                    node.bounds.y,
                    node.bounds.w,
                    node.bounds.h,
                    node.abs_bounds.as_ref().map(|r| r.x),
                    node.abs_bounds.as_ref().map(|r| r.y),
                    node.abs_bounds.as_ref().map(|r| r.w),
                    node.abs_bounds.as_ref().map(|r| r.h),
                    node.component_id,
                    node.variant_props.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.layout_intent.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.style.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    serde_json::to_string(&node.style_refs).unwrap_or_else(|_| "{}".to_string()),
                    node.resources.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.inspection_hints.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.computed.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    now
                ],
            )
            .map_err(|e| anyhow!(e))?;
            inserted.insert(node.id.clone());
            progressed = true;
        }
        if progressed {
            pending = next_pending;
            continue;
        }

        // Fallback for broken parent chains/cycles: keep node importable by dropping parent FK.
        for idx in next_pending {
            let (_, node, _) = &prepared[idx];
            tx.execute(
                "INSERT INTO nodes(
                  id, page_id, parent_id, type, name,
                  x, y, w, h,
                  abs_x, abs_y, abs_w, abs_h,
                  component_id, variant_props_json,
                  layout_intent_json, style_json, style_refs_json, resources_json, inspection_hints_json, computed_json,
                  updated_at
                ) VALUES(
                  ?1, ?2, NULL, ?3, ?4,
                  ?5, ?6, ?7, ?8,
                  ?9, ?10, ?11, ?12,
                  ?13, ?14,
                  ?15, ?16, ?17, ?18, ?19, ?20,
                  ?21
                )",
                params![
                    node.id.clone(),
                    node.page_id.clone(),
                    node.node_type.clone(),
                    node.name.clone(),
                    node.bounds.x,
                    node.bounds.y,
                    node.bounds.w,
                    node.bounds.h,
                    node.abs_bounds.as_ref().map(|r| r.x),
                    node.abs_bounds.as_ref().map(|r| r.y),
                    node.abs_bounds.as_ref().map(|r| r.w),
                    node.abs_bounds.as_ref().map(|r| r.h),
                    node.component_id,
                    node.variant_props.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.layout_intent.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.style.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    serde_json::to_string(&node.style_refs).unwrap_or_else(|_| "{}".to_string()),
                    node.resources.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.inspection_hints.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    node.computed.as_ref().map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())),
                    now
                ],
            )
            .map_err(|e| anyhow!(e))?;
            inserted.insert(node.id.clone());
        }
        pending = Vec::new();
    }

    for (node_id, node, node_value) in &prepared {
        let node_id_db = node.id.clone();
        let page_id_db = node.page_id.clone();
        let node_type_db = node.node_type.clone();
        let node_name_db = node.name.clone();

        for (ord, child_id) in node.children_ids.iter().enumerate() {
            tx.execute(
                "INSERT OR IGNORE INTO edges(parent_id, child_id, ord) VALUES(?1, ?2, ?3)",
                params![node_id_db.clone(), child_id, ord as i64],
            )
            .map_err(|e| anyhow!(e))?;
        }

        let path = build_path_for_node(node_id.as_str(), &ir_nodes, page.name.as_str());

        tx.execute(
            "INSERT INTO fts_nodes(node_id, page_id, name, type, path) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![node_id_db.clone(), page_id_db.clone(), node_name_db, node_type_db, path],
        )
        .map_err(|e| anyhow!(e))?;

        if node.node_type == "TEXT" {
            let content = extract_text_content(&node_value);
            tx.execute(
                "INSERT INTO texts(node_id, page_id, content, text_style_json, style_refs_json)
                 VALUES(?1, ?2, ?3, ?4, ?5)",
                params![
                    node_id_db.clone(),
                    page_id_db.clone(),
                    content,
                    node_value
                        .get("style")
                        .and_then(|v| v.get("text"))
                        .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "null".to_string())),
                    node_value
                        .get("styleRefs")
                        .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string()))
                ],
            )
            .map_err(|e| anyhow!(e))?;

            tx.execute(
                "INSERT INTO fts_texts(node_id, page_id, content) VALUES(?1, ?2, ?3)",
                params![node_id_db.clone(), page_id_db.clone(), content],
            )
            .map_err(|e| anyhow!(e))?;
        }

        let style_refs_value = node_value.get("styleRefs").cloned().unwrap_or_else(|| json!({}));
        for (token_key, prop) in extract_token_usage_entries(&style_refs_value) {
            tx.execute(
                "INSERT OR IGNORE INTO token_usages(token_key, node_id, prop, mode) VALUES(?1, ?2, ?3, NULL)",
                params![token_key, node_id_db.clone(), prop],
            )
            .map_err(|e| anyhow!(e))?;
        }
    }

    tx.execute(
        "UPDATE pages SET frame_count = ?2 WHERE id = ?1",
        params![page.id.clone(), frame_count],
    )
    .map_err(|e| anyhow!(e))?;

    tx.commit().map_err(|e| anyhow!(e))?;

    let safe_page_id = sanitize_id(page.id.as_str());
    let chunk_file = write_chunks.join(format!("page_{safe_page_id}.json.gz"));
    write_gzip_json(&chunk_file, &ir_obj)?;

    Ok(())
}

fn normalize_nodes(
    chunk: &ChunkPage,
    page_id: &str,
    _page_name: &str,
    recompute_spacing: bool,
) -> Map<String, Value> {
    let mut map: HashMap<String, IrNode> = HashMap::new();

    for raw in &chunk.nodes {
        let bounds = raw.bounds.clone().unwrap_or(Rect {
            x: 0.0,
            y: 0.0,
            w: 0.0,
            h: 0.0,
        });

        let mut children = raw.children_ids.clone().unwrap_or_default();
        let mut seen = HashSet::new();
        children.retain(|c| seen.insert(c.clone()));

        let name = normalized_name(raw.name.as_deref(), raw.node_type.as_str(), raw.id.as_str());

        let layout_intent = normalize_layout(raw.layout.clone());
        let mut style_refs = Map::new();
        style_refs.insert(
            "variables".to_string(),
            json!(
                raw.refs
                    .as_ref()
                    .and_then(|r| r.variables.clone())
                    .unwrap_or_default()
            ),
        );
        style_refs.insert(
            "styles".to_string(),
            json!(
                raw.refs
                    .as_ref()
                    .and_then(|r| r.styles.clone())
                    .unwrap_or_default()
            ),
        );
        if let Some(variable_props) = raw
            .refs
            .as_ref()
            .and_then(|r| r.variable_props.clone())
            .filter(|props| !props.is_empty())
        {
            style_refs.insert("variableProps".to_string(), Value::Object(variable_props));
        }

        let style = raw.style.clone();
        let resources = raw.resources.clone();
        let inspection_hints = raw.inspection_hints.clone();

        map.insert(
            raw.id.clone(),
            IrNode {
                id: raw.id.clone(),
                node_type: raw.node_type.clone(),
                name,
                page_id: Some(raw.page_id.clone().unwrap_or_else(|| page_id.to_string())),
                parent_id: raw.parent_id.clone(),
                children_ids: children,
                bounds,
                abs_bounds: raw.abs_bounds.clone(),
                component_id: raw.component_id.clone(),
                variant_props: raw.variant_props.clone(),
                layout_intent,
                style,
                style_refs: Value::Object(style_refs),
                resources,
                inspection_hints,
                computed: None,
            },
        );
    }

    let existing_ids: HashSet<String> = map.keys().cloned().collect();
    for node in map.values_mut() {
        let parent = node.parent_id.clone();
        if parent.as_deref() == Some(page_id)
            || parent
                .as_ref()
                .map(|pid| !existing_ids.contains(pid))
                .unwrap_or(false)
        {
            node.parent_id = None;
        }
    }

    if recompute_spacing {
        recompute_computed(&mut map, chunk);
    }

    let mut out = Map::new();
    let mut ids: Vec<String> = map.keys().cloned().collect();
    ids.sort();
    for id in ids {
        if let Some(node) = map.get(&id) {
            out.insert(id.clone(), serde_json::to_value(node).unwrap_or(json!({})));
        }
    }
    out
}

fn recompute_computed(nodes: &mut HashMap<String, IrNode>, chunk: &ChunkPage) {
    let by_id: HashMap<String, ChunkNode> = chunk.nodes.iter().map(|n| (n.id.clone(), n.clone())).collect();

    let ids: Vec<String> = nodes.keys().cloned().collect();
    for id in ids {
        let Some(node) = nodes.get(&id).cloned() else {
            continue;
        };

        let child_ids = node.children_ids.clone();
        if child_ids.is_empty() {
            continue;
        }

        let content_box = compute_content_box(&node);
        let mut edge_gaps = Map::new();
        let mut children_for_axis: Vec<(String, Rect)> = Vec::new();

        for cid in child_ids {
            let Some(child) = nodes.get(&cid) else {
                continue;
            };
            let visible = by_id
                .get(&cid)
                .and_then(|n| n.visible)
                .unwrap_or(true);
            if !visible || child.bounds.w <= 0.0 || child.bounds.h <= 0.0 {
                continue;
            }
            let l = child.bounds.x - content_box.x;
            let t = child.bounds.y - content_box.y;
            let r = (content_box.x + content_box.w) - (child.bounds.x + child.bounds.w);
            let b = (content_box.y + content_box.h) - (child.bounds.y + child.bounds.h);
            edge_gaps.insert(cid.clone(), json!({"t": t, "r": r, "b": b, "l": l}));
            children_for_axis.push((cid, child.bounds.clone()));
        }

        let axis = infer_axis(node.layout_intent.as_ref(), &children_for_axis);
        let mut gaps_between = Vec::new();
        let mut confidence = 0;

        if let Some(axis_val) = axis {
            let mut sorted = children_for_axis;
            sorted.sort_by(|a, b| {
                let sa = if axis_val == "x" { a.1.x } else { a.1.y };
                let sb = if axis_val == "x" { b.1.x } else { b.1.y };
                sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
            });

            let mut clear = true;
            for pair in sorted.windows(2) {
                let (a_id, a_rect) = &pair[0];
                let (b_id, b_rect) = &pair[1];
                let prev_end = if axis_val == "x" {
                    a_rect.x + a_rect.w
                } else {
                    a_rect.y + a_rect.h
                };
                let next_start = if axis_val == "x" { b_rect.x } else { b_rect.y };
                let mut gap = next_start - prev_end;
                if gap < 0.0 {
                    gap = 0.0;
                    clear = false;
                }
                gaps_between.push(json!({"a": a_id, "b": b_id, "axis": axis_val, "value": gap}));
            }

            let explicit = node
                .layout_intent
                .as_ref()
                .and_then(|v| v.get("mode"))
                .and_then(|v| v.as_str())
                .map(|m| m == "HORIZONTAL" || m == "VERTICAL")
                .unwrap_or(false);

            confidence = if explicit && clear {
                3
            } else if explicit {
                2
            } else if !gaps_between.is_empty() {
                2
            } else {
                1
            };
        }

        if let Some(target) = nodes.get_mut(&id) {
            target.computed = Some(json!({
                "contentBox": content_box,
                "edgeGaps": edge_gaps,
                "gapsBetween": gaps_between,
                "confidence": {"spacingInference": confidence}
            }));
        }
    }
}

fn compute_content_box(node: &IrNode) -> Rect {
    let mut rect = node.bounds.clone();
    let padding = node
        .layout_intent
        .as_ref()
        .and_then(|v| v.get("padding"))
        .and_then(|v| v.as_object());

    if let Some(p) = padding {
        let t = p.get("t").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let r = p.get("r").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let b = p.get("b").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let l = p.get("l").and_then(|v| v.as_f64()).unwrap_or(0.0);

        rect.x += l;
        rect.y += t;
        rect.w -= l + r;
        rect.h -= t + b;
    }
    rect
}

fn infer_axis(layout_intent: Option<&Value>, children: &[(String, Rect)]) -> Option<&'static str> {
    let mode = layout_intent
        .and_then(|v| v.get("mode"))
        .and_then(|v| v.as_str());

    if mode == Some("HORIZONTAL") {
        return Some("x");
    }
    if mode == Some("VERTICAL") {
        return Some("y");
    }

    if children.len() < 2 {
        return None;
    }

    let min_x = children.iter().map(|c| c.1.x).fold(f64::MAX, f64::min);
    let max_x = children.iter().map(|c| c.1.x).fold(f64::MIN, f64::max);
    let min_y = children.iter().map(|c| c.1.y).fold(f64::MAX, f64::min);
    let max_y = children.iter().map(|c| c.1.y).fold(f64::MIN, f64::max);

    let spread_x = max_x - min_x;
    let spread_y = max_y - min_y;

    if spread_x > spread_y {
        Some("x")
    } else if spread_y > spread_x {
        Some("y")
    } else {
        None
    }
}

fn normalize_layout(layout: Option<Value>) -> Option<Value> {
    let Some(layout) = layout else {
        return None;
    };
    let mode = match layout.get("mode").and_then(|v| v.as_str()) {
        Some("HORIZONTAL") => "HORIZONTAL",
        Some("VERTICAL") => "VERTICAL",
        _ => return None,
    };

    let mut normalized = Map::new();
    normalized.insert("mode".to_string(), json!(mode));

    if let Some(wrap) = layout
        .get("wrap")
        .and_then(|v| v.as_str())
        .filter(|value| matches!(*value, "NO_WRAP" | "WRAP"))
    {
        normalized.insert("wrap".to_string(), json!(wrap));
    }
    if let Some(padding) = normalize_padding(layout.get("padding")) {
        normalized.insert("padding".to_string(), Value::Object(padding));
    }
    if let Some(gap) = normalize_gap(layout.get("gap")) {
        normalized.insert("gap".to_string(), Value::Object(gap));
    }
    if let Some(align) = normalize_align(layout.get("align")) {
        normalized.insert("align".to_string(), Value::Object(align));
    }
    if let Some(sizing) = normalize_sizing(layout.get("sizing")) {
        normalized.insert("sizing".to_string(), Value::Object(sizing));
    }

    Some(Value::Object(normalized))
}

fn normalize_padding(value: Option<&Value>) -> Option<Map<String, Value>> {
    let source = value?.as_object()?;
    let mut out = Map::new();
    for key in ["t", "r", "b", "l"] {
        if let Some(number) = source.get(key).and_then(|v| v.as_f64()) {
            out.insert(key.to_string(), json!(number));
        }
    }
    if out.is_empty() {
        return None;
    }
    Some(out)
}

fn normalize_gap(value: Option<&Value>) -> Option<Map<String, Value>> {
    let source = value?.as_object()?;
    let mut out = Map::new();
    if let Some(primary) = source.get("primary") {
        if let Some(number) = primary.as_f64() {
            out.insert("primary".to_string(), json!(number));
        } else if let Some(label) = primary.as_str().filter(|value| *value == "AUTO") {
            out.insert("primary".to_string(), json!(label));
        }
    }
    if let Some(wrap) = source.get("wrap") {
        if wrap.is_null() {
            out.insert("wrap".to_string(), Value::Null);
        } else if let Some(number) = wrap.as_f64() {
            out.insert("wrap".to_string(), json!(number));
        }
    }
    if out.is_empty() {
        return None;
    }
    Some(out)
}

fn normalize_align(value: Option<&Value>) -> Option<Map<String, Value>> {
    let source = value?.as_object()?;
    let mut out = Map::new();
    if let Some(primary) = source
        .get("primary")
        .and_then(|v| v.as_str())
        .filter(|value| matches!(*value, "MIN" | "CENTER" | "MAX" | "SPACE_BETWEEN"))
    {
        out.insert("primary".to_string(), json!(primary));
    }
    if let Some(counter) = source
        .get("counter")
        .and_then(|v| v.as_str())
        .filter(|value| matches!(*value, "MIN" | "CENTER" | "MAX" | "STRETCH"))
    {
        out.insert("counter".to_string(), json!(counter));
    }
    if out.is_empty() {
        return None;
    }
    Some(out)
}

fn normalize_sizing(value: Option<&Value>) -> Option<Map<String, Value>> {
    let source = value?.as_object()?;
    let mut out = Map::new();
    if let Some(primary) = source
        .get("primary")
        .and_then(|v| v.as_str())
        .filter(|value| matches!(*value, "FIXED" | "HUG" | "FILL"))
    {
        out.insert("primary".to_string(), json!(primary));
    }
    if let Some(counter) = source
        .get("counter")
        .and_then(|v| v.as_str())
        .filter(|value| matches!(*value, "FIXED" | "HUG" | "FILL"))
    {
        out.insert("counter".to_string(), json!(counter));
    }
    if out.is_empty() {
        return None;
    }
    Some(out)
}

fn extract_token_usage_entries(style_refs: &Value) -> Vec<(String, String)> {
    let mut entries: HashSet<(String, String)> = HashSet::new();

    if let Some(variable_props) = style_refs
        .get("variableProps")
        .and_then(|value| value.as_object())
    {
        for (prop, value) in variable_props {
            match value {
                Value::String(token_key) => {
                    if token_key.starts_with("var:") {
                        entries.insert((token_key.clone(), prop.clone()));
                    }
                }
                Value::Array(values) => {
                    for nested in values {
                        if let Some(token_key) = nested.as_str().filter(|token| token.starts_with("var:")) {
                            entries.insert((token_key.to_string(), prop.clone()));
                        }
                    }
                }
                _ => {}
            }
        }
    }

    if entries.is_empty() {
        if let Some(variables) = style_refs.get("variables").and_then(|value| value.as_array()) {
            for value in variables {
                if let Some(token_key) = value.as_str().filter(|token| token.starts_with("var:")) {
                    entries.insert((token_key.to_string(), "ref".to_string()));
                }
            }
        }
    }

    let mut out: Vec<(String, String)> = entries.into_iter().collect();
    out.sort();
    out
}

fn build_path_for_node(node_id: &str, nodes: &Map<String, Value>, page_name: &str) -> String {
    let mut segments = Vec::new();
    let mut current = node_id.to_string();
    let mut guard = 0;

    while guard < 128 {
        guard += 1;
        let Some(node) = nodes.get(&current) else {
            break;
        };
        let name = normalized_name(
            node.get("name").and_then(|v| v.as_str()),
            node.get("type").and_then(|v| v.as_str()).unwrap_or("NODE"),
            current.as_str(),
        );
        segments.push(name);

        let parent = node.get("parentId").and_then(|v| v.as_str());
        let Some(parent_id) = parent else {
            break;
        };
        if parent_id == page_name || parent_id == current {
            break;
        }
        if !nodes.contains_key(parent_id) {
            break;
        }
        current = parent_id.to_string();
    }

    segments.reverse();
    let mut path = format!("{} / {}", normalize_segment(page_name), segments.join(" / "));
    path = collapse_spaces(&path);
    if path.len() <= 768 {
        return path;
    }

    let final_seg = segments.last().cloned().unwrap_or_else(|| "(unnamed)".to_string());
    let page = normalize_segment(page_name);
    let reserved = page.len() + final_seg.len() + 8;

    if reserved >= 768 {
        return path[path.len().saturating_sub(768)..].to_string();
    }

    let tail_len = 768 - reserved;
    let tail = &path[path.len().saturating_sub(tail_len)..];
    format!("{} / ... / {}", page, tail.replace('\n', " "))
}

fn extract_text_content(node_value: &Value) -> String {
    if let Some(v) = node_value.get("characters").and_then(|v| v.as_str()) {
        return v.to_string();
    }
    if let Some(v) = node_value
        .get("text")
        .and_then(|t| t.get("content"))
        .and_then(|v| v.as_str())
    {
        return v.to_string();
    }
    if let Some(v) = node_value
        .get("style")
        .and_then(|style| style.get("text"))
        .and_then(|text| text.get("characters"))
        .and_then(|v| v.as_str())
    {
        return v.to_string();
    }
    if let Some(runs) = node_value
        .get("style")
        .and_then(|style| style.get("text"))
        .and_then(|text| text.get("textRuns"))
        .and_then(|v| v.as_array())
    {
        let joined = runs
            .iter()
            .filter_map(|run| run.get("characters").and_then(|v| v.as_str()))
            .collect::<Vec<_>>()
            .join("");
        if !joined.is_empty() {
            return joined;
        }
    }
    String::new()
}

fn clear_page(conn: &Connection, page_id: &str) -> Result<()> {
    conn.execute(
        "DELETE FROM token_usages WHERE node_id IN (SELECT id FROM nodes WHERE page_id = ?1)",
        [page_id],
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        "DELETE FROM edges WHERE parent_id IN (SELECT id FROM nodes WHERE page_id = ?1)
         OR child_id IN (SELECT id FROM nodes WHERE page_id = ?1)",
        [page_id],
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute("DELETE FROM fts_nodes WHERE page_id = ?1", [page_id])
        .map_err(|e| anyhow!(e))?;
    conn.execute("DELETE FROM fts_texts WHERE page_id = ?1", [page_id])
        .map_err(|e| anyhow!(e))?;
    conn.execute("DELETE FROM texts WHERE page_id = ?1", [page_id])
        .map_err(|e| anyhow!(e))?;
    conn.execute("DELETE FROM nodes WHERE page_id = ?1", [page_id])
        .map_err(|e| anyhow!(e))?;
    Ok(())
}

fn clear_conflicting_nodes(conn: &Connection, node_ids: &[String]) -> Result<()> {
    if node_ids.is_empty() {
        return Ok(());
    }

    let placeholders = vec!["?"; node_ids.len()].join(", ");
    let node_id_refs: Vec<&str> = node_ids.iter().map(String::as_str).collect();
    let doubled_node_id_refs: Vec<&str> = node_id_refs
        .iter()
        .copied()
        .chain(node_id_refs.iter().copied())
        .collect();

    conn.execute(
        &format!("DELETE FROM token_usages WHERE node_id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!(
            "DELETE FROM edges WHERE parent_id IN ({placeholders}) OR child_id IN ({placeholders})"
        ),
        params_from_iter(doubled_node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!("DELETE FROM uikit_component_usages WHERE node_id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!("DELETE FROM fts_nodes WHERE node_id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!("DELETE FROM fts_texts WHERE node_id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!("DELETE FROM texts WHERE node_id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    conn.execute(
        &format!("DELETE FROM nodes WHERE id IN ({placeholders})"),
        params_from_iter(node_id_refs.iter().copied()),
    )
    .map_err(|e| anyhow!(e))?;
    Ok(())
}

fn purge_missing_pages(conn: &Connection, pages: &[ManifestPage]) -> Result<()> {
    let current: HashSet<String> = pages.iter().map(|p| p.id.clone()).collect();
    let mut stmt = conn
        .prepare("SELECT id FROM pages")
        .map_err(|e| anyhow!(e))?;
    let ids = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| anyhow!(e))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| anyhow!(e))?;

    for id in ids {
        if !current.contains(&id) {
            clear_page(conn, id.as_str())?;
            conn.execute("DELETE FROM pages WHERE id = ?1", [id.as_str()])
                .map_err(|e| anyhow!(e))?;
            conn.execute("DELETE FROM meta WHERE key = ?1", [format!("page_hash:{id}")])
                .map_err(|e| anyhow!(e))?;
        }
    }
    Ok(())
}

fn load_optional_gz_json(input: &Path, rel: Option<&str>) -> Result<Value> {
    let Some(rel) = rel else {
        return Ok(json!({}));
    };
    let p = input.join(rel);
    if !p.exists() {
        return Ok(json!({}));
    }
    read_gzip_json(&p)
}

fn read_json(path: &Path) -> Result<Value> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    serde_json::from_slice(&bytes).with_context(|| format!("invalid json {}", path.display()))
}

fn read_gzip_json(path: &Path) -> Result<Value> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let mut decoder = GzDecoder::new(bytes.as_slice());
    let mut out = Vec::new();
    decoder
        .read_to_end(&mut out)
        .with_context(|| format!("failed to decompress {}", path.display()))?;
    serde_json::from_slice(&out).with_context(|| format!("invalid gz json {}", path.display()))
}

fn write_gzip_json(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let payload = serde_json::to_vec(value)?;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(&payload)?;
    let gz = encoder.finish()?;
    fs::write(path, gz).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn sync_previews(source_dir: &Path, preview_paths: &[String], write_chunks_dir: &Path) -> Result<()> {
    let data_dir = write_chunks_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let previews_dir = data_dir.join("previews");
    fs::create_dir_all(&previews_dir)
        .with_context(|| format!("failed to create {}", previews_dir.display()))?;

    for entry in fs::read_dir(&previews_dir)
        .with_context(|| format!("failed to read {}", previews_dir.display()))?
    {
        let entry = entry?;
        let p = entry.path();
        if entry.file_name().to_string_lossy() == ".gitkeep" {
            continue;
        }
        if p.is_dir() {
            fs::remove_dir_all(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        } else {
            fs::remove_file(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        }
    }

    for rel in preview_paths {
        let src = source_dir.join(rel);
        if !src.exists() {
            continue;
        }
        let Some(file_name) = Path::new(rel).file_name() else {
            continue;
        };
        let dst = previews_dir.join(file_name);
        fs::copy(&src, &dst).with_context(|| {
            format!(
                "failed to copy preview {} -> {}",
                src.display(),
                dst.display()
            )
        })?;
    }

    Ok(())
}

fn load_selection_index(source_dir: &Path) -> Result<SelectionIndex> {
    let p = source_dir.join("selection_index.json.gz");
    if !p.exists() {
        return Ok(SelectionIndex { selections: vec![] });
    }
    let raw = read_gzip_json(&p)?;
    let parsed: SelectionIndex =
        serde_json::from_value(raw).context("invalid selection_index.json.gz")?;
    Ok(parsed)
}

fn load_asset_index(source_dir: &Path) -> Result<AssetIndex> {
    let p = source_dir.join("asset_index.json.gz");
    if !p.exists() {
        return Ok(AssetIndex { assets: vec![] });
    }
    let raw = read_gzip_json(&p)?;
    let parsed: AssetIndex = serde_json::from_value(raw).context("invalid asset_index.json.gz")?;
    Ok(parsed)
}

fn sync_assets(source_dir: &Path, assets: &AssetIndex, write_chunks_dir: &Path) -> Result<()> {
    let data_dir = write_chunks_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let assets_dir = data_dir.join("assets").join("svg");
    fs::create_dir_all(&assets_dir)
        .with_context(|| format!("failed to create {}", assets_dir.display()))?;

    for entry in fs::read_dir(&assets_dir)
        .with_context(|| format!("failed to read {}", assets_dir.display()))?
    {
        let entry = entry?;
        let p = entry.path();
        if entry.file_name().to_string_lossy() == ".gitkeep" {
            continue;
        }
        if p.is_dir() {
            fs::remove_dir_all(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        } else {
            fs::remove_file(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        }
    }

    for asset in &assets.assets {
        if asset.path.trim().is_empty() {
            continue;
        }
        let src = source_dir.join(&asset.path);
        if !src.exists() {
            continue;
        }
        let out_name = if let Some(ext) = Path::new(&asset.path).extension().and_then(|e| e.to_str()) {
            format!("{}.{}", asset.asset_id, ext)
        } else {
            asset.asset_id.clone()
        };
        let dst = assets_dir.join(out_name);
        fs::copy(&src, &dst).with_context(|| {
            format!(
                "failed to copy asset {} -> {}",
                src.display(),
                dst.display()
            )
        })?;
    }
    Ok(())
}

fn load_image_asset_index(source_dir: &Path) -> Result<ImageAssetIndex> {
    let p = source_dir.join("image_asset_index.json.gz");
    if !p.exists() {
        return Ok(ImageAssetIndex { images: vec![] });
    }
    let raw = read_gzip_json(&p)?;
    let parsed: ImageAssetIndex =
        serde_json::from_value(raw).context("invalid image_asset_index.json.gz")?;
    Ok(parsed)
}

fn apply_selection_scope_rewrite(
    manifest: &mut ExportManifest,
    selections: &mut SelectionIndex,
    assets: &mut AssetIndex,
    images: &mut ImageAssetIndex,
) -> Option<String> {
    if manifest.pages.len() != 1 || selections.selections.is_empty() {
        return None;
    }

    let original_page = manifest.pages.first()?.clone();
    if selections
        .selections
        .iter()
        .any(|selection| selection.page_id != original_page.id)
    {
        return None;
    }

    let synthetic_page_id = if selections.selections.len() == 1 {
        format!("selection:{}", selections.selections[0].selection_id)
    } else {
        let joined = selections
            .selections
            .iter()
            .map(|selection| selection.selection_id.as_str())
            .collect::<Vec<_>>()
            .join("__");
        format!("selection:multi:{}", sanitize_id(joined.as_str()))
    };
    let synthetic_page_name = if selections.selections.len() == 1 {
        collapse_spaces(selections.selections[0].name.as_str())
    } else {
        format!("Selection ({})", selections.selections.len())
    };

    if let Some(page) = manifest.pages.first_mut() {
        page.id = synthetic_page_id.clone();
        page.name = if synthetic_page_name.is_empty() {
            "Selection".to_string()
        } else {
            synthetic_page_name
        };
    }

    for selection in &mut selections.selections {
        selection.page_id = synthetic_page_id.clone();
    }
    for asset in &mut assets.assets {
        if asset.page_id == original_page.id {
            asset.page_id = synthetic_page_id.clone();
        }
    }
    for image in &mut images.images {
        if image.page_id == original_page.id {
            image.page_id = synthetic_page_id.clone();
        }
    }

    Some(synthetic_page_id)
}

fn sync_image_assets(
    source_dir: &Path,
    images: &ImageAssetIndex,
    write_chunks_dir: &Path,
) -> Result<()> {
    let data_dir = write_chunks_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let images_dir = data_dir.join("assets").join("images");
    fs::create_dir_all(&images_dir)
        .with_context(|| format!("failed to create {}", images_dir.display()))?;

    for entry in fs::read_dir(&images_dir)
        .with_context(|| format!("failed to read {}", images_dir.display()))?
    {
        let entry = entry?;
        let p = entry.path();
        if entry.file_name().to_string_lossy() == ".gitkeep" {
            continue;
        }
        if p.is_dir() {
            fs::remove_dir_all(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        } else {
            fs::remove_file(&p).with_context(|| format!("failed to remove {}", p.display()))?;
        }
    }

    for image in &images.images {
        if image.path.trim().is_empty() {
            continue;
        }
        let src = source_dir.join(&image.path);
        if !src.exists() {
            continue;
        }
        let ext = Path::new(&image.path)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("bin");
        let dst = images_dir.join(format!("{}.{}", image.image_id, ext));
        fs::copy(&src, &dst).with_context(|| {
            format!(
                "failed to copy image asset {} -> {}",
                src.display(),
                dst.display()
            )
        })?;
    }
    Ok(())
}

fn materialize_bundle_if_needed(
    input_dir: &Path,
    write_chunks_dir: &Path,
    materialized_dir_name: &str,
) -> Result<PathBuf> {
    let manifest_path = input_dir.join("manifest.json");
    if manifest_path.exists() {
        return Ok(input_dir.to_path_buf());
    }

    let bundle_path = input_dir.join("plugin-export.bundle.json");
    if !bundle_path.exists() {
        return Ok(input_dir.to_path_buf());
    }

    let expanded_root = write_chunks_dir.join(materialized_dir_name);
    if expanded_root.exists() {
        fs::remove_dir_all(&expanded_root)
            .with_context(|| format!("failed to cleanup {}", expanded_root.display()))?;
    }
    fs::create_dir_all(&expanded_root)
        .with_context(|| format!("failed to create {}", expanded_root.display()))?;

    let bundle_raw = fs::read(&bundle_path)
        .with_context(|| format!("failed to read {}", bundle_path.display()))?;
    let bundle: BundlePayload =
        serde_json::from_slice(&bundle_raw).context("invalid plugin-export.bundle.json")?;

    for file in bundle.files {
        if file.path.trim().is_empty() {
            continue;
        }
        if file.mime.trim().is_empty() {
            continue;
        }
        let decoded = B64
            .decode(file.bytes_base64.as_bytes())
            .with_context(|| format!("invalid base64 for {}", file.path))?;
        let out_path = expanded_root.join(&file.path);
        if let Some(parent) = out_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let enc = file.encoding.as_deref().unwrap_or("binary-base64");
        if enc == "json-utf8" && file.path.ends_with(".gz") {
            let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
            encoder.write_all(&decoded)?;
            let gz = encoder.finish()?;
            fs::write(&out_path, gz)
                .with_context(|| format!("failed to write {}", out_path.display()))?;
        } else {
            fs::write(&out_path, decoded)
                .with_context(|| format!("failed to write {}", out_path.display()))?;
        }
    }

    Ok(expanded_root)
}

fn resolve_uikit_input(args: &ImportArgs) -> Option<PathBuf> {
    if let Some(explicit) = &args.ui_kit_input {
        return Some(explicit.clone());
    }
    let parent = args.input.parent()?;
    let candidate = parent.join("import-ui-kit");
    if candidate.exists() {
        Some(candidate)
    } else {
        None
    }
}

fn import_uikit(
    conn: &mut Connection,
    args: &ImportArgs,
    write_chunks: &Path,
    plugin_validator: &JSONSchema,
    now: &str,
) -> Result<()> {
    let Some(ui_kit_input) = resolve_uikit_input(args) else {
        return Ok(());
    };

    let source_dir = materialize_bundle_if_needed(&ui_kit_input, write_chunks, "_uikit_source")?;
    let manifest_path = source_dir.join("manifest.json");
    if !manifest_path.exists() {
        return Ok(());
    }

    let manifest_raw = read_json(&manifest_path)?;
    if let Err(errors) = plugin_validator.validate(&manifest_raw) {
        for e in errors {
            eprintln!("ui-kit schema error: {e}");
        }
        return Err(anyhow!("ui-kit manifest schema validation failed"));
    }
    let export: PluginExport = serde_json::from_value(manifest_raw.clone())
        .context("ui-kit manifest.json does not match plugin-export.v1 shape")?;
    if export.version != "plugin-export.v1" {
        return Err(anyhow!("ui-kit export version must be plugin-export.v1"));
    }
    if !validate_chunk_contract(&source_dir, &export) {
        return Err(anyhow!("ui-kit chunk contract validation failed"));
    }

    let tokens = load_optional_gz_json(&source_dir, export.manifest.tokens_chunk.as_deref())?;
    let styles = load_optional_gz_json(&source_dir, export.manifest.styles_chunk.as_deref())?;

    let tx = conn.unchecked_transaction().map_err(|e| anyhow!(e))?;
    tx.execute("DELETE FROM uikit_component_usages", [])
        .map_err(|e| anyhow!(e))?;
    tx.execute("DELETE FROM uikit_components", [])
        .map_err(|e| anyhow!(e))?;
    tx.execute("DELETE FROM uikit_pages", [])
        .map_err(|e| anyhow!(e))?;
    tx.execute("DELETE FROM uikit_tokens_raw", [])
        .map_err(|e| anyhow!(e))?;
    tx.execute("DELETE FROM uikit_styles_raw", [])
        .map_err(|e| anyhow!(e))?;

    for page in &export.manifest.pages {
        tx.execute(
            "INSERT INTO uikit_pages(id, name, hash) VALUES(?1, ?2, ?3)",
            params![page.id, page.name, page.hash],
        )
        .map_err(|e| anyhow!(e))?;

        let chunk_path = source_dir.join(&page.node_chunk);
        let chunk_value = read_gzip_json(&chunk_path)?;
        let chunk: ChunkPage = serde_json::from_value(chunk_value)
            .with_context(|| format!("invalid ui-kit nodes chunk {}", page.node_chunk))?;

        for raw in chunk.nodes {
            if raw.node_type != "COMPONENT" && raw.node_type != "COMPONENT_SET" {
                continue;
            }
            let name = normalized_name(raw.name.as_deref(), raw.node_type.as_str(), raw.id.as_str());
            let bounds = raw.bounds.unwrap_or(Rect {
                x: 0.0,
                y: 0.0,
                w: 0.0,
                h: 0.0,
            });
            let style_refs = json!({
                "variables": raw
                    .refs
                    .as_ref()
                    .and_then(|r| r.variables.clone())
                    .unwrap_or_default(),
                "styles": raw
                    .refs
                    .as_ref()
                    .and_then(|r| r.styles.clone())
                    .unwrap_or_default()
            });
            tx.execute(
                "INSERT INTO uikit_components(
                    id, page_id, type, name, x, y, w, h,
                    variant_props_json, style_json, style_refs_json, updated_at
                ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    raw.id,
                    page.id,
                    raw.node_type,
                    name,
                    bounds.x,
                    bounds.y,
                    bounds.w,
                    bounds.h,
                    raw.variant_props
                        .as_ref()
                        .map(serde_json::to_string)
                        .transpose()?,
                    raw.style.as_ref().map(serde_json::to_string).transpose()?,
                    serde_json::to_string(&style_refs)?,
                    now
                ],
            )
            .map_err(|e| anyhow!(e))?;
        }
    }

    tx.execute(
        "INSERT INTO uikit_component_usages(component_id, node_id, page_id, node_name, node_type, match_strategy)
         SELECT c.id, n.id, n.page_id, n.name, n.type, 'direct_id'
         FROM nodes n
         JOIN uikit_components c ON c.id = n.component_id",
        [],
    )
    .map_err(|e| anyhow!(e))?;

    // Fallback mapping when component IDs differ across files:
    // 1) normalized exact name match for INSTANCE -> COMPONENT_SET
    tx.execute(
        "INSERT OR IGNORE INTO uikit_component_usages(component_id, node_id, page_id, node_name, node_type, match_strategy)
         SELECT c.id, n.id, n.page_id, n.name, n.type, 'name'
         FROM nodes n
         JOIN uikit_components c
           ON c.type = 'COMPONENT_SET'
          AND lower(replace(replace(replace(replace(replace(c.name, ' ', ''), '/', ''), '-', ''), '_', ''), ',', ''))
              = lower(replace(replace(replace(replace(replace(n.name, ' ', ''), '/', ''), '-', ''), '_', ''), ',', ''))
         WHERE n.type = 'INSTANCE'
           AND n.component_id IS NOT NULL",
        [],
    )
    .map_err(|e| anyhow!(e))?;

    // 2) alias-based name mapping for common wrapper instance names
    tx.execute(
        "INSERT OR IGNORE INTO uikit_component_usages(component_id, node_id, page_id, node_name, node_type, match_strategy)
         WITH aliases(node_alias, uikit_name) AS (
           VALUES
             ('TextInput', 'Dynamic / Text Field'),
             ('Autocomplete', 'Dynamic / Multiple Combobox'),
             ('Dynamic / Checkbox', 'Dynamic / Checkbox')
         )
         SELECT c.id, n.id, n.page_id, n.name, n.type, 'alias'
         FROM nodes n
         JOIN aliases a ON n.name = a.node_alias
         JOIN uikit_components c ON c.type = 'COMPONENT_SET' AND c.name = a.uikit_name
         WHERE n.type = 'INSTANCE'
           AND n.component_id IS NOT NULL",
        [],
    )
    .map_err(|e| anyhow!(e))?;

    tx.execute(
        "INSERT INTO uikit_tokens_raw(json, exported_at) VALUES(?1, ?2)",
        params![serde_json::to_string(&tokens)?, export.manifest.exported_at.clone()],
    )
    .map_err(|e| anyhow!(e))?;
    tx.execute(
        "INSERT INTO uikit_styles_raw(json, exported_at) VALUES(?1, ?2)",
        params![serde_json::to_string(&styles)?, export.manifest.exported_at.clone()],
    )
    .map_err(|e| anyhow!(e))?;
    tx.execute(
        "INSERT INTO meta(key, value) VALUES('uikit_manifest', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [serde_json::to_string(&json!({
            "version": "plugin-export.v1",
            "exportId": export.manifest.export_id,
            "fileKey": export.manifest.file_key,
            "exportedAt": export.manifest.exported_at,
            "pages": export.manifest.pages
        }))?],
    )
    .map_err(|e| anyhow!(e))?;

    tx.commit().map_err(|e| anyhow!(e))?;

    let uikit_chunks_dir = write_chunks.join("uikit");
    write_gzip_json(
        &uikit_chunks_dir.join("manifest.json.gz"),
        &json!({
            "version": "plugin-export.v1",
            "manifest": export.manifest,
            "chunks": export.chunks
        }),
    )?;
    write_gzip_json(&uikit_chunks_dir.join("tokens.json.gz"), &tokens)?;
    write_gzip_json(&uikit_chunks_dir.join("styles.json.gz"), &styles)?;

    Ok(())
}

fn apply_ddl_with_compat(conn: &Connection, ddl: &str) -> Result<()> {
    match conn.execute_batch(ddl) {
        Ok(()) => {
            ensure_schema_compat(conn)?;
            Ok(())
        }
        Err(err) => {
            let msg = err.to_string();
            if !msg.contains("expressions prohibited in PRIMARY KEY") {
                return Err(anyhow!(err)).context("failed to apply ddl");
            }

            let patched = ddl.replace(
                "PRIMARY KEY(token_key, node_id, prop, COALESCE(mode, ''))",
                "PRIMARY KEY(token_key, node_id, prop, mode)",
            );
            conn.execute_batch(&patched)
                .map_err(|e| anyhow!(e))
                .context("failed to apply compatibility ddl patch")?;
            conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_token_usages_pk_compat
                 ON token_usages(token_key, node_id, prop, IFNULL(mode, ''))",
                [],
            )
            .map_err(|e| anyhow!(e))
            .context("failed to apply compatibility unique index")?;
            ensure_schema_compat(conn)?;
            Ok(())
        }
    }
}

fn ensure_schema_compat(conn: &Connection) -> Result<()> {
    let mut has_nodes_table = false;
    let mut node_columns = HashSet::new();
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='nodes' LIMIT 1")
        .map_err(|e| anyhow!(e))?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| anyhow!(e))?;
    for row in rows {
        let name = row.map_err(|e| anyhow!(e))?;
        if name == "nodes" {
            has_nodes_table = true;
        }
    }

    if has_nodes_table {
        let mut stmt = conn
            .prepare("PRAGMA table_info('nodes')")
            .map_err(|e| anyhow!(e))?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(1))
            .map_err(|e| anyhow!(e))?;
        for col in rows {
            node_columns.insert(col.map_err(|e| anyhow!(e))?);
        }
        if !node_columns.contains("resources_json") {
            conn.execute("ALTER TABLE nodes ADD COLUMN resources_json TEXT", [])
                .map_err(|e| anyhow!(e))
                .context("failed to add resources_json column to nodes")?;
        }
        if !node_columns.contains("inspection_hints_json") {
            conn.execute("ALTER TABLE nodes ADD COLUMN inspection_hints_json TEXT", [])
                .map_err(|e| anyhow!(e))
                .context("failed to add inspection_hints_json column to nodes")?;
        }
    }

    let has_uikit_usages = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='uikit_component_usages' LIMIT 1",
            [],
            |_r| Ok(()),
        )
        .optional()
        .map_err(|e| anyhow!(e))?
        .is_some();

    if has_uikit_usages {
        let mut has_match_strategy = false;
        let mut stmt = conn
            .prepare("PRAGMA table_info('uikit_component_usages')")
            .map_err(|e| anyhow!(e))?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(1))
            .map_err(|e| anyhow!(e))?;
        for col in rows {
            let c = col.map_err(|e| anyhow!(e))?;
            if c == "match_strategy" {
                has_match_strategy = true;
                break;
            }
        }
        if !has_match_strategy {
            conn.execute(
                "ALTER TABLE uikit_component_usages ADD COLUMN match_strategy TEXT NOT NULL DEFAULT 'direct_id'",
                [],
            )
            .map_err(|e| anyhow!(e))
            .context("failed to add match_strategy column to uikit_component_usages")?;
        }
    }

    Ok(())
}

fn clear_uikit_usages_if_exists(conn: &Connection) -> Result<()> {
    let has_uikit_usages = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='uikit_component_usages' LIMIT 1",
            [],
            |_r| Ok(()),
        )
        .optional()
        .map_err(|e| anyhow!(e))?
        .is_some();
    if has_uikit_usages {
        conn.execute("DELETE FROM uikit_component_usages", [])
            .map_err(|e| anyhow!(e))
            .context("failed to clear uikit_component_usages before page import")?;
    }
    Ok(())
}

fn compile_schema(schema: &Value) -> Result<JSONSchema> {
    let compiled =
        JSONSchema::compile(schema).map_err(|e| anyhow!("failed to compile json schema: {e}"))?;
    Ok(compiled)
}

fn find_repo_file(rel: &str) -> Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    for dir in cwd.ancestors() {
        let candidate = dir.join(rel);
        if candidate.exists() {
            return Ok(candidate);
        }
    }

    if let Ok(repo_root) = std::env::var("REPO_ROOT") {
        let p = PathBuf::from(repo_root).join(rel);
        if p.exists() {
            return Ok(p);
        }
    }

    Err(anyhow!("cannot resolve required file: {rel}"))
}

fn validate_chunk_contract(input_dir: &Path, export: &PluginExport) -> bool {
    let mut ok = true;
    let listed_nodes: HashSet<String> = export
        .chunks
        .nodes
        .clone()
        .unwrap_or_default()
        .into_iter()
        .collect();

    for page in &export.manifest.pages {
        if !listed_nodes.is_empty() && !listed_nodes.contains(&page.node_chunk) {
            eprintln!(
                "manifest/chunks mismatch: page {} nodeChunk {} not listed in chunks.nodes",
                page.id, page.node_chunk
            );
            ok = false;
        }
        if !input_dir.join(&page.node_chunk).exists() {
            eprintln!("missing page chunk file: {}", page.node_chunk);
            ok = false;
        }
    }

    let manifest_tokens = export.manifest.tokens_chunk.clone();
    let chunks_tokens = export.chunks.tokens.clone();
    if manifest_tokens.is_some() && chunks_tokens.is_some() && manifest_tokens != chunks_tokens {
        eprintln!("manifest/chunks mismatch: tokensChunk differs from chunks.tokens");
        ok = false;
    }
    if let Some(tokens_rel) = manifest_tokens.or(chunks_tokens) {
        if !input_dir.join(&tokens_rel).exists() {
            eprintln!("missing tokens chunk file: {tokens_rel}");
            ok = false;
        }
    }

    let manifest_styles = export.manifest.styles_chunk.clone();
    let chunks_styles = export.chunks.styles.clone();
    if manifest_styles.is_some() && chunks_styles.is_some() && manifest_styles != chunks_styles {
        eprintln!("manifest/chunks mismatch: stylesChunk differs from chunks.styles");
        ok = false;
    }
    if let Some(styles_rel) = manifest_styles.or(chunks_styles) {
        if !input_dir.join(&styles_rel).exists() {
            eprintln!("missing styles chunk file: {styles_rel}");
            ok = false;
        }
    }

    for preview in export.chunks.previews.clone().unwrap_or_default() {
        if !input_dir.join(&preview).exists() {
            eprintln!("missing preview file: {preview}");
            ok = false;
        }
    }

    ok
}

fn sanitize_id(value: &str) -> String {
    value
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn normalized_name(name: Option<&str>, node_type: &str, id: &str) -> String {
    let cleaned = collapse_spaces(name.unwrap_or(""));
    if cleaned.is_empty() {
        format!("(unnamed:{}:{})", node_type, id)
    } else {
        cleaned
    }
}

fn normalize_segment(seg: &str) -> String {
    let s = collapse_spaces(seg);
    if s.is_empty() {
        "(unnamed)".to_string()
    } else {
        s
    }
}

fn collapse_spaces(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_layout_drops_none_mode() {
        assert_eq!(normalize_layout(Some(json!({ "mode": "NONE" }))), None);
    }

    #[test]
    fn normalize_layout_keeps_only_explicit_fields() {
        let layout = normalize_layout(Some(json!({
            "mode": "HORIZONTAL",
            "padding": { "t": 8, "l": 12 },
            "gap": { "primary": 16 }
        })))
        .expect("layout should normalize");

        assert_eq!(
            layout,
            json!({
                "mode": "HORIZONTAL",
                "padding": { "t": 8.0, "l": 12.0 },
                "gap": { "primary": 16.0 }
            })
        );
    }

    #[test]
    fn extract_token_usage_entries_prefers_semantic_variable_props() {
        let entries = extract_token_usage_entries(&json!({
            "variables": ["var:generic"],
            "styles": [],
            "variableProps": {
                "fill": ["var:fill-primary"],
                "padding.l": ["var:space-sm"]
            }
        }));

        assert_eq!(
            entries,
            vec![
                ("var:fill-primary".to_string(), "fill".to_string()),
                ("var:space-sm".to_string(), "padding.l".to_string()),
            ]
        );
    }

    #[test]
    fn extract_token_usage_entries_falls_back_to_refs() {
        let entries = extract_token_usage_entries(&json!({
            "variables": ["var:one", "var:two"],
            "styles": []
        }));

        assert_eq!(
            entries,
            vec![
                ("var:one".to_string(), "ref".to_string()),
                ("var:two".to_string(), "ref".to_string()),
            ]
        );
    }
}
