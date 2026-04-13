[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$ClaudeDesktop,
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
    [string]$ClaudeDesktopConfig = $(if ($env:CLAUDE_DESKTOP_CONFIG) { $env:CLAUDE_DESKTOP_CONFIG } elseif ($env:APPDATA) { Join-Path $env:APPDATA "Claude/claude_desktop_config.json" } else { Join-Path $env:USERPROFILE "AppData/Roaming/Claude/claude_desktop_config.json" }),
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
$RepoClaudeDesktopPayloadDir = Join-Path $RepoMcpDir "claude-desktop-extension-payload"
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
$ClaudeUserConfig = Join-Path (Split-Path -Parent $ClaudeHome) ".claude.json"
$ClaudeProjectMcpConfig = Join-Path $ConfigRoot ".mcp.json"
$ClaudeCliPath = ""
$ClaudeIntegrationMode = ""
$NodeRuntimePath = ""
$NodeRuntimeVersion = ""
$ClaudeDesktopBundleOpenStatus = "not-attempted"

$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$ClaudeMarkerEnd = "<!-- FIGMA PORT CLAUDE BLOCK END -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"
$CodexTomlMarkerEnd = "# <<< FIGMA PORT MCP END <<<"

function Show-Usage {
    @"
usage: .\scripts\install\windows.ps1 [-Codex] [-ClaudeCode] [-ClaudeDesktop] [-Cursor] [-All]

options:
  -Codex                 install for Codex
  -CodexApp              install for Codex App
  -ClaudeCode            install for Claude Code
  -ClaudeDesktop         install for Claude Desktop
  -Cursor                install for Cursor
  -All                   install for all supported targets
  -UsePrebuilt           install from a prebuilt runtime bundle without local Rust/TypeScript builds
  -Targets LIST          install for comma-separated target names or numbers: 1=Codex, 2=Codex App, 3=Claude Code, 4=Claude Desktop, 5=Cursor
  -ProjectRoot PATH      override repository root
  -ConfigRoot PATH       override workspace root for legacy project files that may need cleanup
  -StateDir PATH         override Local Figma Port state root
  -CodexHome PATH        override Codex home
  -CodexAppData PATH     override Codex App data dir
  -CodexAppExe PATH      override Codex App executable path
  -ClaudeHome PATH       override Claude home
  -ClaudeDesktopConfig PATH override legacy Claude Desktop config path for cleanup
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
        "4" { $script:ClaudeDesktop = $true; return }
        "claude-desktop" { $script:ClaudeDesktop = $true; return }
        "claude_desktop" { $script:ClaudeDesktop = $true; return }
        "claude-desktop-app" { $script:ClaudeDesktop = $true; return }
        "5" { $script:Cursor = $true; return }
        "cursor" { $script:Cursor = $true; return }
        default { throw "Unknown target token: $Token" }
    }
}

function Apply-TargetsCsv {
    param([string]$Csv)

    $script:Codex = $false
    $script:CodexApp = $false
    $script:ClaudeCode = $false
    $script:ClaudeDesktop = $false
    $script:Cursor = $false

    if ($Csv -match '^\s*all\s*$') {
        $script:Codex = $true
        $script:CodexApp = $true
        $script:ClaudeCode = $true
        $script:ClaudeDesktop = $true
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

function Get-NodeRuntimeInfo {
    $nodeCmd = Get-Command "node" -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        throw "Missing required command: node"
    }

    $script:NodeRuntimePath = $nodeCmd.Source
    $versionOutput = (& $nodeCmd.Source --version 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($versionOutput)) {
        $versionOutput = "unknown"
    }
    $script:NodeRuntimeVersion = $versionOutput
}

function Resolve-ClaudeCli {
    if (-not [string]::IsNullOrWhiteSpace($script:ClaudeCliPath) -and (Test-Path $script:ClaudeCliPath)) {
        return $script:ClaudeCliPath
    }

    $cmd = Get-Command "claude" -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:ClaudeCliPath = $cmd.Source
        return $script:ClaudeCliPath
    }

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
            $script:ClaudeCliPath = $candidate
            return $script:ClaudeCliPath
        }
    }

    throw "Claude Code CLI not found. Install Claude Code so the 'claude' command is available, then re-run the installer."
}

function Resolve-ClaudeCliIfPresent {
    try {
        return (Resolve-ClaudeCli)
    } catch {
        return $null
    }
}

