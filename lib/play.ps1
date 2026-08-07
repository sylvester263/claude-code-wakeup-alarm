<#
Detached worker: wait out the grace period, check you're actually away, play the
alarm, and cut it the moment you touch the keyboard. Windows/PowerShell twin of lib/play.sh.
#>
param(
    [string]$Trigger = 'unknown'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$script:PlayerProc = $null

# --- lock --------------------------------------------------------------------
# mkdir-equivalent New-Item is atomic on NTFS too, so two hooks firing at the same
# instant still produce one alarm.
function Get-LockPid {
    $pidFile = Join-Path $WAKEUP_LOCK 'pid'
    if (Test-Path $pidFile) { return Get-Content $pidFile -ErrorAction SilentlyContinue }
    return $null
}

function Invoke-AcquireLock {
    try {
        New-Item -ItemType Directory -Path $WAKEUP_LOCK -ErrorAction Stop | Out-Null
        Set-Content -Path (Join-Path $WAKEUP_LOCK 'pid') -Value $PID
        return $true
    } catch {
        $existingPid = Get-LockPid
        if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            return $false
        }
        Remove-Item -Path $WAKEUP_LOCK -Recurse -Force -ErrorAction SilentlyContinue
        try {
            New-Item -ItemType Directory -Path $WAKEUP_LOCK -ErrorAction Stop | Out-Null
            Set-Content -Path (Join-Path $WAKEUP_LOCK 'pid') -Value $PID
            return $true
        } catch { return $false }
    }
}

# --- volume --------------------------------------------------------------------
# No clean restore-safe Windows one-liner exists (unlike `osascript set volume`) --
# per README's own Windows-port table, the honest answer is a documented no-op.
function Set-WakeupVolume {
    if ($WAKEUP_VOLUME) {
        Write-WakeupLog 'note: WAKEUP_VOLUME is a no-op on Windows (no restore-safe volume API wired up)'
    }
}

# --- players ---------------------------------------------------------------
function Test-FfplayAvailable {
    return [bool](Get-Command ffplay -ErrorAction SilentlyContinue)
}

function Start-WakeupPlayer {
    param([string]$VideoPath)
    # ArgumentList is a single pre-quoted string, not an array -- see the matching
    # comment in wakeup.ps1 for why (Start-Process won't quote spaces in an array itself).
    if ((Test-FfplayAvailable) -and $WAKEUP_PLAYER -ne 'wpf') {
        $argString = "-fs -autoexit -loglevel quiet `"$VideoPath`""
        $script:PlayerProc = Start-Process -FilePath 'ffplay' `
            -ArgumentList $argString `
            -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
    } else {
        if (-not (Test-FfplayAvailable)) {
            Write-WakeupLog 'ffplay not installed -- using WPF fallback player'
        }
        $wpfScript = Join-Path $WakeupHome 'lib\wpf-player.ps1'
        $argString = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$wpfScript`" `"$VideoPath`""
        $script:PlayerProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $argString `
            -PassThru -ErrorAction SilentlyContinue
    }
}

function Test-WakeupPlayerRunning {
    if ($null -eq $script:PlayerProc) { return $false }
    $script:PlayerProc.Refresh()
    return -not $script:PlayerProc.HasExited
}

function Stop-WakeupPlayer {
    if ($script:PlayerProc -and -not $script:PlayerProc.HasExited) {
        try { Stop-Process -Id $script:PlayerProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# --- run ---------------------------------------------------------------------
function Invoke-Wakeup {
    Write-WakeupLog "armed by $Trigger -- waiting ${WAKEUP_DELAY_SECS}s"
    Start-Sleep -Seconds $WAKEUP_DELAY_SECS

    $idle = Get-IdleSecs
    if ($idle -lt $WAKEUP_IDLE_SECS) {
        Write-WakeupLog "skipped: you're here (idle ${idle}s < ${WAKEUP_IDLE_SECS}s)"
        return
    }

    $video = Resolve-WakeupVideo
    if (-not $video -or -not (Test-Path $video)) {
        Write-WakeupLog "WARN nothing to play (WAKEUP_VIDEO='$WAKEUP_VIDEO', no clips in media\?)"
        return
    }

    if ($env:WAKEUP_DRY_RUN -eq '1') {
        Write-WakeupLog "PLAY $video (dry run, trigger=$Trigger, idle=${idle}s)"
        return
    }

    Set-WakeupVolume
    Write-WakeupLog "PLAY $video (trigger=$Trigger, idle=${idle}s)"

    $deadline = (Get-Date).AddSeconds($WAKEUP_MAX_SECS)
    while ($true) {
        Start-WakeupPlayer -VideoPath $video
        while (Test-WakeupPlayerRunning) {
            if ((Get-IdleSecs) -lt $WAKEUP_RETURN_SECS) {
                Write-WakeupLog "you're back -- stopping"
                return
            }
            if ((Get-Date) -ge $deadline) {
                Write-WakeupLog "hit WAKEUP_MAX_SECS (${WAKEUP_MAX_SECS}s) -- stopping"
                return
            }
            Start-Sleep -Seconds 1
        }
        if ($WAKEUP_LOOP -ne '1' -or (Get-Date) -ge $deadline) { break }
    }
    Write-WakeupLog 'played through'
}

if (-not (Invoke-AcquireLock)) {
    Write-WakeupLog "skip $Trigger (another alarm holds the lock)"
    exit 0
}

try {
    Invoke-Wakeup
} finally {
    Stop-WakeupPlayer
    if (Test-Path $WAKEUP_LOCK) {
        Remove-Item -Path $WAKEUP_LOCK -Recurse -Force -ErrorAction SilentlyContinue
    }
}
