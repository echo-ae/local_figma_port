[CmdletBinding()]
param(
    [switch]$Codex,
    [switch]$CodexApp,
    [switch]$ClaudeCode,
    [switch]$ClaudeDesktop,
    [switch]$Cursor,
    [switch]$All,
    [switch]$Purge,
    [switch]$KeepData,
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
$Timestamp = Get-Date -Format "yyyyMMddHHmmss"

$ClaudeMarkerStart = "<!-- FIGMA PORT CLAUDE BLOCK START -->"
$ClaudeMarkerEnd = "<!-- FIGMA PORT CLAUDE BLOCK END -->"
$CodexTomlMarkerStart = "# >>> FIGMA PORT MCP START >>>"
$CodexTomlMarkerEnd = "# <<< FIGMA PORT MCP END <<<"

function Show-Usage {
    @"
usage: .\scripts\uninstall\windows.ps1 [-Codex] [-CodexApp] [-ClaudeCode] [-ClaudeDesktop] [-Cursor] [-All] [-Targets LIST] [-Purge] [-KeepData]

options:
  -Codex                 uninstall from Codex
  -CodexApp              uninstall from Codex App
  -ClaudeCode            uninstall from Claude Code
  -ClaudeDesktop         uninstall from Claude Desktop
  -Cursor                uninstall from Cursor
  -All                   uninstall from all supported targets
  -Targets LIST          uninstall from comma-separated target names or numbers: 1=Codex, 2=Codex App, 3=Claude Code, 4=Claude Desktop, 5=Cursor
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

function Test-JsonHasServer {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $raw = Get-Content -Raw $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        return $false
    }

    return $parsed.ContainsKey("mcpServers") -and $parsed.mcpServers -is [System.Collections.IDictionary] -and $parsed.mcpServers.ContainsKey("local-figma-port")
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

function Test-ProjectJsonConfigs {
    if ($ClaudeCode) {
        Test-JsonFileIfPresent -Path (Join-Path $ConfigRoot ".mcp.json") -Label "legacy Claude project MCP config"
    }
    if ($Cursor) {
        Test-JsonFileIfPresent -Path (Join-Path $CursorHome "mcp.json") -Label "Cursor global MCP config"
    }
}

function Show-InteractiveSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select targets to uninstall:"
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

Test-ProjectJsonConfigs
Resolve-DataMode

Write-Host ""
Write-Host "[uninstall-windows] summary"
if ($Codex) { Write-Host "  - Codex" }
if ($CodexApp) { Write-Host "  - Codex App" }
if ($ClaudeCode) { Write-Host "  - Claude Code" }
if ($ClaudeDesktop) { Write-Host "  - Claude Desktop" }
if ($Cursor) { Write-Host "  - Cursor" }
Write-Host "  - project root: $ProjectRoot"
Write-Host "  - config root: $ConfigRoot"
Write-Host "  - state root: $StateDir"
if ($CodexApp) { Write-Host "  - codex app data: $CodexAppData" }
Write-Host ("  - data: {0}" -f $(if ($Purge) { "purge" } else { "keep" }))

& (Join-Path $ProjectRoot "scripts/runtime/stop.ps1") -StateDir $StateDir -McpPort $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })

$removeSharedCodex = $Codex -and $CodexApp
if ($removeSharedCodex) {
    Remove-CodexTomlBlock -Path (Join-Path $CodexHome "config.toml")
    Remove-PathSafe -Path (Join-Path $CodexHome "skills/local-figma-port")
} elseif ($Codex -or $CodexApp) {
    Write-Host "[uninstall-windows] keeping shared Codex runtime because Codex and Codex App use the same ~/.codex installation."
}

if ($ClaudeCode) {
    $claudeCmd = Get-Command "claude" -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
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
                $claudeCmd = [pscustomobject]@{ Source = $candidate }
                break
            }
        }
    }
    if ($claudeCmd) {
        & $claudeCmd.Source mcp remove local-figma-port --scope user | Out-Null
    }
    Remove-JsonMcpServer -Path (Join-Path (Split-Path -Parent $ClaudeHome) ".claude.json")
    Remove-JsonMcpServer -Path (Join-Path $ConfigRoot ".mcp.json")
    Remove-MarkdownManagedBlock -Path (Join-Path $ConfigRoot "CLAUDE.md") -StartMarker $ClaudeMarkerStart -EndMarker $ClaudeMarkerEnd
    Remove-PathSafe -Path (Join-Path $ClaudeHome "agents/local-figma-port.md")
    Remove-PathSafe -Path (Join-Path $ClaudeHome "skills/local-figma-port")
}

if ($ClaudeDesktop) {
    Remove-PathSafe -Path (Get-LfpClaudeDesktopBundlePath -StateDir $StateDir)
    Remove-JsonMcpServer -Path $ClaudeDesktopConfig
    Write-Host "[uninstall-windows] note: if you already installed the Local Figma Port extension in Claude Desktop, remove it from Claude Desktop Settings -> Extensions."
}

if ($Cursor) {
    Remove-JsonMcpServer -Path (Join-Path $CursorHome "mcp.json")
    Remove-JsonMcpServer -Path (Join-Path $ConfigRoot ".cursor/mcp.json")
}

if ($Purge) {
    Remove-PathSafe -Path $StateDir
}

Write-Host "[uninstall-windows] uninstall complete"
