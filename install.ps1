<#
Install the wake-up hooks into ~/.claude/settings.json. Windows/PowerShell twin of install.sh.

  .\install.ps1              # global: every Claude Code session, every project
  .\install.ps1 -Project     # just this repo (.claude\settings.json here)

Safe to run repeatedly: it strips any previous claude-code-wakeup entries first
(bash or PowerShell), and backs up your settings before touching them.
#>
param(
    [switch]$Project
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
. (Join-Path $Root 'lib\common.ps1')
$HookScript = Join-Path $Root 'wakeup.ps1'
$Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HookScript`""

if ($Project) {
    $Settings = Join-Path $Root '.claude\settings.json'
    $Scope = 'this project only'
} else {
    $Settings = Join-Path $HOME '.claude\settings.json'
    $Scope = 'every Claude Code session'
}

$settingsDir = Split-Path -Parent $Settings
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
if (-not (Test-Path $Settings)) { Set-Content -Path $Settings -Value '{}' -Encoding utf8 }

try {
    $raw = Get-Content -Path $Settings -Raw
    $config = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Error "error: $Settings is not valid JSON -- fix it before installing"
    exit 1
}

$backup = "$Settings.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Copy-Item -Path $Settings -Destination $backup -Force

function Set-JsonProperty {
    param($Object, [string]$Name, $DefaultValue)
    if (-not $Object.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $DefaultValue
    }
    return $Object.$Name
}

function Remove-WakeupGroups {
    param([array]$Groups)
    $result = @()
    foreach ($g in $Groups) {
        $keptHooks = @($g.hooks | Where-Object { $_.command -notmatch 'wakeup\.(ps1|sh)' })
        if ($keptHooks.Count -gt 0) {
            $g.hooks = $keptHooks
            $result += $g
        }
    }
    return $result
}

Set-JsonProperty -Object $config -Name 'hooks' -DefaultValue ([PSCustomObject]@{}) | Out-Null

$notification = @(Set-JsonProperty -Object $config.hooks -Name 'Notification' -DefaultValue @())
$stop = @(Set-JsonProperty -Object $config.hooks -Name 'Stop' -DefaultValue @())

$entry = [PSCustomObject]@{
    matcher = '*'
    hooks   = @([PSCustomObject]@{ type = 'command'; command = $Command; timeout = 5 })
}

$config.hooks.Notification = @(Remove-WakeupGroups $notification) + $entry
$config.hooks.Stop = @(Remove-WakeupGroups $stop) + $entry

$json = $config | ConvertTo-Json -Depth 10
Set-Content -Path $Settings -Value $json -Encoding utf8

Write-Host "installed -> $Settings  (active for: $Scope)"
Write-Host "backup    -> $backup"
Write-Host ''
$config.hooks | ConvertTo-Json -Depth 10 | Write-Host
Write-Host ''
Write-Host 'Hooks load when a session starts, so restart Claude Code to arm it.'
Write-Host "Log: $WAKEUP_LOG"
