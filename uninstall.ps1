<#
Remove the wake-up hooks again. Leaves every other setting untouched.
Windows/PowerShell twin of uninstall.sh.

  .\uninstall.ps1            # from ~/.claude/settings.json
  .\uninstall.ps1 -Project   # from this repo's .claude\settings.json
#>
param(
    [switch]$Project
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot

if ($Project) {
    $Settings = Join-Path $Root '.claude\settings.json'
} else {
    $Settings = Join-Path $HOME '.claude\settings.json'
}

if (-not (Test-Path $Settings)) {
    Write-Host "nothing to do: $Settings does not exist"
    exit 0
}

$backup = "$Settings.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Copy-Item -Path $Settings -Destination $backup -Force

try {
    $config = Get-Content -Path $Settings -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Error "error: $Settings is not valid JSON"
    exit 1
}

if ($config.PSObject.Properties['hooks']) {
    $names = @($config.hooks.PSObject.Properties.Name)
    foreach ($name in $names) {
        $groups = @($config.hooks.$name)
        $kept = @()
        foreach ($g in $groups) {
            $keptHooks = @($g.hooks | Where-Object { $_.command -notmatch 'wakeup\.(ps1|sh)' })
            if ($keptHooks.Count -gt 0) {
                $g.hooks = $keptHooks
                $kept += $g
            }
        }
        if ($kept.Count -gt 0) {
            $config.hooks.$name = $kept
        } else {
            $config.hooks.PSObject.Properties.Remove($name)
        }
    }
    if (@($config.hooks.PSObject.Properties).Count -eq 0) {
        $config.PSObject.Properties.Remove('hooks')
    }
}

$json = $config | ConvertTo-Json -Depth 10
Set-Content -Path $Settings -Value $json -Encoding utf8

Write-Host "removed from -> $Settings"
Write-Host "backup       -> $backup"
