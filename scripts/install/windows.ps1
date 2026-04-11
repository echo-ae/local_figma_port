[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$Cursor,
    [switch]$All,
    [switch]$UsePrebuilt,
    [string]$Targets,
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ConfigRoot = "",
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [string]$CodexAppData = $(if ($env:CODEX_APP_DATA_DIR) { $env:CODEX_APP_DATA_DIR } elseif ($env:APPDATA) { Join-Path $env:APPDATA "Codex" } else { Join-Path $env:USERPROFILE "AppData/Roaming/Codex" }),
    [string]$CodexAppExe = $(if ($env:CODEX_APP_EXE) { $env:CODEX_APP_EXE } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs/Codex/Codex.exe" } else { Join-Path $env:USERPROFILE "AppData/Local/Programs/Codex/Codex.exe" }),
    [string]$ClaudeHome = $(if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE ".claude" }),
    [string]$CursorHome = (Join-Path $env:USERPROFILE ".cursor")
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
. (Join-Path $LibDir "ensure-pwsh7.ps1")
. (Join-Path $LibDir "windows_agent_paths.ps1")
Restart-InPwsh7IfNeeded -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -ForwardArgs $MyInvocation.UnboundArguments

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
    $ConfigRoot = $ProjectRoot
} else {
    New-Item -ItemType Directory -Force -Path $ConfigRoot | Out-Null
    $ConfigRoot = (Resolve-Path $ConfigRoot).Path
}
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$RepoSkill = Join-Path $ProjectRoot "SKILL.md"
$RepoMcpDir = Join-Path $ProjectRoot "packages/mcp-server"
$RepoMcpPackageJson = Join-Path $RepoMcpDir "package.json"
$RepoMcpEntry = Join-Path $ProjectRoot "packages/mcp-server/dist/mcp-stdio.js"
$RepoMcpHttpEntry = Join-Path $ProjectRoot "packages/mcp-server/dist/index.js"
$RepoImporterExe = Join-Path $ProjectRoot "packages/design-importer/target/release/design-importer.exe"
$RepoPluginDir = Join-Path $ProjectRoot "packages/figma-exporter-plugin"
$RepoPluginEntry = Join-Path $RepoPluginDir "dist/main.js"
$RepoPluginManifest = Join-Path $RepoPluginDir "manifest.json"
$RepoPluginPackageJson = Join-Path $RepoPluginDir "package.json"
$RepoSqliteBinDir = Join-Path $StateDir "bin"
$RepoSqliteBin = Join-Path $RepoSqliteBinDir "sqlite3.exe"
$RepoSqliteArchiveDir = Join-Path $StateDir "downloads"
$RepoSqliteAssetName = "sqlite-tools-win-x64-3510300.zip"
$RepoSqliteArchive = Join-Path $RepoSqliteArchiveDir $RepoSqliteAssetName
$RepoSqliteVersion = "3.51.3"
$RepoSqliteGitHubRepo = "echo-ae/local_figma_port"
$RepoSqliteReleaseTag = $env:LOCAL_FIGMA_PORT_RELEASE_TAG
$RepoSqliteReleaseAssetUrl = $(if ([string]::IsNullOrWhiteSpace($RepoSqliteReleaseTag)) {
    "https://github.com/$RepoSqliteGitHubRepo/releases/latest/download/$RepoSqliteAssetName"
} else {
    "https://github.com/$RepoSqliteGitHubRepo/releases/download/$RepoSqliteReleaseTag/$RepoSqliteAssetName"
})
$RepoSqliteUpstreamUrl = "https://sqlite.org/2026/$RepoSqliteAssetName"
$ProjectData = Join-Path $ProjectRoot "data"
$RepoData = Join-Path $StateDir "data"
$RepoSqlite = Join-Path $RepoData "design_store.sqlite"
$Timestamp = Get-Date -Format "yyyyMMddHHmmss"

$AgentsMarkerStart = "<!-- FIGMA PORT MANAGED BLOCK START -->"
$AgentsMarkerEnd = "<!-- FIGMA PORT MANAGED BLOCK END -->"
$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$ClaudeMarkerEnd = "<!-- FIGMA PORT CLAUDE BLOCK END -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"
$CodexTomlMarkerEnd = "# <<< FIGMA PORT MCP END <<<"

