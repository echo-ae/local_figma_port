[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$ClaudeDesktop,
    [switch]$Cursor,
    [switch]$All,
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ConfigRoot = "",
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [string]$CodexAppData = $(if ($env:CODEX_APP_DATA_DIR) { $env:CODEX_APP_DATA_DIR } elseif ($env:APPDATA) { Join-Path $env:APPDATA "Codex" } else { Join-Path $env:USERPROFILE "AppData/Roaming/Codex" }),
    [string]$CodexAppExe = $(if ($env:CODEX_APP_EXE) { $env:CODEX_APP_EXE } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs/Codex/Codex.exe" } else { Join-Path $env:USERPROFILE "AppData/Local/Programs/Codex/Codex.exe" }),
    [string]$ClaudeHome = $(if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }),
    [string]$ClaudeDesktopConfig = $(if ($env:CLAUDE_DESKTOP_CONFIG) { $env:CLAUDE_DESKTOP_CONFIG } elseif ($env:APPDATA) { Join-Path $env:APPDATA "Claude/claude_desktop_config.json" } else { Join-Path $env:USERPROFILE "AppData/Roaming/Claude/claude_desktop_config.json" }),
    [string]$CursorHome = (Join-Path $env:USERPROFILE ".cursor")
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
. (Join-Path $LibDir "ensure-pwsh7.ps1")
. (Join-Path $LibDir "windows_agent_paths.ps1")
Restart-InPwsh7IfNeeded -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -ForwardArgs $MyInvocation.UnboundArguments

$ErrorActionPreference = "Stop"

function To-PosixPath([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Fail([string]$Message) {
    Write-Error $Message
    $script:Failures += 1
}

function Ok([string]$Message) {
    Write-Host "[verify-windows] ok: $Message"
}

function Check-Contains {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        Fail "$Label (missing file: $Path)"
        return
    }
    if ((Get-Content -Raw $Path).Contains($Needle)) {
        Ok $Label
    } else {
        Fail $Label
    }
}

function Check-JsonServer {
    param(
        [string]$Path,
        [string]$RepoMcpEntry,
        [string]$RepoSqliteBin,
        [string]$RepoSqlite,
        [string]$RepoData,
        [string]$Label,
        [string]$ExpectedCommand = "node"
    )

    if (-not (Test-Path $Path)) {
        Fail "$Label (missing file: $Path)"
        return
    }

    $parsed = Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable
    $server = $parsed.mcpServers["local-figma-port"]
    if ($null -eq $server) {
        Fail $Label
        return
    }

    if ($server.command -ne $ExpectedCommand) {
        Fail $Label
        return
    }
    if ($server.args.Count -lt 1 -or $server.args[0] -ne (To-PosixPath $RepoMcpEntry)) {
        Fail $Label
        return
    }
    if (
        $server.env.SQLITE3_BIN -ne (To-PosixPath $RepoSqliteBin) -or
        $server.env.SQLITE_PATH -ne (To-PosixPath $RepoSqlite) -or
        $server.env.DATA_DIR -ne (To-PosixPath $RepoData)
    ) {
        Fail $Label
        return
    }

    Ok $Label
}

function Check-SqliteFts5 {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        Fail "$Label (missing file: $Path)"
        return
    }

    & $Path ":memory:" "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail $Label
        return
    }

    Ok $Label
}

function Check-ClaudeAgentRegistered {
    param([string]$Label)

    $agentPath = Join-Path $ClaudeHome "agents/local-figma-port.md"
    Check-Contains -Path $agentPath -Needle "name: local-figma-port" -Label "Claude Code subagent file installed"
    Ok $Label
}

function Check-ClaudeUserMcpServer {
    param([string]$Label)

    $claudeCli = Get-Command "claude" -ErrorAction SilentlyContinue
    if (-not $claudeCli) {
        $candidates = @(
            (Join-Path $env:USERPROFILE ".local/bin/claude"),
            (Join-Path $env:USERPROFILE ".local/bin/claude.cmd"),
            (Join-Path $env:USERPROFILE ".local/bin/claude.exe"),
            (Join-Path $env:USERPROFILE ".local/bin/claude.bat"),
            (Join-Path $env:USERPROFILE ".local/bin/claude.ps1"),
            (Join-Path $env:USERPROFILE ".claude/local/claude"),
            (Join-Path $env:USERPROFILE ".claude/local/claude.exe"),
            (Join-Path $env:USERPROFILE ".claude/local/claude.cmd"),
            (Join-Path $env:LOCALAPPDATA "Microsoft/WinGet/Links/claude.exe"),
            (Join-Path $env:LOCALAPPDATA "Microsoft/WinGet/Links/claude.cmd"),
            (Join-Path $env:APPDATA "npm/claude.cmd"),
            (Join-Path $env:APPDATA "npm/claude.exe"),
            (Join-Path $env:APPDATA "npm/claude"),
            (Join-Path $env:USERPROFILE "AppData/Roaming/npm/claude.cmd"),
            (Join-Path $env:USERPROFILE "AppData/Roaming/npm/claude.exe"),
            (Join-Path $env:USERPROFILE "AppData/Roaming/npm/claude")
        )
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate -PathType Leaf)) {
                $claudeCli = [pscustomobject]@{ Source = $candidate }
                break
            }
        }
    }
    if (-not $claudeCli) {
        Fail "$Label (missing command: claude)"
        return
    }

    $output = (& $claudeCli.Source mcp get local-figma-port --scope user 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label (claude mcp get failed)"
        return
    }

    $expected = @(
        (To-PosixPath $RepoMcpEntry),
        (To-PosixPath $RepoSqliteBin),
        (To-PosixPath $RepoSqlite),
        (To-PosixPath $RepoData)
    )
    foreach ($needle in $expected) {
        if (-not $output.Contains($needle)) {
            Fail $Label
            return
        }
    }

    Ok $Label
}

