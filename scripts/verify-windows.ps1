[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$Cursor,
    [switch]$All,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [string]$CodexAppData = $(if ($env:CODEX_APP_DATA_DIR) { $env:CODEX_APP_DATA_DIR } elseif ($env:APPDATA) { Join-Path $env:APPDATA "Codex" } else { Join-Path $env:USERPROFILE "AppData/Roaming/Codex" }),
    [string]$CodexAppExe = $(if ($env:CODEX_APP_EXE) { $env:CODEX_APP_EXE } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs/Codex/Codex.exe" } else { Join-Path $env:USERPROFILE "AppData/Local/Programs/Codex/Codex.exe" }),
    [string]$ClaudeHome = $(if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }),
    [string]$CursorHome = (Join-Path $env:USERPROFILE ".cursor")
)

. (Join-Path $PSScriptRoot "lib/ensure-pwsh7.ps1")
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
        [string]$Label
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

    if ($server.command -ne "node") {
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
    $Cursor = $true
}

if (-not ($Codex -or $CodexApp -or $ClaudeCode -or $Cursor)) {
    $Codex = $true
    $ClaudeCode = $true
    $Cursor = $true
}

$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$RepoSkill = Join-Path $ProjectRoot "SKILL.md"
$RepoMcpEntry = Join-Path $ProjectRoot "packages/mcp-server/dist/mcp-stdio.js"
$RepoSqliteBin = Join-Path $StateDir "bin/sqlite3.exe"
$RepoSqlite = Join-Path (Join-Path $StateDir "data") "design_store.sqlite"
$RepoData = Join-Path $StateDir "data"
$RepoMcpNodeModules = Join-Path $ProjectRoot "packages/mcp-server/node_modules"

$AgentsMarkerStart = "<!-- FIGMA PORT MANAGED BLOCK START -->"
$AgentsMarkerEnd = "<!-- FIGMA PORT MANAGED BLOCK END -->"
$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"

$script:Failures = 0

if (-not (Test-Path $RepoSkill)) {
    Fail "repo skill exists ($RepoSkill)"
}
if (-not (Test-Path $RepoMcpEntry)) {
    Fail "built MCP entry exists ($RepoMcpEntry)"
}
if (-not (Test-Path $RepoSqliteBin)) {
    Fail "bundled sqlite3.exe exists ($RepoSqliteBin)"
}
if (-not (Test-Path $RepoData)) {
    Fail "stable data dir exists ($RepoData)"
}
if (-not (Test-Path $RepoMcpNodeModules)) {
    Fail "MCP runtime dependencies exist ($RepoMcpNodeModules)"
}
Check-SqliteFts5 -Path $RepoSqliteBin -Label "bundled sqlite3.exe supports FTS5"

if ($Codex) {
    Check-CodexSharedConfig -LabelPrefix "Codex"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle '$Local Figma Port' -Label "AGENTS.md advertises `$Local Figma Port`"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle $AgentsMarkerStart -Label "AGENTS.md has managed skill block"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle (To-PosixPath $RepoSkill) -Label "AGENTS.md points at repo skill"
}

if ($CodexApp) {
    if (-not (Test-Path $CodexAppData) -and -not (Test-Path $CodexAppExe)) {
        Fail "Codex App installation detected (checked $CodexAppData and $CodexAppExe)"
    } else {
        Ok "Codex App installation detected"
    }
    Check-CodexSharedConfig -LabelPrefix "Codex App"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle '$Local Figma Port' -Label "Codex App alias is exposed through AGENTS.md"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle $AgentsMarkerStart -Label "Codex App AGENTS.md has managed skill block"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle (To-PosixPath $RepoSkill) -Label "Codex App AGENTS.md points at repo skill"
}

if ($ClaudeCode) {
    Check-Contains -Path (Join-Path $ClaudeHome "skills/local-figma-port/SKILL.md") -Needle "name: local-figma-port" -Label "Claude Code skill installed"
    Check-JsonServer -Path (Join-Path $ProjectRoot ".mcp.json") -RepoMcpEntry $RepoMcpEntry -RepoSqliteBin $RepoSqliteBin -RepoSqlite $RepoSqlite -RepoData $RepoData -Label "Claude project MCP config points at repo build"
    Check-Contains -Path (Join-Path $ProjectRoot "CLAUDE.md") -Needle $ClaudeMarkerStart -Label "CLAUDE.md has managed skill block"
    Check-Contains -Path (Join-Path $ProjectRoot "CLAUDE.md") -Needle '$Local Figma Port' -Label "CLAUDE.md advertises `$Local Figma Port`"
    Check-Contains -Path (Join-Path $ProjectRoot "CLAUDE.md") -Needle (To-PosixPath $RepoSkill) -Label "CLAUDE.md points at repo skill"
}

if ($Cursor) {
    Check-JsonServer -Path (Join-Path $ProjectRoot ".cursor/mcp.json") -RepoMcpEntry $RepoMcpEntry -RepoSqliteBin $RepoSqliteBin -RepoSqlite $RepoSqlite -RepoData $RepoData -Label "Cursor project MCP config points at repo build"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle '$Local Figma Port' -Label "Cursor alias is exposed through AGENTS.md"
    Check-Contains -Path (Join-Path $ProjectRoot "AGENTS.md") -Needle $AgentsMarkerEnd -Label "AGENTS.md managed block is complete"
}

if ($script:Failures -gt 0) {
    exit 1
}

Write-Host "[verify-windows] all checks passed"