function Show-Usage {
    @"
usage: .\scripts\install\windows.ps1 [-Codex] [-ClaudeCode] [-Cursor] [-All]

options:
  -Codex                 install for Codex
  -CodexApp              install for Codex App
  -ClaudeCode            install for Claude Code
  -Cursor                install for Cursor
  -All                   install for all supported targets
  -UsePrebuilt           install from a prebuilt runtime bundle without local Rust/TypeScript builds
  -Targets LIST          install for comma-separated target numbers: 1=Codex, 2=Codex App, 3=Claude Code, 4=Cursor
  -ProjectRoot PATH      override repository root
  -ConfigRoot PATH       override workspace root for project-local config files (.mcp.json, .cursor/mcp.json, CLAUDE.md, AGENTS.md)
  -StateDir PATH         override Local Figma Port state root
  -CodexHome PATH        override Codex home
  -CodexAppData PATH     override Codex App data dir
  -CodexAppExe PATH      override Codex App executable path
  -ClaudeHome PATH       override Claude home
  -CursorHome PATH       override Cursor home
"@
}

function To-PosixPath([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Apply-TargetToken {
    param([string]$Token)

    switch ($Token.ToLowerInvariant()) {
        "1" { $script:Codex = $true; return }
        "codex" { $script:Codex = $true; return }
        "2" { $script:CodexApp = $true; return }
        "codex-app" { $script:CodexApp = $true; return }
        "codex_app" { $script:CodexApp = $true; return }
        "3" { $script:ClaudeCode = $true; return }
        "claude" { $script:ClaudeCode = $true; return }
        "claude-code" { $script:ClaudeCode = $true; return }
        "claude_code" { $script:ClaudeCode = $true; return }
        "4" { $script:Cursor = $true; return }
        "cursor" { $script:Cursor = $true; return }
        default { throw "Unknown target token: $Token" }
    }
}

function Apply-TargetsCsv {
    param([string]$Csv)

    $script:Codex = $false
    $script:CodexApp = $false
    $script:ClaudeCode = $false
    $script:Cursor = $false

    if ($Csv -match '^\s*all\s*$') {
        $script:Codex = $true
        $script:CodexApp = $true
        $script:ClaudeCode = $true
        $script:Cursor = $true
        return
    }

    foreach ($token in ($Csv -split ',')) {
        $trimmed = $token.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            Apply-TargetToken -Token $trimmed
        }
    }
}

function Remove-ManagedBlockText {
    param(
        [string]$Text,
        [string]$StartMarker,
        [string]$EndMarker
    )

    $lines = $Text -split "`r?`n"
    $skip = $false
    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -eq $StartMarker) {
            $skip = $true
            continue
        }
        if ($line -eq $EndMarker) {
            $skip = $false
            continue
        }
        if (-not $skip) {
            $output.Add($line)
        }
    }
    return ($output -join "`n").TrimEnd()
}

function Require-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Ensure-MsvcLinkerAvailable {
    $linker = Get-Command "link.exe" -ErrorAction SilentlyContinue
    if ($linker) {
        return
    }

    throw @"
Rust is installed, but the MSVC linker (link.exe) is not available.

Local Figma Port builds the Rust importer on Windows, which requires the
Visual C++ toolchain.

Install one of these:
- Visual Studio 2017 or later with Desktop development with C++
- Build Tools for Visual Studio with the C++ build tools workload

Then re-run this installer from a new PowerShell session.
"@
}

