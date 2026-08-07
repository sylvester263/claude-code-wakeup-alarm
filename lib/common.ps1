# Shared settings and helpers. Dot-sourced by wakeup.ps1 and lib\play.ps1.
# Windows/PowerShell twin of lib/common.sh -- reads the same config.env.

$WakeupHome = Split-Path -Parent $PSScriptRoot

$script:ConfigFile = Join-Path $WakeupHome 'config.env'
$script:FileConfig = @{}
if (Test-Path $script:ConfigFile) {
    Get-Content $script:ConfigFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"(.*)"\s*$') {
            $key = $Matches[1]
            $raw = $Matches[2]
            # config.env values are bash `${VAR:-default}` expressions -- pull the default out.
            if ($raw -match '^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.*)\}$') {
                $default = $Matches[1]
                # A default that itself references a bash variable (e.g. $HOME/.claude/...,
                # as WAKEUP_LOG's does) can't be resolved here -- skip it and let
                # Get-WakeupSetting's own PowerShell-native default take over instead.
                if ($default -notmatch '\$') {
                    $script:FileConfig[$key] = $default
                }
            } else {
                $script:FileConfig[$key] = $raw
            }
        }
    }
}

# A real environment variable always wins over config.env, same rule as the bash version.
function Get-WakeupSetting {
    param([string]$Name, [string]$Default = '')
    $envVal = [Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $envVal -and $envVal -ne '') { return $envVal }
    if ($script:FileConfig.ContainsKey($Name)) { return $script:FileConfig[$Name] }
    return $Default
}

$WAKEUP_DELAY_SECS  = [int](Get-WakeupSetting 'WAKEUP_DELAY_SECS' '10')
$WAKEUP_IDLE_SECS   = [int](Get-WakeupSetting 'WAKEUP_IDLE_SECS' '10')
$WAKEUP_EVENTS      = @((Get-WakeupSetting 'WAKEUP_EVENTS' 'permission_prompt idle_prompt agent_needs_input agent_completed stop') -split '\s+' | Where-Object { $_ })
$WAKEUP_VIDEO       = Get-WakeupSetting 'WAKEUP_VIDEO' ''
$WAKEUP_PLAYER      = Get-WakeupSetting 'WAKEUP_PLAYER' 'ffplay'
$WAKEUP_VOLUME      = Get-WakeupSetting 'WAKEUP_VOLUME' ''
$WAKEUP_LOOP        = Get-WakeupSetting 'WAKEUP_LOOP' '0'
$WAKEUP_MAX_SECS    = [int](Get-WakeupSetting 'WAKEUP_MAX_SECS' '120')
$WAKEUP_RETURN_SECS = [int](Get-WakeupSetting 'WAKEUP_RETURN_SECS' '2')
$WAKEUP_LOG         = Get-WakeupSetting 'WAKEUP_LOG' (Join-Path $HOME '.claude\wakeup.log')
$WAKEUP_LOCK        = Get-WakeupSetting 'WAKEUP_LOCK' (Join-Path $env:TEMP 'claude-wakeup.lock')

function Write-WakeupLog {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $WAKEUP_LOG
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $WAKEUP_LOG -Value "$ts  $Message" -ErrorAction SilentlyContinue
    } catch {}
}

# Idle detection via user32.dll GetLastInputInfo -- the Windows equivalent of
# `ioreg -c IOHIDSystem` on macOS. Same two test seams as the bash version.
$script:IdleTypeDef = @'
using System;
using System.Runtime.InteropServices;
public static class WakeupIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        uint idleMs = (uint)Environment.TickCount - lii.dwTime;
        return idleMs / 1000;
    }
}
'@
if (-not ('WakeupIdle' -as [type])) {
    try { Add-Type -TypeDefinition $script:IdleTypeDef -ErrorAction Stop } catch {}
}

function Get-IdleSecs {
    if ($env:WAKEUP_IDLE_OVERRIDE_FILE -and (Test-Path $env:WAKEUP_IDLE_OVERRIDE_FILE)) {
        $val = Get-Content $env:WAKEUP_IDLE_OVERRIDE_FILE -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($val -match '^\d+$') { return [int]$val }
        return 0
    }
    if ($env:WAKEUP_IDLE_OVERRIDE -and $env:WAKEUP_IDLE_OVERRIDE -match '^\d+$') {
        return [int]$env:WAKEUP_IDLE_OVERRIDE
    }
    try {
        return [int]([WakeupIdle]::GetIdleSeconds())
    } catch {
        # Can't tell how long you've been away. Assume you're gone rather than stay silent.
        return 999
    }
}

# The video to play: WAKEUP_VIDEO if set, otherwise a random .mp4/.mov from media\.
function Resolve-WakeupVideo {
    if ($WAKEUP_VIDEO) { return $WAKEUP_VIDEO }
    $mediaDir = Join-Path $WakeupHome 'media'
    if (-not (Test-Path $mediaDir)) { return '' }
    $clips = @(Get-ChildItem -Path $mediaDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.mp4', '.mov' })
    if ($clips.Count -eq 0) { return '' }
    return ($clips | Get-Random).FullName
}

# True if an alarm is already armed or playing.
function Test-WakeupLockHeld {
    if (-not (Test-Path $WAKEUP_LOCK)) { return $false }
    $pidFile = Join-Path $WAKEUP_LOCK 'pid'
    if (-not (Test-Path $pidFile)) { return $false }
    $lockPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if (-not $lockPid) { return $false }
    return [bool](Get-Process -Id $lockPid -ErrorAction SilentlyContinue)
}
