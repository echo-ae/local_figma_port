# Local Figma Port

Export scoped Figma design context for AI coding agents.

For developers using Codex, Claude Code, or Cursor with Figma-driven frontend work.

Local Figma Port is a source-available toolkit made of four parts:

- a Figma plugin for scoped export
- a local MCP server
- a data optimizer/importer that reshapes raw export data into agent-friendly context
- a skill that helps coding agents use that context correctly

Instead of dumping an entire Figma file into an agent, Local Figma Port exports only the narrow scope selected by the developer. That keeps the context focused, makes the data easier for coding agents to understand, and avoids wasting Figma credits on irrelevant parts of the file.

The export can include layout structure, styles, icons, graphics, and preview screenshots. Those previews can also be used for visual control when your agent workflow has Playwright available.

If your Figma file is structured well, you can also export a UI kit separately and let agents reuse mapped components from it.

## Demo

![Demo](https://github.com/echo-ae/local_figma_port/releases/download/v1.0.0/screencast.gif)

## Problem

AI coding agents struggle with large design files.

Passing an entire Figma file into context is noisy, expensive, and usually leads to weaker code generation. The agent has to search through too much unrelated design data, while the developer only needs one frame, one flow, or one component.

## Solution

Local Figma Port lets you export only the relevant part of a Figma design and send it to a local MCP server.

The raw export is validated and normalized into a structure that is much easier for coding agents to query than raw Figma JSON. Agents receive a focused design context instead of a giant design dump, which leads to much better implementation quality.

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
6. The repository skill helps agents traverse the exported scope without guessing.

If auto-post fails, the plugin can fall back to a downloadable bundle JSON for manual import.

The MCP server does not automatically ingest the whole Figma file. It only knows about the scope you explicitly exported.

## Result

Instead of asking an agent to reason over an entire design system, you give it exactly the design slice it needs. In practice, frontend implementation becomes much closer to "autopilot" for well-structured UI work.

## Installation

### 2-Minute Quickstart

1. Run the install script for your platform.
2. Start the local MCP server.
3. In Figma, select the node you want and click `Export` in the `Local Figma Port` plugin.
4. Ask your coding agent to use the exported Local Figma Port context.

### Requirements

- Node.js LTS
- Rust toolchain and Cargo
- Figma Desktop

### Quick Start By Platform

| Platform | Install | Uninstall | Notes |
| --- | --- | --- | --- |
| macOS | `./scripts/install-mac.sh` | `./scripts/uninstall-mac.sh` | Native installer for Codex, Codex App, Claude Code, and Cursor |
| Windows | `pwsh -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1` | `pwsh -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1` | Native installer for the same targets |
| Linux | `./scripts/install-linux.sh` | `./scripts/uninstall-linux.sh` | Native bash installer for Codex, Claude Code, and Cursor |

### macOS

Install for one or more targets:

```bash
./scripts/install-mac.sh
```

Supported target numbers:

- `1` = Codex
- `2` = Codex App
- `3` = Claude Code
- `4` = Cursor

The installer:

- installs local runtime dependencies
- validates and builds the importer/server toolchain
- installs or syncs the Local Figma Port skill where needed
- updates local MCP configuration
- uses a stable per-user state directory instead of repository-local runtime state

Default state root on macOS:

```bash
~/Library/Application\ Support/LocalFigmaPort
```

### Windows

Install for one or more targets:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

Default state root on Windows:

```powershell
$env:LOCALAPPDATA\LocalFigmaPort
```

### Linux

Install for one or more targets:

```bash
./scripts/install-linux.sh
```

Supported target numbers:

- `1` = Codex
- `2` = Claude Code
- `3` = Cursor

Default state root on Linux:

```bash
~/.local/share/local-figma-port
```

## Start And Stop The Local MCP Server

> Important: the local MCP server must be started manually before exporting from Figma or asking an agent to use Local Figma Port.

The installers start the server once at the end of installation for validation, but day-to-day work still expects you to start it yourself when you begin a session.

### macOS / Linux

Start:

```bash
./scripts/start_mcp.sh
```

Stop:

```bash
./scripts/stop_mcp.sh
```

### Windows

Start:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\start_mcp.ps1
```

Stop:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\stop_mcp.ps1
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

## Figma Plugin Setup For Development

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