function Invoke-DownloadFile {
    param(
        [string[]]$Urls,
        [string]$Destination,
        [string]$Label
    )

    $attemptErrors = New-Object System.Collections.Generic.List[string]
    foreach ($url in $Urls) {
        try {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
            }
            Write-Host "[install-windows] downloading $Label from $url"
            Invoke-WebRequest -Uri $url -OutFile $Destination
            if (-not (Test-Path $Destination -PathType Leaf)) {
                throw "download completed but file is missing"
            }
            return
        } catch {
            $attemptErrors.Add("${url}: $($_.Exception.Message)")
        }
    }

    throw "Failed to download ${Label}. Attempts:`n$($attemptErrors -join "`n")"
}

function Test-SqliteFts5 {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $false
    }

    & $Path ":memory:" "CREATE VIRTUAL TABLE temp.t USING fts5(x); DROP TABLE temp.t;" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-SqliteRuntime {
    New-Item -ItemType Directory -Force -Path $RepoSqliteBinDir | Out-Null
    New-Item -ItemType Directory -Force -Path $RepoSqliteArchiveDir | Out-Null

    if (Test-SqliteFts5 -Path $RepoSqliteBin) {
        Write-Host "[install-windows] using existing sqlite3.exe with FTS5: $RepoSqliteBin"
        return
    }

    $extractDir = Join-Path $RepoSqliteArchiveDir ([System.IO.Path]::GetFileNameWithoutExtension($RepoSqliteAssetName))
    if (Test-Path $extractDir) {
        Remove-Item $extractDir -Recurse -Force
    }

    $overrideUrl = $env:LOCAL_FIGMA_PORT_SQLITE_ZIP_URL
    $candidateUrls = if ([string]::IsNullOrWhiteSpace($overrideUrl)) {
        @($RepoSqliteReleaseAssetUrl, $RepoSqliteUpstreamUrl)
    } else {
        @($overrideUrl)
    }

    Invoke-DownloadFile -Urls $candidateUrls -Destination $RepoSqliteArchive -Label "SQLite $RepoSqliteVersion Windows x64 tools archive"
    Expand-Archive -LiteralPath $RepoSqliteArchive -DestinationPath $extractDir -Force

    $downloadedSqlite = Join-Path $extractDir "sqlite3.exe"
    if (-not (Test-Path $downloadedSqlite -PathType Leaf)) {
        throw "Downloaded SQLite archive did not contain sqlite3.exe: $RepoSqliteArchive"
    }

    Copy-Item -LiteralPath $downloadedSqlite -Destination $RepoSqliteBin -Force

    if (-not (Test-SqliteFts5 -Path $RepoSqliteBin)) {
        throw "Downloaded sqlite3.exe does not support FTS5: $RepoSqliteBin"
    }

    Write-Host "[install-windows] prepared sqlite3.exe with FTS5: $RepoSqliteBin"
}

function Test-SkillFrontmatter {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Missing skill file: $Path"
    }

    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
    if ($firstLine -ne "---") {
        throw "Skill file is missing opening YAML frontmatter delimiter: $Path"
    }
}

function Test-JsonFileIfPresent {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        return
    }

    $raw = Get-Content -Raw $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return
    }

    try {
        $null = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw "Invalid JSON in ${Label}: ${Path}`n$($_.Exception.Message)"
    }
}

function Test-McpRuntimeDependenciesInstalled {
    $ajvDir = Join-Path $RepoMcpDir "node_modules/ajv"
    $pngjsDir = Join-Path $RepoMcpDir "node_modules/pngjs"
    return (Test-Path $ajvDir) -and (Test-Path $pngjsDir)
}

function Ensure-PrebuiltBundleSupportFiles {
    if (-not (Test-Path $RepoMcpEntry -PathType Leaf)) {
        throw "Missing prebuilt MCP stdio entry: $RepoMcpEntry"
    }
    if (-not (Test-Path $RepoMcpHttpEntry -PathType Leaf)) {
        throw "Missing prebuilt MCP HTTP entry: $RepoMcpHttpEntry"
    }
    if (-not (Test-Path $RepoMcpPackageJson -PathType Leaf)) {
        throw "Missing prebuilt MCP package metadata: $RepoMcpPackageJson"
    }
    if (-not (Test-Path $RepoImporterExe -PathType Leaf)) {
        throw "Missing prebuilt importer executable: $RepoImporterExe"
    }
    if (-not (Test-Path $RepoPluginEntry -PathType Leaf)) {
        throw "Missing prebuilt Figma plugin bundle: $RepoPluginEntry"
    }
    if (-not (Test-Path $RepoPluginManifest -PathType Leaf)) {
        throw "Missing prebuilt Figma plugin manifest: $RepoPluginManifest"
    }
    $httpEntryText = Get-Content -Raw $RepoMcpHttpEntry
    if (-not $httpEntryText.Contains("IMPORTER_EXE")) {
        throw "The prebuilt MCP HTTP entry at $RepoMcpHttpEntry does not support prebuilt importer execution yet. Rebuild the Windows release bundle from the updated repository before publishing it."
    }
}

