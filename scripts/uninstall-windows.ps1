[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$Cursor,
    [switch]$All,
    [switch]$Purge,
    [switch]$KeepData,
    [string]$Targets,
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

$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$Timestamp = Get-Date -Format "yyyyMMddHHmmss"

$AgentsMarkerStart = "<!-- FIGMA PORT MANAGED BLOCK START -->"
$AgentsMarkerEnd = "<!-- FIGMA PORT MANAGED BLOCK END -->"
$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$ClaudeMarkerEnd = "<!-- FIGMA PORT CLAUDE BLOCK END -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"
$CodexTomlMarkerEnd = "# <<< FIGMA PORT MCP END <<<"

function Show-Usage {
    @"
usage: .\scripts\uninstall-windows.ps1 [-Codex] [-CodexApp] [-ClaudeCode] [-Cursor] [-All] [-Targets LIST] [-Purge] [-KeepData]

options:
  -Codex                 uninstall from Codex
  -CodexApp              uninstall from Codex App
  -ClaudeCode            uninstall from Claude Code
  -Cursor                uninstall from Cursor
  -All                   uninstall from all supported targets
  -Targets LIST          uninstall from comma-separated target numbers: 1=Codex, 2=Codex App, 3=Claude Code, 4=Cursor
  -Purge                 remove stable Local Figma Port state data
  -KeepData              keep stable Local Figma Port state data
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

function Write-OrRemoveFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $hasContent = -not [string]::IsNullOrWhiteSpace($Content)
    if ($hasContent -and (Test-Path $Path) -and ((Get-Content -Raw $Path) -eq $Content)) {
        Write-Host "[uninstall-windows] unchanged: $Path"
        return
    }

    if (Test-Path $Path) {
        $backupPath = "$Path.local-figma-port.$Timestamp.bak"
        Copy-Item $Path $backupPath -Force
        Write-Host "[uninstall-windows] backup: $backupPath"
    }

    if ($hasContent) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Set-Content -Path $Path -Value $Content -NoNewline:$false
        Write-Host "[uninstall-windows] wrote: $Path"
    } elseif (Test-Path $Path) {
        Remove-Item $Path -Force
        Write-Host "[uninstall-windows] removed: $Path"
    } else {
        Write-Host "[uninstall-windows] unchanged: $Path"
    }
}

function Remove-BackupFiles {
    param([string]$Path)

    $pattern = "$Path.local-figma-port.*.bak"
    foreach ($backup in Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue) {
        Remove-Item $backup.FullName -Force
        Write-Host "[uninstall-windows] removed backup: $($backup.FullName)"
    }
}

function Remove-PathSafe {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "[uninstall-windows] unchanged: $Path"
        return
    }

    Remove-Item $Path -Recurse -Force
    Write-Host "[uninstall-windows] removed: $Path"
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
    Write-OrRemoveFile -Path $Path -Content $(if ([string]::IsNullOrWhiteSpace($baseText)) { "" } else { $baseText + "`n" })
    Remove-BackupFiles -Path $Path
}

function Remove-CodexTomlBlock {
    param([string]$Path)

    $content = ""
    if (Test-Path $Path) {
        $lines = Get-Content $Path
        $filtered = New-Object System.Collections.Generic.List[string]
        $skipLegacy = $false
        $skipManaged = $false
        foreach ($line in $lines) {
            if ($skipLegacy -and $line -match '^\[') {
                $skipLegacy = $false
            }
            if ($line -eq "[mcp_servers.local-figma-port]" -or $line -eq "[mcp_servers.design_local]") {
                $skipLegacy = $true
                continue
            }
            if ($line -eq $CodexTomlMarkerStart) {
                $skipManaged = $true
                continue
            }
            if ($line -eq $CodexTomlMarkerEnd) {
                $skipManaged = $false
                continue
            }
            if (-not $skipLegacy -and -not $skipManaged) {
                $filtered.Add($line)
            }
        }
        $content = ($filtered -join "`n").TrimEnd()
    }
    Write-OrRemoveFile -Path $Path -Content $(if ([string]::IsNullOrWhiteSpace($content)) { "" } else { $content + "`n" })
    Remove-BackupFiles -Path $Path
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
        Write-OrRemoveFile -Path $Path -Content ""
    } else {
        Write-OrRemoveFile -Path $Path -Content (($payload | ConvertTo-Json -Depth 8) + "`n")
    }
    Remove-BackupFiles -Path $Path
}

