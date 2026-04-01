[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$DataDir = "",
    [string]$SqlitePath = "",
    [string]$Sqlite3Bin = "",
    [int]$McpPort = $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
)

. (Join-Path $PSScriptRoot "lib/ensure-pwsh7.ps1")
Restart-InPwsh7IfNeeded -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -ForwardArgs $MyInvocation.UnboundArguments

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $DataDir = Join-Path $StateDir "data"
}
if ([string]::IsNullOrWhiteSpace($SqlitePath)) {
    $SqlitePath = Join-Path $DataDir "design_store.sqlite"
}
if ([string]::IsNullOrWhiteSpace($Sqlite3Bin)) {
    $bundledSqlite = Join-Path $StateDir "bin/sqlite3.exe"
    if (Test-Path $bundledSqlite -PathType Leaf) {
        $Sqlite3Bin = $bundledSqlite
    } else {
        $Sqlite3Bin = "sqlite3"
    }
}

$McpDir = Join-Path $ProjectRoot "packages/mcp-server"
$PidFile = Join-Path $StateDir "run/mcp-server.pid"
$LogFile = Join-Path $StateDir "logs/mcp-server.log"
$NodeScript = Join-Path $McpDir "dist/index.js"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PidFile) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null

if (Test-Path $PidFile) {
    $oldPid = (Get-Content -Raw $PidFile).Trim()
    if ($oldPid) {
        try {
            $existing = Get-Process -Id ([int]$oldPid) -ErrorAction Stop
            if ($null -ne $existing) {
                Write-Host "[start] MCP already running pid=$oldPid"
                exit 0
            }
        } catch {
        }
    }
}

$portBusy = Get-NetTCPConnection -State Listen -LocalPort $McpPort -ErrorAction SilentlyContinue
if ($portBusy) {
    throw "[start] port $McpPort is busy; stop existing process first."
}

Push-Location $McpDir
try {
    & npm run build | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "npm run build failed in $McpDir"
    }
} finally {
    Pop-Location
}

$previousProjectRoot = $env:PROJECT_ROOT
$previousSqlite3Bin = $env:SQLITE3_BIN
$previousSqlitePath = $env:SQLITE_PATH
$previousDataDir = $env:DATA_DIR
$previousMcpPort = $env:MCP_PORT
try {
    $env:PROJECT_ROOT = $ProjectRoot
    $env:SQLITE3_BIN = $Sqlite3Bin
    $env:SQLITE_PATH = $SqlitePath
    $env:DATA_DIR = $DataDir
    $env:MCP_PORT = [string]$McpPort

    $cmd = "node `"$NodeScript`" >> `"$LogFile`" 2>&1"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WorkingDirectory $McpDir -WindowStyle Hidden -PassThru
} finally {
    $env:PROJECT_ROOT = $previousProjectRoot
    $env:SQLITE3_BIN = $previousSqlite3Bin
    $env:SQLITE_PATH = $previousSqlitePath
    $env:DATA_DIR = $previousDataDir
    $env:MCP_PORT = $previousMcpPort
}

Set-Content -Path $PidFile -Value $proc.Id
Start-Sleep -Seconds 1
try {
    $null = Get-Process -Id $proc.Id -ErrorAction Stop
} catch {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    $message = "[start] MCP failed to stay running on port $McpPort"
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 0)) {
        $tail = Get-Content -Path $LogFile -Tail 20 | Out-String
        throw "$message`n[start] recent log output:`n$tail"
    }
    throw $message
}
Write-Host "[start] MCP started pid=$($proc.Id) port=$McpPort"
Write-Host "[start] sqlite3: $Sqlite3Bin"
Write-Host "[start] log: $LogFile"