function Write-WithBackup {
    param(
        [string]$Path,
        [string]$Content
    )

    if ((Test-Path $Path) -and ((Get-Content -Raw $Path) -eq $Content)) {
        Write-Host "[install-windows] unchanged: $Path"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    if (Test-Path $Path) {
        $backupPath = "$Path.local-figma-port.$Timestamp.bak"
        Copy-Item $Path $backupPath -Force
        Write-Host "[install-windows] backup: $backupPath"
    }
    Set-Content -Path $Path -Value $Content -NoNewline:$false
    Write-Host "[install-windows] wrote: $Path"
}

function Set-MarkdownManagedBlock {
    param(
        [string]$Path,
        [string]$StartMarker,
        [string]$EndMarker,
        [string]$Block
    )

    $baseText = ""
    if (Test-Path $Path) {
        $baseText = Remove-ManagedBlockText -Text (Get-Content -Raw $Path) -StartMarker $StartMarker -EndMarker $EndMarker
    }

    $newText = if ([string]::IsNullOrWhiteSpace($baseText)) {
        "$StartMarker`n$Block`n$EndMarker`n"
    } else {
        "$baseText`n`n$StartMarker`n$Block`n$EndMarker`n"
    }

    Write-WithBackup -Path $Path -Content $newText
}

function Set-CodexTomlBlock {
    param(
        [string]$Path,
        [string]$Block
    )

    if ((Test-Path $Path) -and (Select-String -Path $Path -SimpleMatch "[mcp_servers.local-figma-port]" -Quiet) -and -not (Select-String -Path $Path -SimpleMatch $CodexTomlMarkerStart -Quiet)) {
        throw "Found an unmanaged [mcp_servers.local-figma-port] block in $Path. Refusing to overwrite it automatically."
    }

    $baseText = ""
    if (Test-Path $Path) {
        $baseText = Remove-ManagedBlockText -Text (Get-Content -Raw $Path) -StartMarker $CodexTomlMarkerStart -EndMarker $CodexTomlMarkerEnd
        $lines = $baseText -split "`r?`n"
        $filtered = New-Object System.Collections.Generic.List[string]
        $skipLegacy = $false
        foreach ($line in $lines) {
            if ($skipLegacy -and $line -match '^\[') {
                $skipLegacy = $false
            }
            if ($line -eq "[mcp_servers.design_local]") {
                $skipLegacy = $true
                continue
            }
            if (-not $skipLegacy) {
                $filtered.Add($line)
            }
        }
        $baseText = ($filtered -join "`n").TrimEnd()
    }

    $newText = if ([string]::IsNullOrWhiteSpace($baseText)) {
        "$CodexTomlMarkerStart`n$Block`n$CodexTomlMarkerEnd`n"
    } else {
        "$baseText`n`n$CodexTomlMarkerStart`n$Block`n$CodexTomlMarkerEnd`n"
    }

    Write-WithBackup -Path $Path -Content $newText
}

function Set-JsonMcpFile {
    param([string]$Path)

    $server = @{
        command = "node"
        args = @((To-PosixPath $RepoMcpEntry))
        env = @{
            SQLITE3_BIN = (To-PosixPath $RepoSqliteBin)
            SQLITE_PATH = (To-PosixPath $RepoSqlite)
            DATA_DIR = (To-PosixPath $RepoData)
        }
    }

    $payload = @{}
    if (Test-Path $Path) {
        $raw = Get-Content -Raw $Path
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $payload = $raw | ConvertFrom-Json -AsHashtable
        }
    }

    if (-not $payload.ContainsKey("mcpServers") -or $payload.mcpServers -isnot [System.Collections.IDictionary]) {
        $payload.mcpServers = @{}
    }

    $payload.mcpServers.Remove("design_local") | Out-Null
    $payload.mcpServers["local-figma-port"] = $server
    $json = ($payload | ConvertTo-Json -Depth 8)
    Write-WithBackup -Path $Path -Content ($json + "`n")
}

