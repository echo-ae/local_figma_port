[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$DataDir = "",
    [string]$SqlitePath = "",
    [string]$Sqlite3Bin = "",
    [string]$ImporterExe = "",
    [int]$McpPort = $(if ($env:MCP_PORT) { [int]$env:MCP_PORT } else { 7331 })
)

$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
. (Join-Path $LibDir "ensure-pwsh7.ps1")
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
$McpPackageJson = Join-Path $McpDir "package.json"
$DdlPath = Join-Path $ProjectRoot "sql/design_store.v1.sql"
$CompatDdlPath = Join-Path $ProjectRoot "sql/design_store.v1.compat.sql"

if ([string]::IsNullOrWhiteSpace($ImporterExe)) {
    $candidateImporterExe = Join-Path $ProjectRoot "packages/design-importer/target/release/design-importer.exe"
    if (Test-Path $candidateImporterExe -PathType Leaf) {
        $ImporterExe = $candidateImporterExe
    }
}

function Invoke-SqliteStatement {
    param(
        [string]$DatabasePath,
        [string]$Statement
    )

    $output = & $Sqlite3Bin $DatabasePath $Statement 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ($output.Trim())
    }

    return $output.Trim()
}

function Ensure-DatabaseSchema {
    if (-not (Test-Path $DdlPath -PathType Leaf)) {
        throw "[start] missing DDL file: $DdlPath"
    }
    if (-not (Test-Path $CompatDdlPath -PathType Leaf)) {
        throw "[start] missing compatibility DDL file: $CompatDdlPath"
    }

    $hasFtsNodes = $false
    try {
        $result = Invoke-SqliteStatement -DatabasePath $SqlitePath -Statement "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_nodes' LIMIT 1;"
        $hasFtsNodes = $result -eq "1"
    } catch {
        $hasFtsNodes = $false
    }

    if ($hasFtsNodes) {
        return
    }

    $ddl = Get-Content -Raw $DdlPath
    try {
        Invoke-SqliteStatement -DatabasePath $SqlitePath -Statement $ddl | Out-Null
    } catch {
        $message = $_.Exception.Message
        if ($message -notmatch "expressions prohibited in PRIMARY KEY") {
            throw "[start] failed to initialize SQLite schema: $message"
        }

        $compatDdl = Get-Content -Raw $CompatDdlPath
        Invoke-SqliteStatement -DatabasePath $SqlitePath -Statement $compatDdl | Out-Null
    }

    $ftsNodesReady = Invoke-SqliteStatement -DatabasePath $SqlitePath -Statement "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_nodes' LIMIT 1;"
    if ($ftsNodesReady -ne "1") {
        throw "[start] SQLite schema initialization did not create fts_nodes in $SqlitePath"
    }

    Write-Host "[start] initialized SQLite schema at $SqlitePath"
}

function Ensure-McpEntryPoint {
    if (Test-Path $NodeScript -PathType Leaf) {
        if (-not (Test-Path $McpPackageJson -PathType Leaf)) {
            throw "[start] missing MCP package metadata: $McpPackageJson. Run scripts/install/windows.ps1 first."
        }
        return
    }

    if (-not (Test-Path $McpPackageJson -PathType Leaf)) {
        throw "[start] missing MCP package metadata and prebuilt entrypoint at $McpPackageJson / $NodeScript"
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

    if (-not (Test-Path $NodeScript -PathType Leaf)) {
        throw "[start] MCP build did not produce $NodeScript"
    }
}

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

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PidFile) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Ensure-DatabaseSchema
Ensure-McpEntryPoint

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

$portBusy = Get-ListeningProcessIds -Port $McpPort
if ($portBusy) {
    $busyPids = ($portBusy -join ", ")
    throw "[start] port $McpPort is busy; stop existing process first. Listening process(es): $busyPids"
}

$previousProjectRoot = $env:PROJECT_ROOT
$previousSqlite3Bin = $env:SQLITE3_BIN
$previousSqlitePath = $env:SQLITE_PATH
$previousDataDir = $env:DATA_DIR
$previousImporterExe = $env:IMPORTER_EXE
$previousMcpPort = $env:MCP_PORT
try {
    $env:PROJECT_ROOT = $ProjectRoot
    $env:SQLITE3_BIN = $Sqlite3Bin
    $env:SQLITE_PATH = $SqlitePath
    $env:DATA_DIR = $DataDir
    if ([string]::IsNullOrWhiteSpace($ImporterExe)) {
        Remove-Item Env:IMPORTER_EXE -ErrorAction SilentlyContinue
    } else {
        $env:IMPORTER_EXE = $ImporterExe
    }
    $env:MCP_PORT = [string]$McpPort

    $cmd = "node `"$NodeScript`" >> `"$LogFile`" 2>&1"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WorkingDirectory $McpDir -WindowStyle Hidden -PassThru
} finally {
    $env:PROJECT_ROOT = $previousProjectRoot
    $env:SQLITE3_BIN = $previousSqlite3Bin
    $env:SQLITE_PATH = $previousSqlitePath
    $env:DATA_DIR = $previousDataDir
    if ($null -eq $previousImporterExe) {
        Remove-Item Env:IMPORTER_EXE -ErrorAction SilentlyContinue
    } else {
        $env:IMPORTER_EXE = $previousImporterExe
    }
    $env:MCP_PORT = $previousMcpPort
}

Set-Content -Path $PidFile -Value $proc.Id

$managedPid = $null
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 500

    $listenerPids = Get-ListeningProcessIds -Port $McpPort
    if ($listenerPids.Count -gt 0) {
        if ($listenerPids -contains $proc.Id) {
            $managedPid = $proc.Id
        } else {
            $managedPid = $listenerPids[0]
        }
        break
    }

    try {
        $null = Get-Process -Id $proc.Id -ErrorAction Stop
    } catch {
        break
    }
}

if ($null -eq $managedPid) {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    $message = "[start] MCP failed to stay running on port $McpPort"
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 0)) {
        $tail = Get-Content -Path $LogFile -Tail 20 | Out-String
        throw "$message`n[start] recent log output:`n$tail"
    }
    throw $message
}

Set-Content -Path $PidFile -Value $managedPid
Write-Host "[start] MCP started pid=$managedPid port=$McpPort"
Write-Host "[start] sqlite3: $Sqlite3Bin"
if (-not [string]::IsNullOrWhiteSpace($ImporterExe)) {
    Write-Host "[start] importer: $ImporterExe"
}
Write-Host "[start] log: $LogFile"
