[CmdletBinding()]
param(
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [int]$McpPort = $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
)

$ErrorActionPreference = "Stop"

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$PidFile = Join-Path $StateDir "run/mcp-server.pid"
$stopped = $false
$listeners = @()

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
                Write-Host "[stop] stopped MCP pid=$pidText"
                $stopped = $true
            }
        } catch {
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

$listeners = Get-NetTCPConnection -State Listen -LocalPort $McpPort -ErrorAction SilentlyContinue

if (-not $stopped) {
    Write-Host "[stop] no running managed MCP process found"
}

if ($listeners) {
    $pids = ($listeners | ForEach-Object { $_.OwningProcess } | Where-Object { $_ } | Sort-Object -Unique) -join ", "
    Write-Warning "[stop] port $McpPort is still in use by non-managed process(es): $pids"
}