function Ensure-McpRuntime {
    Require-Command -Name "node"
    Require-Command -Name "npm"

    if ($UsePrebuilt) {
        Ensure-PrebuiltBundleSupportFiles
        Write-Host "[install-windows] preparing MCP runtime dependencies in $RepoMcpDir"
        Push-Location $RepoMcpDir
        try {
            if (Test-McpRuntimeDependenciesInstalled) {
                Write-Host "[install-windows] reusing existing node_modules in $RepoMcpDir"
            } else {
                & npm install --omit=dev --no-package-lock
                if ($LASTEXITCODE -ne 0) {
                    throw "npm install failed in $RepoMcpDir"
                }
            }
        } finally {
            Pop-Location
        }

        return
    }

    Write-Host "[install-windows] bootstrapping MCP runtime in $RepoMcpDir"
    Push-Location $RepoMcpDir
    try {
        if (Test-Path (Join-Path $RepoMcpDir "node_modules")) {
            Write-Host "[install-windows] reusing existing node_modules in $RepoMcpDir"
        } else {
            & npm install --no-package-lock
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed in $RepoMcpDir"
            }
        }
        & npm run build | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed in $RepoMcpDir"
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $RepoMcpEntry)) {
        throw "MCP build did not produce $RepoMcpEntry"
    }
}

function Ensure-ImporterRuntime {
    if ($UsePrebuilt) {
        Ensure-PrebuiltBundleSupportFiles
        Write-Host "[install-windows] using prebuilt importer runtime at $RepoImporterExe"
        return
    }

    $importerManifest = Join-Path $ProjectRoot "packages/design-importer/Cargo.toml"

    Require-Command -Name "cargo"
    Require-Command -Name "rustc"
    Ensure-MsvcLinkerAvailable

    if (-not (Test-Path $importerManifest)) {
        throw "Missing importer manifest: $importerManifest"
    }

    Write-Host "[install-windows] bootstrapping importer runtime in $(Join-Path $ProjectRoot 'packages/design-importer')"
    & cargo build --manifest-path $importerManifest --release | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed for $importerManifest"
    }
}

function Ensure-FigmaPluginRuntime {
    Require-Command -Name "npm"

    if ($UsePrebuilt) {
        Ensure-PrebuiltBundleSupportFiles
        Write-Host "[install-windows] using prebuilt Figma plugin bundle at $RepoPluginEntry"
        return
    }

    if (-not (Test-Path $RepoPluginPackageJson -PathType Leaf)) {
        throw "Missing Figma plugin package: $RepoPluginPackageJson"
    }

    Write-Host "[install-windows] bootstrapping Figma plugin runtime in $RepoPluginDir"
    Push-Location $RepoPluginDir
    try {
        if (Test-Path (Join-Path $RepoPluginDir "node_modules")) {
            Write-Host "[install-windows] reusing existing node_modules in $RepoPluginDir"
        } else {
            & npm install --no-package-lock
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed in $RepoPluginDir"
            }
        }
        & npm run build | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed in $RepoPluginDir"
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $RepoPluginEntry -PathType Leaf)) {
        throw "Figma plugin build did not produce $RepoPluginEntry"
    }
}

function Show-FigmaPluginManifestInstructions {
    $border = "=" * 78
    Write-Host ""
    Write-Host $border -ForegroundColor Cyan
    Write-Host "  Figma Desktop plugin manifest" -ForegroundColor Cyan
    Write-Host $border -ForegroundColor Cyan
    Write-Host "  Import this file in Figma Desktop:" -ForegroundColor White
    Write-Host ""
    Write-Host "  $RepoPluginManifest" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Figma: Plugins -> Development -> Import plugin from manifest..." -ForegroundColor White
    Write-Host $border -ForegroundColor Cyan
    Write-Host ""
}

function Test-ProjectJsonConfigs {
    if ($ClaudeCode) {
        Test-JsonFileIfPresent -Path (Join-Path $ConfigRoot ".mcp.json") -Label "Claude project MCP config"
    }
    if ($Cursor) {
        Test-JsonFileIfPresent -Path (Join-Path $ConfigRoot ".cursor/mcp.json") -Label "Cursor project MCP config"
        Test-JsonFileIfPresent -Path (Join-Path $CursorHome "mcp.json") -Label "Cursor global MCP config"
    }
}

