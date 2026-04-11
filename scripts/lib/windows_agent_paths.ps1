function Add-LfpUniquePathCandidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $normalized = $Value
    try {
        $normalized = [System.IO.Path]::GetFullPath($Value)
    } catch {
    }

    if (-not $List.Contains($normalized)) {
        $List.Add($normalized)
    }
}

function Get-LfpDefaultCodexAppDataDir {
    if ($env:APPDATA) {
        return (Join-Path $env:APPDATA "Codex")
    }

    return (Join-Path $env:USERPROFILE "AppData/Roaming/Codex")
}

function Resolve-LfpCodexAppInstallation {
    param(
        [string]$CodexAppData = "",
        [string]$CodexAppExe = ""
    )

    $dataCandidates = New-Object 'System.Collections.Generic.List[string]'
    $exeCandidates = New-Object 'System.Collections.Generic.List[string]'
    $packageFamilyNames = New-Object 'System.Collections.Generic.List[string]'

    Add-LfpUniquePathCandidate -List $dataCandidates -Value $CodexAppData
    Add-LfpUniquePathCandidate -List $dataCandidates -Value $env:CODEX_APP_DATA_DIR
    Add-LfpUniquePathCandidate -List $dataCandidates -Value (Get-LfpDefaultCodexAppDataDir)

    Add-LfpUniquePathCandidate -List $exeCandidates -Value $CodexAppExe
    Add-LfpUniquePathCandidate -List $exeCandidates -Value $env:CODEX_APP_EXE
    if ($env:LOCALAPPDATA) {
        Add-LfpUniquePathCandidate -List $exeCandidates -Value (Join-Path $env:LOCALAPPDATA "Programs/Codex/Codex.exe")
        Add-LfpUniquePathCandidate -List $exeCandidates -Value (Join-Path $env:LOCALAPPDATA "Microsoft/WindowsApps/Codex.exe")
    }

    $packages = @()
    try {
        $packages = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
            ($_.Name -like "OpenAI.Codex*") -or ($_.PackageFamilyName -like "OpenAI.Codex*")
        })
    } catch {
        $packages = @()
    }

    foreach ($package in $packages) {
        if ($package.PackageFamilyName) {
            Add-LfpUniquePathCandidate -List $packageFamilyNames -Value $package.PackageFamilyName
            if ($env:LOCALAPPDATA) {
                Add-LfpUniquePathCandidate -List $dataCandidates -Value (Join-Path $env:LOCALAPPDATA "Packages/$($package.PackageFamilyName)/LocalCache/Roaming/Codex")
                Add-LfpUniquePathCandidate -List $dataCandidates -Value (Join-Path $env:LOCALAPPDATA "Packages/$($package.PackageFamilyName)/RoamingState/Codex")
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($package.InstallLocation)) {
            Add-LfpUniquePathCandidate -List $exeCandidates -Value (Join-Path $package.InstallLocation "app/Codex.exe")
            Add-LfpUniquePathCandidate -List $exeCandidates -Value (Join-Path $package.InstallLocation "Codex.exe")
        }
    }

    $resolvedDataDir = ""
    foreach ($candidate in $dataCandidates) {
        if (Test-Path $candidate) {
            $resolvedDataDir = $candidate
            break
        }
    }

    $resolvedExePath = ""
    foreach ($candidate in $exeCandidates) {
        if (Test-Path $candidate -PathType Leaf) {
            $resolvedExePath = $candidate
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedDataDir) -and $dataCandidates.Count -gt 0) {
        $resolvedDataDir = $dataCandidates[0]
    }
    if ([string]::IsNullOrWhiteSpace($resolvedExePath) -and $exeCandidates.Count -gt 0) {
        $resolvedExePath = $exeCandidates[0]
    }

    return [pscustomobject]@{
        IsInstalled        = ($packages.Count -gt 0) -or (-not [string]::IsNullOrWhiteSpace($resolvedDataDir) -and (Test-Path $resolvedDataDir)) -or (-not [string]::IsNullOrWhiteSpace($resolvedExePath) -and (Test-Path $resolvedExePath -PathType Leaf))
        DataDir            = $resolvedDataDir
        ExePath            = $resolvedExePath
        CandidateDataDirs  = $dataCandidates.ToArray()
        CandidateExePaths  = $exeCandidates.ToArray()
        PackageFamilyNames = $packageFamilyNames.ToArray()
    }
}