function Resolve-ClaudeIntegrationMode {
    if (-not [string]::IsNullOrWhiteSpace($script:ClaudeIntegrationMode)) {
        return $script:ClaudeIntegrationMode
    }

    $cli = Resolve-ClaudeCliIfPresent
    if ($cli) {
        $script:ClaudeIntegrationMode = "code"
    } else {
        $script:ClaudeIntegrationMode = "desktop"
    }
    return $script:ClaudeIntegrationMode
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

function Remove-MarkdownManagedBlock {
    param(
        [string]$Path,
        [string]$StartMarker,
        [string]$EndMarker
    )

    $baseText = ""
    if (Test-Path $Path) {
        $baseText = Remove-ManagedBlockText -Text (Get-Content -Raw $Path) -StartMarker $StartMarker -EndMarker $EndMarker
    }

    if ([string]::IsNullOrWhiteSpace($baseText)) {
        if (Test-Path $Path) {
            Remove-Item -LiteralPath $Path -Force
            Write-Host "[install-windows] removed: $Path"
        }
        return
    }

    Write-WithBackup -Path $Path -Content ($baseText.TrimEnd() + "`n")
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
    param(
        [string]$Path,
        [string]$Command = "node"
    )

    $server = @{
        command = $Command
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

function Remove-JsonMcpServer {
    param([string]$Path)

    $payload = @{}
    if (Test-Path $Path) {
        $raw = Get-Content -Raw $Path
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $payload = $raw | ConvertFrom-Json -AsHashtable
        }
    }

    if (-not ($payload -is [System.Collections.IDictionary])) {
        $payload = @{}
    }
    if ($payload.ContainsKey("mcpServers") -and $payload.mcpServers -is [System.Collections.IDictionary]) {
        $payload.mcpServers.Remove("local-figma-port") | Out-Null
        $payload.mcpServers.Remove("design_local") | Out-Null
        if ($payload.mcpServers.Count -eq 0) {
            $payload.Remove("mcpServers") | Out-Null
        }
    }

    if ($payload.Count -eq 0) {
        if (Test-Path $Path) {
            Remove-Item -LiteralPath $Path -Force
            Write-Host "[install-windows] removed: $Path"
        }
        return
    }

    Write-WithBackup -Path $Path -Content (($payload | ConvertTo-Json -Depth 8) + "`n")
}

function Ensure-McpRuntime {
    Get-NodeRuntimeInfo
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

function Show-AgentMcpDiagnostic {
    param(
        [string]$AgentLabel,
        [string]$ConfigPath
    )

    Write-Host "[install-windows] MCP diagnostics for $AgentLabel"
    Write-Host "  - config: $ConfigPath"
    Write-Host "  - command: node"
}

function Show-ClaudeDesktopExtensionDiagnostic {
    $bundlePath = Get-LfpClaudeDesktopBundlePath -StateDir $StateDir
    $border = "=============================================================================="

    Write-Host ""
    Write-Host $border
    Write-Host "  Claude Desktop extension"
    Write-Host $border
    Write-Host "  Bundle:"
    Write-Host ""
    Write-Host "  $bundlePath"
    Write-Host ""
    if ($script:ClaudeDesktopBundleOpenStatus -eq "opened") {
        Write-Host "  The installer asked Windows to open this .mcpb file now."
        Write-Host "  If Claude Desktop was closed, Windows may launch it for you."
        Write-Host ""
        Write-Host "  If no install dialog appeared, install it manually:"
    } else {
        Write-Host "  Automatic opening did not succeed. Install it manually:"
    }
    Write-Host ""
    Write-Host "  Claude Desktop: Settings -> Extensions -> Install extension from file..."
    Write-Host "  Choose: $bundlePath"
    Write-Host "  Enable the extension, then start a new Claude Desktop chat."
    Write-Host $border
}

function Show-AgentRestartNotes {
    if ($CodexApp) {
        Write-Host "[install-windows] note: restart Codex App if it was already open so the MCP server appears in Settings."
    }
    if ($ClaudeCode) {
        Write-Host "[install-windows] note: restart Claude Code if it was already open."
    }
    if ($Cursor) {
        Write-Host "[install-windows] note: restart Cursor if it was already open."
    }
}

function Show-PostInstallDiagnostics {
    Write-Host ""
    if ($Codex) {
        Show-AgentMcpDiagnostic -AgentLabel "Codex" -ConfigPath (Join-Path $CodexHome "config.toml")
    }
    if ($CodexApp) {
        Show-AgentMcpDiagnostic -AgentLabel "Codex App" -ConfigPath (Join-Path $CodexHome "config.toml")
    }
    if ($ClaudeCode) {
        Show-AgentMcpDiagnostic -AgentLabel "Claude Code" -ConfigPath ("user scope via {0}" -f $ClaudeCliPath)
    }
    if ($ClaudeDesktop) {
        Show-ClaudeDesktopExtensionDiagnostic
    }
    if ($Cursor) {
        Show-AgentMcpDiagnostic -AgentLabel "Cursor" -ConfigPath (Join-Path $CursorHome "mcp.json")
    }
    Show-AgentRestartNotes
}

function Open-ClaudeDesktopExtensionBundle {
    $bundlePath = Get-LfpClaudeDesktopBundlePath -StateDir $StateDir
    if (-not (Test-Path $bundlePath -PathType Leaf)) {
        $script:ClaudeDesktopBundleOpenStatus = "manual"
        return
    }

    # Windows does not always register a .mcpb file association for Claude
    # Desktop. Launching the bundle directly can surface the generic "Open with"
    # chooser instead of the extension installer flow, so keep this step manual.
    $script:ClaudeDesktopBundleOpenStatus = "manual"
}

function Test-ProjectJsonConfigs {
    if ($Cursor) {
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

function Set-ClaudeUserSubagent {
    $agentTarget = Join-Path $ClaudeHome "agents/local-figma-port.md"
    $skillPath = To-PosixPath (Join-Path $ClaudeHome "skills/local-figma-port/SKILL.md")
    $agentContent = @'
---
name: local-figma-port
description: Use proactively when implementing UI from Local Figma Port MCP context or when troubleshooting this MCP workflow.
---

You are the Local Figma Port specialist for Claude Code.

When the user asks for Local Figma Port, Figma implementation fidelity, or MCP troubleshooting:
- Follow the skill at `{0}`.
- Prefer the `local-figma-port` MCP server over guessing from partial context.
- Use the exported design context end-to-end before concluding work.
'@ -f $skillPath

    Write-WithBackup -Path $agentTarget -Content $agentContent
}

function Set-ClaudeUserMcpServer {
    $claudeCli = Resolve-ClaudeCli
    & $claudeCli mcp remove local-figma-port --scope user | Out-Null
    & $claudeCli mcp add local-figma-port --scope user `
        --env ("SQLITE3_BIN={0}" -f (To-PosixPath $RepoSqliteBin)) `
        --env ("SQLITE_PATH={0}" -f (To-PosixPath $RepoSqlite)) `
        --env ("DATA_DIR={0}" -f (To-PosixPath $RepoData)) `
        -- node (To-PosixPath $RepoMcpEntry) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "claude mcp add failed for user-scoped local-figma-port"
    }
}

function Set-ClaudeDesktopExtensionBundle {
    $bundlePath = Get-LfpClaudeDesktopBundlePath -StateDir $StateDir
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("local-figma-port-claude-desktop-" + [guid]::NewGuid().ToString("N"))
    $extensionRoot = Join-Path $stagingRoot "extension"
    $mcpVersion = ((Get-Content -Raw $RepoMcpPackageJson | ConvertFrom-Json).version)

    try {
        New-Item -ItemType Directory -Force -Path $extensionRoot | Out-Null
        $payloadManifest = Join-Path $RepoClaudeDesktopPayloadDir "package.json"
        $payloadServer = Join-Path $RepoClaudeDesktopPayloadDir "server/mcp-stdio.js"
        $payloadSchema = Join-Path $RepoClaudeDesktopPayloadDir "schemas/mcp-tools.v1.schema.json"
        $payloadNodeModules = Join-Path $RepoClaudeDesktopPayloadDir "node_modules"
        $hasPrebuiltPayload = (Test-Path $payloadManifest -PathType Leaf) -and (Test-Path $payloadServer -PathType Leaf) -and (Test-Path $payloadSchema -PathType Leaf) -and (Test-Path $payloadNodeModules -PathType Container)

        if ($hasPrebuiltPayload) {
            Copy-Item -Path (Join-Path $RepoClaudeDesktopPayloadDir "*") -Destination $extensionRoot -Recurse -Force
            Write-Host "[install-windows] using prebuilt Claude Desktop extension payload at $RepoClaudeDesktopPayloadDir"
        } else {
            New-Item -ItemType Directory -Force -Path (Join-Path $extensionRoot "server") | Out-Null
            Copy-Item -Path (Join-Path $RepoMcpDir "dist/*") -Destination (Join-Path $extensionRoot "server") -Recurse -Force
            Copy-Item -Path (Join-Path $ProjectRoot "schemas") -Destination (Join-Path $extensionRoot "schemas") -Recurse -Force
            Copy-Item -Path $RepoMcpPackageJson -Destination (Join-Path $extensionRoot "package.json") -Force
            Push-Location $extensionRoot
            try {
                & npm install --omit=dev --no-package-lock | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "npm install failed while preparing Claude Desktop extension runtime dependencies"
                }
            } finally {
                Pop-Location
            }
            Write-Host "[install-windows] built Claude Desktop extension payload locally"
        }

        $manifest = [ordered]@{
            manifest_version = "0.3"
            name             = "local-figma-port"
            display_name     = "Local Figma Port"
            version          = $mcpVersion
            description      = "Read Local Figma Port design exports from Claude Desktop."
            long_description = "Local-first MCP access to the Local Figma Port design store. Start the Local Figma Port runtime, export from the Figma Desktop plugin, then use this extension inside Claude Desktop."
            author           = [ordered]@{
                name = "echo-ae"
            }
            documentation    = "https://github.com/echo-ae/local_figma_port#readme"
            support          = "https://github.com/echo-ae/local_figma_port/issues"
            repository       = [ordered]@{
                type = "git"
                url  = "https://github.com/echo-ae/local_figma_port.git"
            }
            tools_generated  = $true
            server           = [ordered]@{
                type        = "node"
                entry_point = "server/mcp-stdio.js"
                mcp_config  = [ordered]@{
                    command = "node"
                    args    = @('${__dirname}/server/mcp-stdio.js')
                    env     = [ordered]@{
                        SQLITE3_BIN = (To-PosixPath $RepoSqliteBin)
                        SQLITE_PATH = (To-PosixPath $RepoSqlite)
                        DATA_DIR    = (To-PosixPath $RepoData)
                    }
                }
            }
        }

        Set-Content -Path (Join-Path $extensionRoot "manifest.json") -Value (($manifest | ConvertTo-Json -Depth 10) + "`n") -NoNewline:$false

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bundlePath) | Out-Null
        if (Test-Path $bundlePath) {
            Remove-Item $bundlePath -Force
        }
        Compress-Archive -Path (Join-Path $extensionRoot "*") -DestinationPath $bundlePath -Force
        Write-Host "[install-windows] wrote: $bundlePath"
    } finally {
        if (Test-Path $stagingRoot) {
            Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
        Write-Host "  [4] Claude Desktop"
        Write-Host "  [5] Cursor"
        Write-Host ""
        Write-Host "Enter numbers separated by commas, or use 'all'. Example: 1,2,5"
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
        if (-not ($Codex -or $CodexApp -or $ClaudeCode -or $ClaudeDesktop -or $Cursor)) {
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
    $ClaudeDesktop = $true
    $Cursor = $true
}

if (-not [string]::IsNullOrWhiteSpace($Targets)) {
    Apply-TargetsCsv -Csv $Targets
}

$explicitSelection = $Codex -or $CodexApp -or $ClaudeCode -or $ClaudeDesktop -or $Cursor
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
if ($ClaudeDesktop) { Write-Host "  - Claude Desktop" }
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
    Resolve-ClaudeCli | Out-Null
    Copy-SkillFile -TargetDir (Join-Path $ClaudeHome "skills/local-figma-port")
    Set-ClaudeUserSubagent
    Set-ClaudeUserMcpServer
    Remove-JsonMcpServer -Path $ClaudeUserConfig
    Remove-JsonMcpServer -Path $ClaudeProjectMcpConfig
    Remove-MarkdownManagedBlock -Path (Join-Path $ConfigRoot "CLAUDE.md") -StartMarker $ClaudeMarkerStart -EndMarker $ClaudeMarkerEnd
}

if ($ClaudeDesktop) {
    Set-ClaudeDesktopExtensionBundle
    Remove-JsonMcpServer -Path $ClaudeDesktopConfig
}

if ($Cursor) {
    Set-JsonMcpFile -Path (Join-Path $CursorHome "mcp.json")
    Remove-JsonMcpServer -Path (Join-Path $ConfigRoot ".cursor/mcp.json")
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
if ($ClaudeDesktop) { $verifyParams.ClaudeDesktop = $true }
if ($Cursor) { $verifyParams.Cursor = $true }

& (Join-Path $ProjectRoot "scripts/verify/windows.ps1") @verifyParams
& (Join-Path $ProjectRoot "scripts/runtime/start.ps1") -ProjectRoot $ProjectRoot -StateDir $StateDir -DataDir $RepoData -SqlitePath $RepoSqlite -ImporterExe $RepoImporterExe -McpPort $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
if ($ClaudeDesktop) {
    Open-ClaudeDesktopExtensionBundle
}
Show-FigmaPluginManifestInstructions
Show-PostInstallDiagnostics
Write-Host "[install-windows] install complete"
