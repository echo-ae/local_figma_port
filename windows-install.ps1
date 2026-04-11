[CmdletBinding()]
param(
    [ValidateSet("", "codex", "codex-app", "claude-code", "cursor")]
    [string]$Target = "",
    [ValidateSet("", "amd64", "arm64")]
    [string]$Architecture = "",
    [string]$GitHubRepo = "echo-ae/local_figma_port",
    [string]$ReleaseTag = "",
    [string]$BundleUrl = "",
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$StateDir = $(if ($env:LOCAL_FIGMA_PORT_STATE_DIR) { $env:LOCAL_FIGMA_PORT_STATE_DIR } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "LocalFigmaPort" } else { Join-Path $env:USERPROFILE "AppData/Local/LocalFigmaPort" }),
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $StateDir "bundle/current"
}

function Refresh-LfpProcessPath {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($machine)) {
        $machine = ""
    }
    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = ""
    }
    $env:Path = ($machine.TrimEnd(";") + ";" + $user.TrimStart(";")).Trim(";")
}

function Invoke-LfpWingetInstall {
    param(
        [string]$PackageId,
        [string]$Label
    )

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "$Label is required, but winget.exe is not available. Install $Label manually and run this script again."
    }

    Write-Host "[windows-install] installing $Label via winget"
    & $winget.Source install --id $PackageId --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Label (package id: $PackageId)"
    }
    Refresh-LfpProcessPath
}

function Resolve-LfpPwshExecutable {
    $isPwsh7 = $PSVersionTable.PSEdition -eq "Core" -and $PSVersionTable.PSVersion.Major -ge 7
    if ($isPwsh7) {
        $pwsh = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
        if ($pwsh) {
            return $pwsh.Source
        }
    }

    $existing = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($existing) {
        return $existing.Source
    }

    Invoke-LfpWingetInstall -PackageId "Microsoft.PowerShell" -Label "PowerShell 7"
    $installed = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if (-not $installed) {
        throw "PowerShell 7 was installed, but pwsh.exe is still not on PATH. Open a new terminal and run this installer again."
    }

    return $installed.Source
}

function Ensure-LfpNodeRuntime {
    $node = Get-Command "node" -ErrorAction SilentlyContinue
    $npm = Get-Command "npm" -ErrorAction SilentlyContinue
    if ($node -and $npm) {
        return
    }

    Invoke-LfpWingetInstall -PackageId "OpenJS.NodeJS.LTS" -Label "Node.js LTS"
    $node = Get-Command "node" -ErrorAction SilentlyContinue
    $npm = Get-Command "npm" -ErrorAction SilentlyContinue
    if (-not $node -or -not $npm) {
        throw "Node.js LTS was installed, but node/npm are still not on PATH. Open a new terminal and run this installer again."
    }
}

function Get-LfpWindowsArchitecture {
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        return $Architecture
    }

    $raw = ""
    try {
        $raw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        $raw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }

    switch -Regex ($raw.ToUpperInvariant()) {
        "ARM64" { return "arm64" }
        "AMD64|X64" { return "amd64" }
        default { throw "Unsupported Windows architecture: $raw" }
    }
}

function Get-LfpTargetChoice {
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        return $Target
    }

    while ($true) {
        Write-Host ""
        Write-Host "Choose the coding agent to configure:"
        Write-Host "  [1] Codex"
        Write-Host "  [2] Codex App"
        Write-Host "  [3] Claude Code"
        Write-Host "  [4] Cursor"
        Write-Host ""
        $choice = Read-Host "> "
        switch ($choice.Trim().ToLowerInvariant()) {
            "1" { return "codex" }
            "codex" { return "codex" }
            "2" { return "codex-app" }
            "codex-app" { return "codex-app" }
            "codex_app" { return "codex-app" }
            "3" { return "claude-code" }
            "claude" { return "claude-code" }
            "claude-code" { return "claude-code" }
            "claude_code" { return "claude-code" }
            "4" { return "cursor" }
            "cursor" { return "cursor" }
            default { Write-Warning "Unknown choice: $choice" }
        }
    }
}

function Get-LfpTargetToken {
    param([string]$Name)

    switch ($Name) {
        "codex" { return "1" }
        "codex-app" { return "2" }
        "claude-code" { return "3" }
        "cursor" { return "4" }
        default { throw "Unknown target: $Name" }
    }
}

function Get-LfpBundleCandidateUrls {
    param(
        [string]$Arch,
        [string]$Repo,
        [string]$Tag
    )

    $assetNames = @(
        "local-figma-port-windows-$Arch.zip",
        "windows-$Arch.zip",
        "$Arch.zip"
    )
    $base = if ([string]::IsNullOrWhiteSpace($Tag)) {
        "https://github.com/$Repo/releases/latest/download"
    } else {
        "https://github.com/$Repo/releases/download/$Tag"
    }

    $urls = New-Object 'System.Collections.Generic.List[string]'
    foreach ($assetName in $assetNames) {
        $urls.Add("$base/$assetName")
    }
    return $urls.ToArray()
}