function Test-JsonHasServer {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }
    return (Get-Content -Raw $Path).Contains('"local-figma-port"')
}

function Test-ProjectJsonConfigs {
    if ($ClaudeCode) {
        Test-JsonFileIfPresent -Path (Join-Path $ProjectRoot ".mcp.json") -Label "Claude project MCP config"
    }
    if ($Cursor) {
        Test-JsonFileIfPresent -Path (Join-Path $ProjectRoot ".cursor/mcp.json") -Label "Cursor project MCP config"
    }
}

function Show-InteractiveSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select targets to uninstall:"
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

function Resolve-DataMode {
    if ($Purge -or $KeepData) {
        return
    }
    if ([Console]::IsInputRedirected) {
        $script:KeepData = $true
        return
    }
    $choice = Read-Host "[uninstall-windows] remove Local Figma Port data at $StateDir? [y/N]"
    if ($choice -in @("y", "Y", "yes", "YES")) {
        $script:Purge = $true
    } else {
        $script:KeepData = $true
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

Test-ProjectJsonConfigs
Resolve-DataMode

$keepAgents = $false
if (-not $Codex -and (Test-Path (Join-Path $CodexHome "config.toml")) -and (Get-Content -Raw (Join-Path $CodexHome "config.toml")).Contains("[mcp_servers.local-figma-port]")) {
    $keepAgents = $true
}
if (-not $CodexApp -and ((Test-Path $CodexAppData) -or (Test-Path $CodexAppExe))) {
    $keepAgents = $true
}
if (-not $Cursor -and (Test-JsonHasServer (Join-Path $ProjectRoot ".cursor/mcp.json"))) {
    $keepAgents = $true
}

Write-Host ""
Write-Host "[uninstall-windows] summary"
if ($Codex) { Write-Host "  - Codex" }
if ($CodexApp) { Write-Host "  - Codex App" }
if ($ClaudeCode) { Write-Host "  - Claude Code" }
if ($Cursor) { Write-Host "  - Cursor" }
Write-Host "  - project root: $ProjectRoot"
Write-Host "  - state root: $StateDir"
if ($CodexApp) { Write-Host "  - codex app data: $CodexAppData" }
Write-Host ("  - data: {0}" -f $(if ($Purge) { "purge" } else { "keep" }))

& (Join-Path $ProjectRoot "scripts/stop_mcp.ps1") -StateDir $StateDir -McpPort $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })

$removeSharedCodex = $Codex -and $CodexApp
if ($removeSharedCodex) {
    Remove-CodexTomlBlock -Path (Join-Path $CodexHome "config.toml")
    Remove-PathSafe -Path (Join-Path $CodexHome "skills/local-figma-port")
} elseif ($Codex -or $CodexApp) {
    Write-Host "[uninstall-windows] keeping shared Codex runtime because Codex and Codex App use the same ~/.codex installation."
}

if ($ClaudeCode) {
    Remove-JsonMcpServer -Path (Join-Path $ProjectRoot ".mcp.json")
    Remove-MarkdownManagedBlock -Path (Join-Path $ProjectRoot "CLAUDE.md") -StartMarker $ClaudeMarkerStart -EndMarker $ClaudeMarkerEnd
    Remove-PathSafe -Path (Join-Path $ClaudeHome "skills/local-figma-port")
}

if ($Cursor) {
    Remove-JsonMcpServer -Path (Join-Path $ProjectRoot ".cursor/mcp.json")
}

if (-not $keepAgents -and ($Codex -or $CodexApp -or $Cursor)) {
    Remove-MarkdownManagedBlock -Path (Join-Path $ProjectRoot "AGENTS.md") -StartMarker $AgentsMarkerStart -EndMarker $AgentsMarkerEnd
}

if ($Purge) {
    Remove-PathSafe -Path $StateDir
}

Write-Host "[uninstall-windows] uninstall complete"
