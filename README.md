# Local Figma Port

A local-first bridge between Figma and AI coding agents.

Local Figma Port connects Figma design data directly to AI coding tools.

It gives agents like Codex, Claude Code, and Cursor direct access to normalized design data
(frames, components, styles) — without manual export.

It does not require a paid Figma account or Figma Dev Mode.

## Who is this for

- Developers using AI coding tools with Figma
- Teams building UI from structured design systems
- Anyone tired of manual Figma → code handoff

## Quickstart

1. Install the tool
2. Start the local server
3. In Figma, import the plugin via `manifest.json` (see below), then export a node
4. In your coding agent, use the shortcut `$Local Figma Port` followed by your prompt

Takes under 2 minutes.

## Figma Plugin Setup

To use the Local Figma Port plugin in Figma:

1. Open Figma Desktop
2. Go to `Plugins → Development → Import plugin from manifest...`
3. Select `packages/figma-exporter-plugin/manifest.json`
4. Run `Plugins → Development → Local Figma Port`

You can now select a node and export it from Figma using the plugin.

Requires Figma Desktop (plugin development mode is not available in the browser).

## Using the Skill

After exporting a design slice, the context becomes available to your coding agent.

Use the Local Figma Port skill in your agent:

`$Local Figma Port implement this screen in React`

The shortcut tells the agent to use the exported Local Figma Port context instead of guessing from scratch.

The more specific your prompt, the better the result will be.

You can combine it with any prompt:
- `$Local Figma Port build this component`
- `$Local Figma Port generate layout with Tailwind`
- `$Local Figma Port extract styles and structure`

You can check what is in MCP now:
- `$Local Figma Port what do you see?`

## Model Recommendations

For best results, use strong coding agents backed by large models.

Recommended environments:
- Codex / Codex App
- Claude Code
- Cursor

These tools provide sufficient reasoning and context handling to work effectively with Local Figma Port.

Using weaker coding agents or smaller models is not recommended, as they may struggle to interpret the exported design context and produce lower-quality results.

## Figma Access Note

Works without Dev Mode only for Figma projects you own.

To use designs from someone else:
- duplicate the file into your own drafts or workspace
- export from your copy

It is built as a local-first system with strict control over exported scope.

At a high level, it consists of four parts:

- a Figma plugin for scoped export
- a local MCP server
- a data optimizer/importer that reshapes raw export data into agent-friendly context
- a skill that helps coding agents use that context correctly

Instead of dumping an entire Figma file into an agent, Local Figma Port exports only the narrow scope selected by the developer. That keeps the context focused, makes the data easier for coding agents to understand, and avoids wasting Figma credits on irrelevant parts of the file.

The export can include layout structure, styles, icons, graphics, and preview screenshots. Those previews can also be used for visual control when your agent workflow has Playwright available.

If your Figma file is structured well, you can also export a UI kit separately and let agents reuse mapped components from it.

## Demo

Short walkthrough: exporting a design slice and using it with an agent.