function Ensure-CodexAppInstalled {
    if (-not $CodexApp) {
        return
    }

    $resolved = Resolve-LfpCodexAppInstallation -CodexAppData $CodexAppData -CodexAppExe $CodexAppExe
    if (-not [string]::IsNullOrWhiteSpace($resolved.DataDir)) {
        $script:CodexAppData = $resolved.DataDir
    }
    if (-not [string]::IsNullOrWhiteSpace($resolved.ExePath)) {
        $script:CodexAppExe = $resolved.ExePath
    }

    if (-not $resolved.IsInstalled) {
        $candidateLines = @()
        foreach ($candidate in $resolved.CandidateDataDirs) {
            $candidateLines += "data: $candidate"
        }
        foreach ($candidate in $resolved.CandidateExePaths) {
            $candidateLines += "exe:  $candidate"
        }
        throw "Codex App target selected, but no app data dir or executable was found.`nChecked:`n$($candidateLines -join "`n")"
    }
}

function Seed-StateDataIfNeeded {
    New-Item -ItemType Directory -Force -Path $RepoData | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $StateDir "run") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $StateDir "logs") | Out-Null

    if ($ProjectData -eq $RepoData -or -not (Test-Path $ProjectData)) {
        return
    }

    $sourceSample = Get-ChildItem -Force $ProjectData -ErrorAction SilentlyContinue | Select-Object -First 1
    $targetSample = Get-ChildItem -Force $RepoData -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $sourceSample -and $null -eq $targetSample) {
        Copy-Item -Path (Join-Path $ProjectData "*") -Destination $RepoData -Recurse -Force
        Write-Host "[install-windows] seeded stable state data from $ProjectData"
    }
}

function Copy-SkillFile {
    param([string]$TargetDir)

    $target = Join-Path $TargetDir "SKILL.md"
    $interfaceTarget = Join-Path $TargetDir "agents/openai.yaml"
    $content = Get-Content -Raw $RepoSkill
    Write-WithBackup -Path $target -Content $content

    $interfaceContent = @"
interface:
  display_name: Local Figma Port
  short_description: Exact UI replication from the Local Figma Port MCP server
  default_prompt: Use the Local Figma Port MCP server as the source of truth and implement the target UI with exact traced fidelity.
"@
    Write-WithBackup -Path $interfaceTarget -Content $interfaceContent
}

function Render-AgentsBlock {
    return @'
## Local Figma Port

### Available skills
- Local Figma Port: Use when implementing UI from this repository's `local-figma-port` MCP server where nested descendants, partial node reads, or ambiguous style ownership could cause the agent to stop early and guess instead of fully tracing the design source. (file: {0})

### How to use skills
- If the user names this skill with `$Local Figma Port` or plain text `Local Figma Port`, you must use it for that turn.
- Read the skill file above and follow it directly.
- Treat `Local Figma Port` as the canonical human-facing alias for this repository skill.
'@ -f (To-PosixPath $RepoSkill)
}

function Render-ClaudeBlock {
    return @'
## Local Figma Port

When the user mentions `$Local Figma Port` or `Local Figma Port`, use the skill at `{0}`.

Use this skill for:
- exact implementation from this repository's `local-figma-port` MCP server;
- setup or troubleshooting of the Local Figma Port workflow itself.
'@ -f (To-PosixPath $RepoSkill)
}

function Render-CodexTomlBlock {
    return @"
[mcp_servers.local-figma-port]
command = "node"
args = ["$(To-PosixPath $RepoMcpEntry)"]
env = { SQLITE3_BIN = "$(To-PosixPath $RepoSqliteBin)", SQLITE_PATH = "$(To-PosixPath $RepoSqlite)", DATA_DIR = "$(To-PosixPath $RepoData)" }
"@
}

function Show-InteractiveSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select targets to configure:"
        Write-Host "  [1] Codex"
        Write-Host "  [2] Codex App"
        Write-Host "  [3] Claude Code"
        Write-Host "  [4] Cursor"
        Write-Host ""
        Write-Host "Enter numbers separated by commas, or use 'all'. Example: 1,2,4"
        $choice = Read-Host "> "
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = "all"
        }
        try {
            Apply-TargetsCsv -Csv $choice
        } catch {
            Write-Warning $_.Exception.Message
            continue
        }
        if (-not ($Codex -or $CodexApp -or $ClaudeCode -or $Cursor)) {
            Write-Warning "Select at least one target."
            continue
        }
        return
    }
}

if ($All) {
    $Codex = $true
    $CodexApp = $true
    $ClaudeCode = $true
    $Cursor = $true
}

if (-not [string]::IsNullOrWhiteSpace($Targets)) {
    Apply-TargetsCsv -Csv $Targets
}

$explicitSelection = $Codex -or $CodexApp -or $ClaudeCode -or $Cursor
if (-not $explicitSelection) {
    Show-InteractiveSelection
}

if (-not (Test-Path $RepoSkill)) {
    throw "Missing repo skill: $RepoSkill"
}
Test-SkillFrontmatter -Path $RepoSkill

if ($UsePrebuilt) {
    Ensure-PrebuiltBundleSupportFiles
}

if (-not (Test-Path $RepoMcpPackageJson)) {
    throw "Missing MCP package: $RepoMcpPackageJson"
}

Write-Host ""
Write-Host "[install-windows] summary"
if ($Codex) { Write-Host "  - Codex" }
if ($CodexApp) { Write-Host "  - Codex App" }
if ($ClaudeCode) { Write-Host "  - Claude Code" }
if ($Cursor) { Write-Host "  - Cursor" }
Write-Host "  - project root: $ProjectRoot"
if ($ConfigRoot -ne $ProjectRoot) {
    Write-Host "  - config root: $ConfigRoot"
}
Write-Host "  - state root: $StateDir"
Write-Host "  - sqlite version: $RepoSqliteVersion"
Write-Host "  - sqlite target: $RepoSqliteBin"
if ($CodexApp) { Write-Host "  - codex app data: $CodexAppData" }

Test-ProjectJsonConfigs
Ensure-CodexAppInstalled
Ensure-SqliteRuntime
Ensure-McpRuntime
Ensure-ImporterRuntime
Ensure-FigmaPluginRuntime
Seed-StateDataIfNeeded

if ($Codex -or $CodexApp) {
    Copy-SkillFile -TargetDir (Join-Path $CodexHome "skills/local-figma-port")
    Set-CodexTomlBlock -Path (Join-Path $CodexHome "config.toml") -Block (Render-CodexTomlBlock)
}

if ($ClaudeCode) {
    Copy-SkillFile -TargetDir (Join-Path $ClaudeHome "skills/local-figma-port")
    Set-JsonMcpFile -Path (Join-Path $ConfigRoot ".mcp.json")
    Set-MarkdownManagedBlock -Path (Join-Path $ConfigRoot "CLAUDE.md") -StartMarker $ClaudeMarkerStart -EndMarker $ClaudeMarkerEnd -Block (Render-ClaudeBlock)
}

if ($Codex -or $CodexApp -or $Cursor) {
    Set-MarkdownManagedBlock -Path (Join-Path $ConfigRoot "AGENTS.md") -StartMarker $AgentsMarkerStart -EndMarker $AgentsMarkerEnd -Block (Render-AgentsBlock)
}

if ($Cursor) {
    Set-JsonMcpFile -Path (Join-Path $ConfigRoot ".cursor/mcp.json")
    Set-JsonMcpFile -Path (Join-Path $CursorHome "mcp.json")
}

$verifyParams = @{
    ProjectRoot = $ProjectRoot
    ConfigRoot = $ConfigRoot
    StateDir = $StateDir
    CodexHome = $CodexHome
    ClaudeHome = $ClaudeHome
    CursorHome = $CursorHome
}
if ($Codex) { $verifyParams.Codex = $true }
if ($CodexApp) {
    $verifyParams.CodexApp = $true
    $verifyParams.CodexAppData = $CodexAppData
    $verifyParams.CodexAppExe = $CodexAppExe
}
if ($ClaudeCode) { $verifyParams.ClaudeCode = $true }
if ($Cursor) { $verifyParams.Cursor = $true }

& (Join-Path $ProjectRoot "scripts/verify/windows.ps1") @verifyParams
& (Join-Path $ProjectRoot "scripts/runtime/start.ps1") -ProjectRoot $ProjectRoot -StateDir $StateDir -DataDir $RepoData -SqlitePath $RepoSqlite -ImporterExe $RepoImporterExe -McpPort $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
if ($CodexApp) {
    Write-Host "[install-windows] note: Codex App reads ~/.codex/config.toml; restart the app if it was already open."
}
Show-FigmaPluginManifestInstructions
Write-Host "[install-windows] install complete"