function Check-ClaudeDesktopBundle {
    param([string]$Label)

    $bundlePath = Get-LfpClaudeDesktopBundlePath -StateDir $StateDir
    if (-not (Test-Path $bundlePath -PathType Leaf)) {
        Fail "$Label (missing file: $bundlePath)"
        return
    }

    $extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("local-figma-port-claude-desktop-verify-" + [guid]::NewGuid().ToString("N"))
    try {
        Expand-Archive -LiteralPath $bundlePath -DestinationPath $extractRoot -Force
        $manifestPath = Join-Path $extractRoot "manifest.json"
        $serverEntry = Join-Path $extractRoot "server/mcp-stdio.js"
        $schemaPath = Join-Path $extractRoot "schemas/mcp-tools.v1.schema.json"

        if (-not (Test-Path $manifestPath -PathType Leaf)) {
            Fail "$Label (missing manifest.json)"
            return
        }
        if (-not (Test-Path $serverEntry -PathType Leaf)) {
            Fail "$Label (missing server/mcp-stdio.js)"
            return
        }
        if (-not (Test-Path $schemaPath -PathType Leaf)) {
            Fail "$Label (missing schemas/mcp-tools.v1.schema.json)"
            return
        }

        $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -AsHashtable
        $server = $manifest.server
        if ($null -eq $server -or $server.type -ne "node" -or $server.entry_point -ne "server/mcp-stdio.js") {
            Fail $Label
            return
        }

        $mcpConfig = $server.mcp_config
        if ($null -eq $mcpConfig -or $mcpConfig.command -ne "node") {
            Fail $Label
            return
        }
        if ($mcpConfig.args.Count -lt 1 -or $mcpConfig.args[0] -ne '${__dirname}/server/mcp-stdio.js') {
            Fail $Label
            return
        }
        if (
            $mcpConfig.env.SQLITE3_BIN -ne (To-PosixPath $RepoSqliteBin) -or
            $mcpConfig.env.SQLITE_PATH -ne (To-PosixPath $RepoSqlite) -or
            $mcpConfig.env.DATA_DIR -ne (To-PosixPath $RepoData)
        ) {
            Fail $Label
            return
        }

        Ok $Label
    } finally {
        if (Test-Path $extractRoot) {
            Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Check-CodexSharedConfig {
    param([string]$LabelPrefix)

    Check-Contains -Path (Join-Path $CodexHome "skills/local-figma-port/SKILL.md") -Needle "name: local-figma-port" -Label "$LabelPrefix skill installed"
    Check-Contains -Path (Join-Path $CodexHome "config.toml") -Needle $CodexTomlMarkerStart -Label "$LabelPrefix config has managed block"
    Check-Contains -Path (Join-Path $CodexHome "config.toml") -Needle (To-PosixPath $RepoMcpEntry) -Label "$LabelPrefix config points at repo MCP build"
    Check-Contains -Path (Join-Path $CodexHome "config.toml") -Needle (To-PosixPath $RepoSqliteBin) -Label "$LabelPrefix config points at bundled sqlite3.exe"
    Check-Contains -Path (Join-Path $CodexHome "config.toml") -Needle (To-PosixPath $RepoSqlite) -Label "$LabelPrefix config points at stable sqlite path"
    Check-Contains -Path (Join-Path $CodexHome "config.toml") -Needle (To-PosixPath $RepoData) -Label "$LabelPrefix config points at stable data dir"
    if ((Get-Content -Raw (Join-Path $CodexHome "config.toml")).Contains("[mcp_servers.design_local]")) {
        Fail "$LabelPrefix config removed legacy design_local block"
    } else {
        Ok "$LabelPrefix config removed legacy design_local block"
    }
}

if ($All) {
    $Codex = $true
    $CodexApp = $true
    $ClaudeCode = $true
    $ClaudeDesktop = $true
    $Cursor = $true
}

if (-not ($Codex -or $CodexApp -or $ClaudeCode -or $ClaudeDesktop -or $Cursor)) {
    $Codex = $true
    $ClaudeCode = $true
    $Cursor = $true
}

$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
    $ConfigRoot = $ProjectRoot
} else {
    $ConfigRoot = [System.IO.Path]::GetFullPath($ConfigRoot)
}
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$RepoSkill = Join-Path $ProjectRoot "SKILL.md"
$RepoMcpEntry = Join-Path $ProjectRoot "packages/mcp-server/dist/mcp-stdio.js"
$RepoMcpHttpEntry = Join-Path $ProjectRoot "packages/mcp-server/dist/index.js"
$RepoMcpPackageJson = Join-Path $ProjectRoot "packages/mcp-server/package.json"
$RepoSqliteBin = Join-Path $StateDir "bin/sqlite3.exe"
$RepoSqlite = Join-Path (Join-Path $StateDir "data") "design_store.sqlite"
$RepoData = Join-Path $StateDir "data"
$RepoMcpNodeModules = Join-Path $ProjectRoot "packages/mcp-server/node_modules"
$RepoImporterExe = Join-Path $ProjectRoot "packages/design-importer/target/release/design-importer.exe"
$RepoPluginEntry = Join-Path $ProjectRoot "packages/figma-exporter-plugin/dist/main.js"
$RepoPluginManifest = Join-Path $ProjectRoot "packages/figma-exporter-plugin/manifest.json"
$ClaudeUserConfig = Join-Path (Split-Path -Parent $ClaudeHome) ".claude.json"

$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"

$script:Failures = 0

if (-not (Test-Path $RepoSkill)) {
    Fail "repo skill exists ($RepoSkill)"
}
if (-not (Test-Path $RepoMcpEntry)) {
    Fail "built MCP entry exists ($RepoMcpEntry)"
}
if (-not (Test-Path $RepoMcpHttpEntry)) {
    Fail "built MCP HTTP entry exists ($RepoMcpHttpEntry)"
} elseif (-not ((Get-Content -Raw $RepoMcpHttpEntry).Contains("IMPORTER_EXE"))) {
    Fail "MCP HTTP entry supports prebuilt importer execution"
} else {
    Ok "MCP HTTP entry supports prebuilt importer execution"
}
if (-not (Test-Path $RepoMcpPackageJson)) {
    Fail "MCP package metadata exists ($RepoMcpPackageJson)"
}
if (-not (Test-Path $RepoSqliteBin)) {
    Fail "bundled sqlite3.exe exists ($RepoSqliteBin)"
}
if (-not (Test-Path $RepoData)) {
    Fail "stable data dir exists ($RepoData)"
}
if (-not (Test-Path $RepoImporterExe)) {
    Fail "importer executable exists ($RepoImporterExe)"
}
if (-not (Test-Path $RepoPluginEntry)) {
    Fail "Figma plugin bundle exists ($RepoPluginEntry)"
}
if (-not (Test-Path $RepoPluginManifest)) {
    Fail "Figma plugin manifest exists ($RepoPluginManifest)"
}
if (-not (Test-Path $RepoMcpNodeModules)) {
    Fail "MCP runtime dependencies exist ($RepoMcpNodeModules)"
}
Check-SqliteFts5 -Path $RepoSqliteBin -Label "bundled sqlite3.exe supports FTS5"

if ($Codex) {
    Check-CodexSharedConfig -LabelPrefix "Codex"
}

if ($CodexApp) {
    $resolved = Resolve-LfpCodexAppInstallation -CodexAppData $CodexAppData -CodexAppExe $CodexAppExe
    if (-not [string]::IsNullOrWhiteSpace($resolved.DataDir)) {
        $CodexAppData = $resolved.DataDir
    }
    if (-not [string]::IsNullOrWhiteSpace($resolved.ExePath)) {
        $CodexAppExe = $resolved.ExePath
    }

    if (-not $resolved.IsInstalled) {
        Fail "Codex App installation detected (checked $CodexAppData and $CodexAppExe)"
    } else {
        Ok "Codex App installation detected"
    }
    Check-CodexSharedConfig -LabelPrefix "Codex App"
}

if ($ClaudeCode) {
    Check-Contains -Path (Join-Path $ClaudeHome "skills/local-figma-port/SKILL.md") -Needle "name: local-figma-port" -Label "Claude Code skill installed"
    Check-ClaudeAgentRegistered -Label "Claude Code subagent is registered"
    Check-ClaudeUserMcpServer -Label "Claude Code user MCP config points at repo build"
}

if ($ClaudeDesktop) {
    Check-ClaudeDesktopBundle -Label "Claude Desktop extension bundle points at repo build"
}

if ($Cursor) {
    Check-JsonServer -Path (Join-Path $CursorHome "mcp.json") -RepoMcpEntry $RepoMcpEntry -RepoSqliteBin $RepoSqliteBin -RepoSqlite $RepoSqlite -RepoData $RepoData -Label "Cursor global MCP config points at repo build"
}

if ($script:Failures -gt 0) {
    exit 1
}

Write-Host "[verify-windows] all checks passed"
