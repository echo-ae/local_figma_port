function Restart-InPwsh7IfNeeded {
    param(
        [string]$ScriptPath,
        [hashtable]$BoundParameters = @{},
        [object[]]$ForwardArgs = @()
    )

    $isPwsh7 = $PSVersionTable.PSEdition -eq "Core" -and $PSVersionTable.PSVersion.Major -ge 7
    if ($isPwsh7) {
        return
    }

    if ($env:LOCAL_FIGMA_PORT_PWSH7_REEXEC -eq "1") {
        throw "Local Figma Port expected to restart under PowerShell 7, but is still running under PowerShell $($PSVersionTable.PSVersion)."
    }

    $pwsh = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw @"
PowerShell 7 is required for Local Figma Port Windows scripts.

Install PowerShell 7 and re-run with:
pwsh -ExecutionPolicy Bypass -File $ScriptPath
"@
    }

    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath)
    foreach ($entry in $BoundParameters.GetEnumerator()) {
        $name = "-$($entry.Key)"
        $value = $entry.Value

        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $args += $name
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                $args += $name
            }
            continue
        }

        $args += $name
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            foreach ($item in $value) {
                $args += [string]$item
            }
        } else {
            $args += [string]$value
        }
    }

    if ($ForwardArgs) {
        $args += $ForwardArgs
    }

    $previous = $env:LOCAL_FIGMA_PORT_PWSH7_REEXEC
    try {
        $env:LOCAL_FIGMA_PORT_PWSH7_REEXEC = "1"
        & $pwsh.Source @args
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        exit $exitCode
    } finally {
        if ($null -eq $previous) {
            Remove-Item Env:LOCAL_FIGMA_PORT_PWSH7_REEXEC -ErrorAction SilentlyContinue
        } else {
            $env:LOCAL_FIGMA_PORT_PWSH7_REEXEC = $previous
        }
    }
}
