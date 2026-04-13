# figma-exporter-plugin

Figma plugin module that exports document data in `plugin-export.v1` format.

## Entry Points

- plugin runtime: `src/main.ts`
- exporter logic: `src/export/*`
- UI panel: `src/ui.html`
- manifest: `manifest.json`

## Responsibilities

- Export selected scope (selection/current page/all pages)
- Provide export mode switch:
  - `Design element`
  - `UI-kit`
- Include auto-layout fields (`padding`, `gap`, `wrap`, `align`)
- Include style and variable refs
- Generate artifacts compatible with importer schema:
  - `manifest.json`
  - `nodes/page_{pageId}.json.gz`
  - `tokens.json.gz`
  - `styles.json.gz`
- In `Design element` mode, add PNG previews (selection or per-page target) to bundle
- In `Design element` selection mode, export original SVG assets (`asset_index.json.gz` + `assets/*.svg`)
- In `Design element` mode, export bitmap image assets from node paints (`image_asset_index.json.gz` + `assets/images/*`)
- Send bundle to local MCP endpoint (`POST /import-bundle`) immediately after export
- Fallback to manual `Download Bundle JSON` when endpoint delivery fails

## Build

```bash
cd <repo-root>/packages/figma-exporter-plugin
# install dependencies with your preferred Node package manager
npm install --no-package-lock
npm run build
```

## Install Into Figma Desktop

1. Open Figma Desktop.
2. `Plugins` -> `Development` -> `Import plugin from manifest...`
3. Select the manifest path for your install mode:

- checked-out repository:

`<repo-root>/packages/figma-exporter-plugin/manifest.json`

- bootstrap/release install:

use the manifest path printed by the installer

4. Run from `Plugins` -> `Development` -> `Local Figma Port`.

## Output Usage

- Default flow: plugin sends bundle directly to:
  - `http://127.0.0.1:7331/import-bundle`
- In checked-out repository installs, the default landing zones are:
  - `<repo-root>/imports/plugin-export.bundle.json` (`Design element`)
  - `<repo-root>/import-ui-kit/plugin-export.bundle.json` (`UI-kit`)
- In bootstrap/release installs, the runtime uses the installed bundle and state directories instead of the repository root, so rely on the installer/runtime paths rather than assuming `<repo-root>`
- If auto-send fails, use fallback button `Download Bundle JSON`.