function Invoke-LfpDownloadFile {
    param(
        [string[]]$Urls,
        [string]$Destination,
        [string]$Label
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($url in $Urls) {
        try {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
            }
            Write-Host "[windows-install] downloading $Label from $url"
            Invoke-WebRequest -Uri $url -OutFile $Destination
            if (-not (Test-Path $Destination -PathType Leaf)) {
                throw "download completed but file is missing"
            }
            return
        } catch {
            $errors.Add("${url}: $($_.Exception.Message)")
        }
    }

    throw "Failed to download $Label.`n$($errors -join "`n")"
}

function Get-LfpExtractedBundleRoot {
    param([string]$ExtractDir)

    $direct = Join-Path $ExtractDir "scripts/install/windows.ps1"
    if (Test-Path $direct -PathType Leaf) {
        return $ExtractDir
    }

    $matches = @(Get-ChildItem -Path $ExtractDir -Directory -Force | Where-Object {
        Test-Path (Join-Path $_.FullName "scripts/install/windows.ps1") -PathType Leaf
    })
    if ($matches.Count -gt 0) {
        return $matches[0].FullName
    }

    throw "Could not find scripts/install/windows.ps1 inside the downloaded bundle."
}

function Stop-LfpExistingMcp {
    param([string]$StateRoot)

    $pidFile = Join-Path $StateRoot "run/mcp-server.pid"
    if (-not (Test-Path $pidFile -PathType Leaf)) {
        return
    }

    $pidText = (Get-Content -Raw $pidFile).Trim()
    if ($pidText -match '^\d+$') {
        try {
            Stop-Process -Id ([int]$pidText) -Force -ErrorAction Stop
            Write-Host "[windows-install] stopped previous MCP process pid=$pidText"
        } catch {
        }
    }

    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

function Copy-LfpBundleContents {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    if (Test-Path $DestinationRoot) {
        Remove-Item $DestinationRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

    Get-ChildItem -Path $SourceRoot -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $DestinationRoot -Recurse -Force
    }
}

$selectedTarget = Get-LfpTargetChoice
$targetToken = Get-LfpTargetToken -Name $selectedTarget
$resolvedArch = Get-LfpWindowsArchitecture
$pwshExe = Resolve-LfpPwshExecutable
Ensure-LfpNodeRuntime

$StateDir = [System.IO.Path]::GetFullPath($StateDir)
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)

Write-Host ""
Write-Host "[windows-install] summary"
Write-Host "  - target: $selectedTarget"
Write-Host "  - architecture: $resolvedArch"
Write-Host "  - state root: $StateDir"
Write-Host "  - install root: $InstallRoot"
if ($selectedTarget -eq "claude-code" -or $selectedTarget -eq "cursor") {
    Write-Host "  - workspace root: $WorkspaceRoot"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("local-figma-port-install-" + [guid]::NewGuid().ToString("N"))
$downloadZip = Join-Path $tempRoot "bundle.zip"
$extractDir = Join-Path $tempRoot "extract"
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

try {
    $candidateUrls = if ([string]::IsNullOrWhiteSpace($BundleUrl)) {
        Get-LfpBundleCandidateUrls -Arch $resolvedArch -Repo $GitHubRepo -Tag $ReleaseTag
    } else {
        @($BundleUrl)
    }

    Invoke-LfpDownloadFile -Urls $candidateUrls -Destination $downloadZip -Label "Local Figma Port $resolvedArch bundle"
    Expand-Archive -LiteralPath $downloadZip -DestinationPath $extractDir -Force
    $bundleRoot = Get-LfpExtractedBundleRoot -ExtractDir $extractDir

    Stop-LfpExistingMcp -StateRoot $StateDir
    Copy-LfpBundleContents -SourceRoot $bundleRoot -DestinationRoot $InstallRoot

    $installScript = Join-Path $InstallRoot "scripts/install/windows.ps1"
    $installArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $installScript,
        "-UsePrebuilt",
        "-Targets",
        $targetToken,
        "-ProjectRoot",
        $InstallRoot,
        "-StateDir",
        $StateDir
    )

    if ($selectedTarget -eq "claude-code" -or $selectedTarget -eq "cursor") {
        $installArgs += "-ConfigRoot"
        $installArgs += $WorkspaceRoot
    }

    $previousReleaseTag = $env:LOCAL_FIGMA_PORT_RELEASE_TAG
    try {
        if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
            Remove-Item Env:LOCAL_FIGMA_PORT_RELEASE_TAG -ErrorAction SilentlyContinue
        } else {
            $env:LOCAL_FIGMA_PORT_RELEASE_TAG = $ReleaseTag
        }

        & $pwshExe @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Bundled installer failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $previousReleaseTag) {
            Remove-Item Env:LOCAL_FIGMA_PORT_RELEASE_TAG -ErrorAction SilentlyContinue
        } else {
            $env:LOCAL_FIGMA_PORT_RELEASE_TAG = $previousReleaseTag
        }
    }
} finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[windows-install] plugin bundle: $(Join-Path $InstallRoot 'packages/figma-exporter-plugin')"
$bundledInstallScript = Join-Path $InstallRoot "scripts/install/windows.ps1"
$bundledInstallerShowsManifest = (Test-Path $bundledInstallScript -PathType Leaf) -and
    (Get-Content -Raw $bundledInstallScript).Contains("Show-FigmaPluginManifestInstructions")
if (-not $bundledInstallerShowsManifest) {
    $manifestPath = Join-Path $InstallRoot "packages/figma-exporter-plugin/manifest.json"
    $border = "=" * 78
    Write-Host ""
    Write-Host $border -ForegroundColor Cyan
    Write-Host "  Figma Desktop plugin manifest" -ForegroundColor Cyan
    Write-Host $border -ForegroundColor Cyan
    Write-Host "  Import this file in Figma Desktop:" -ForegroundColor White
    Write-Host ""
    Write-Host "  $manifestPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Figma: Plugins -> Development -> Import plugin from manifest..." -ForegroundColor White
    Write-Host $border -ForegroundColor Cyan
    Write-Host ""
}
Write-Host "[windows-install] install complete"
