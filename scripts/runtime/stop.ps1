[CmdletBinding()]
param(
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [int]$McpPort = $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
. (Join-Path $LibDir "ensure-pwsh7.ps1")
Restart-InPwsh7IfNeeded -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -ForwardArgs $MyInvocation.UnboundArguments

$ErrorActionPreference = "Stop"

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$PidFile = Join-Path $StateDir "run/mcp-server.pid"
$stopped = $false

function Get-ListeningProcessIds {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $listeners) {
        return @()
    }

    return @(
        $listeners |
            ForEach-Object { $_.OwningProcess } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

if (Test-Path $PidFile) {
    $pidText = (Get-Content -Raw $PidFile).Trim()
    if ($pidText) {
        try {
            $proc = Get-Process -Id ([int]$pidText) -ErrorAction Stop
            if ($null -ne $proc) {
                Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                try {
                    $null = Get-Process -Id $proc.Id -ErrorAction Stop
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                } catch {
                }
                try {
                    $null = Get-Process -Id $proc.Id -ErrorAction Stop
                } catch {
                    Write-Host "[stop] stopped MCP pid=$pidText"
                    $stopped = $true
                }
            }
        } catch {
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

$listenerPids = Get-ListeningProcessIds -Port $McpPort

foreach ($listenerPid in $listenerPids) {
    try {
        Stop-Process -Id $listenerPid -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        try {
            $null = Get-Process -Id $listenerPid -ErrorAction Stop
            Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "[stop] stopped MCP listener pid=$listenerPid"
            $stopped = $true
        }
    } catch {
    }
}

$remainingPids = Get-ListeningProcessIds -Port $McpPort

if (-not $stopped) {
    Write-Host "[stop] no running managed MCP process found"
}

if ($remainingPids.Count -gt 0) {
    $pids = ($remainingPids -join ", ")
    Write-Warning "[stop] port $McpPort is still in use by non-managed process(es): $pids"
}