![Demo](https://github.com/echo-ae/local_figma_port/releases/download/v1.0.0/screencast.gif)

## Problem

AI coding agents struggle with large, unstructured design files.

Passing an entire Figma file into context is noisy, expensive, and usually leads to weaker code generation. The agent has to search through too much unrelated design data, while the developer only needs one frame, one flow, or one component.

## Solution

Local Figma Port lets you export only the relevant part of a Figma design and send it to a local MCP server.

The raw export is validated and normalized into a structure that is easier for agents to query than raw Figma JSON. Agents receive a focused design context instead of a giant design dump, which leads to much better implementation quality.

## Features

- Export a specific frame, component, or selection from Figma.
- Keep the exported scope intentionally narrow instead of sending the whole file.
- Normalize raw plugin output into an agent-friendly local store.
- Expose design context through a local MCP server and local HTTP import endpoint.
- Export icons, graphics, layout metadata, styles, and preview screenshots.
- Use screenshots as an additional verification aid in Playwright-enabled workflows.
- Export a UI kit separately and reuse mapped components from it when the Figma file is built correctly.
- Work locally instead of relying on broad remote design ingestion.

## How It Works

1. In Figma, you select the exact frame, component, or subtree you want to give to the agent.
2. The Figma plugin exports a scoped bundle from that current selection.
3. The bundle is sent to the local import endpoint at `http://127.0.0.1:7331/import-bundle`.
4. The importer/optimizer validates the bundle and rewrites it into a normalized local store.
5. The local MCP server exposes that exported scope to coding agents.
6. The Local Figma Port skill lets agents access and traverse the exported scope without guessing.

If auto-post fails, the plugin can fall back to a downloadable bundle JSON for manual import.

The MCP server does not automatically ingest the whole Figma file. It only knows about the scope you explicitly exported.

## Result

Instead of asking an agent to reason over an entire design system, you give it exactly the design slice it needs. In practice, frontend implementation becomes close to "autopilot" for well-structured UI work.

## Installation

### 2-Minute Quickstart

1. Run the install script for your platform.
2. Start the local MCP server.
3. In Figma, select the node you want and click `Export` in the `Local Figma Port` plugin.
4. Ask your coding agent to use the exported Local Figma Port context.

### Requirements

- Figma Desktop
- Node.js LTS
- On macOS and Linux: `sqlite3` must be installed with `FTS5` enabled

On Windows, the release bootstrap installer can install Node.js automatically
if it is missing, and the Windows bundle ships its own `sqlite3.exe`.
On macOS, the release bootstrap installer can install Node.js and a Homebrew
`sqlite3` build with `FTS5` enabled if they are missing.

### Quick Start By Platform

#### macOS

Install:

```bash
curl -fsSL https://raw.githubusercontent.com/echo-ae/local_figma_port/main/mac-install.sh | bash
```

Uninstall:

```bash
~/Library/Application\ Support/LocalFigmaPort/bundle/current/scripts/uninstall/macos.sh
```

Uses the release bootstrap installer and downloads the matching prebuilt bundle.

#### Windows

Install:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/echo-ae/local_figma_port/main/windows-install.ps1 | iex"
```

Uninstall:

```powershell
pwsh -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\LocalFigmaPort\bundle\current\scripts\uninstall\windows.ps1"
```

Uses the release bootstrap installer and downloads the matching prebuilt bundle.

#### Linux

Install:

```bash
./scripts/install/linux.sh
```

Uninstall:

```bash
./scripts/uninstall/linux.sh
```

Uses the native bash installer for Codex, Claude Code, and Cursor.

### macOS

Recommended install from the latest GitHub release:

```bash
curl -fsSL https://raw.githubusercontent.com/echo-ae/local_figma_port/main/mac-install.sh | bash
```

The bootstrap script:

- detects `arm64` vs `x64`
- downloads the matching prebuilt macOS bundle from GitHub Releases
- installs Node.js and a Homebrew `sqlite3` build with `FTS5` support if they are missing
- asks which coding agent to configure and applies the install for that target
- writes project-local config into the current working directory when you choose `Claude Code` or `Cursor`

If you are installing for `Claude Code` or `Cursor`, run the command from the
workspace root you want to configure.

If you are building from a checked-out repository instead of using a release
bundle, see [Build](#build).

Default state root on macOS:

```bash
~/Library/Application\ Support/LocalFigmaPort
```

### Windows

Recommended install from the latest GitHub release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/echo-ae/local_figma_port/main/windows-install.ps1 | iex"
```

The bootstrap script:

- detects `amd64` vs `arm64`
- downloads the matching prebuilt Windows bundle from GitHub Releases
- installs PowerShell 7 and Node.js LTS if they are missing
- asks which coding agent to configure and applies the install for that target
- writes project-local config into the current working directory when you choose `Claude Code` or `Cursor`

If you are installing for `Claude Code` or `Cursor`, run the command from the
workspace root you want to configure.

If you are building from a checked-out repository instead of using a release
bundle, see [Build](#build).

Default state root on Windows:

```powershell
$env:LOCALAPPDATA\LocalFigmaPort
```

### Linux

Install for one or more targets:

```bash
./scripts/install/linux.sh
```

Supported target numbers:

- `1` = Codex
- `2` = Claude Code
- `3` = Cursor

The Linux installer validates that the system `sqlite3` CLI supports `FTS5`
before it finishes.

Default state root on Linux:

```bash
~/.local/share/local-figma-port
```

## Build

Source builds and checked-out repository installs need the full local toolchain.

### Build Requirements

- Runtime requirements above
- Rust toolchain and Cargo
- On Windows: Visual Studio Build Tools (or Visual Studio) with C++ build tools

### Source Install By Platform

macOS:

```bash
./scripts/install/macos.sh
```

Windows:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\install\windows.ps1
```

Linux:

```bash
./scripts/install/linux.sh
```

### Windows Build Notes

The source Windows installer builds the Rust importer locally. If `link.exe` is
missing, install Visual Studio Build Tools with the C++ workload and re-run the
installer from a new PowerShell session.

The installer prepares `sqlite3.exe` in the Local Figma Port state directory
and points the MCP server at that exact binary, so Windows users do not need a
separate SQLite install on `PATH`.

By default, the installer first looks for the pinned SQLite archive on the
project's latest GitHub release and falls back to the official upstream SQLite
tools archive if needed. You can override that with
`LOCAL_FIGMA_PORT_RELEASE_TAG` or `LOCAL_FIGMA_PORT_SQLITE_ZIP_URL`.

The current pinned Windows bundle is SQLite `3.51.3`
(`sqlite-tools-win-x64-3510300.zip`). The official SQLite download page
currently ships Windows command-line tools for x64. On Windows ARM64, that
binary runs through x64 emulation.

Release maintainers can use the short runbook in
[WINDOWS_SQLITE_RELEASE_ASSET.md](/Users/alex/Documents/src/figma_port/docs/WINDOWS_SQLITE_RELEASE_ASSET.md).

### macOS Build Notes

The source macOS installer builds the Rust importer locally, so `rustc` and
`cargo` are only required for checked-out repository installs.

The release bootstrap installer downloads a prebuilt importer bundle and does
not require Rust.

Release maintainers can build macOS release ZIPs with:

```bash
./scripts/release/package-macos.sh --target all --build
```

On Apple Silicon, add the x64 Rust target first if you have not installed it yet:

```bash
rustup target add x86_64-apple-darwin
```

That produces:

- `out/release/macos/local-figma-port-macos-arm64.zip`
- `out/release/macos/local-figma-port-macos-x64.zip`

## Start And Stop The Local MCP Server

> Important: the local MCP server must be started manually before exporting from Figma or asking an agent to use Local Figma Port.

The installers start the server once at the end of installation for validation, but day-to-day work still expects you to start it yourself when you begin a session.

### macOS / Linux

Start:

```bash
./scripts/runtime/start.sh
```

Stop:

```bash
./scripts/runtime/stop.sh
```

### Windows

Start:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\runtime\start.ps1
```

Stop:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\runtime\stop.ps1
```

By default the server listens on port `7331`.

## Typical Workflow

1. Install Local Figma Port for your coding environment.
2. Start the local MCP server manually.
3. Open Figma Desktop and open the file you want to work with.
4. Select the exact frame, component, or subtree you want to export.
5. Run the `Local Figma Port` plugin.
6. Choose an export mode:
   - `Design element` for a focused implementation task
   - `UI-kit` for a reusable component library snapshot
7. Click `Export`.
8. The plugin sends that export to the local MCP server, and the importer updates the local store.
9. Ask your coding agent to use the exported Local Figma Port context.

After export, the MCP server should expose only the scope you exported, not the entire Figma file.

If you want a different node to appear in MCP, select that node in Figma and export again.

## Developing the Figma Plugin

1. Open Figma Desktop.
2. Go to `Plugins -> Development -> Import plugin from manifest...`
3. Select `packages/figma-exporter-plugin/manifest.json`.
4. Run `Plugins -> Development -> Local Figma Port`.
5. Select a frame, component, or subtree in the canvas.
6. Click `Export` in the plugin UI.

## Repository Layout

- `packages/figma-exporter-plugin` - Figma plugin source
- `packages/design-importer` - Rust importer/optimizer
- `packages/mcp-server` - TypeScript MCP server
- `scripts` - installers, start/stop helpers, verification, and maintenance utilities
- `schemas` - source-of-truth schemas
- `sql` - SQLite schema

## Architecture

For a high-level system overview, data flow, storage model, and contributor map, see [ARCHITECTURE.md](./ARCHITECTURE.md).

For contributor-focused documentation, see [docs/README.md](./docs/README.md).

## Contributing

This project is maintained by a single author.

Contributions are not accepted at the moment.
Feel free to open issues for discussion.

## Commercial Use

If you are a company interested in using this project,
please reach out for a commercial license.

This helps support further development.

## License

This project is licensed under the PolyForm Noncommercial License 1.0.0.

- Free for personal and non-commercial use
- Commercial use requires a separate license

See [LICENSE](./LICENSE.md) and [COMMERCIAL_LICENSE](./COMMERCIAL_LICENSE.md) for details.
