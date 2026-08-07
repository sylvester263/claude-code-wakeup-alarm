<#
Claude Code hook entrypoint. Windows/PowerShell twin of wakeup.sh.

Two rules live here: this script must return in milliseconds (it sits in the path of
every session), and it must never exit non-zero (a failing hook must not break your work).
So it only decides *whether* to wake you, then hands off to a detached worker.
#>

try {
    . (Join-Path $PSScriptRoot 'lib\common.ps1')

    $payload = [Console]::In.ReadToEnd()

    $eventName = $null
    $notificationType = $null
    try {
        $json = $payload | ConvertFrom-Json -ErrorAction Stop
        $eventName = $json.hook_event_name
        $notificationType = $json.notification_type
    } catch {}

    $key = switch ($eventName) {
        'Stop'         { 'stop' }
        'Notification' { $notificationType }
        default        { $null }
    }

    if ($key) {
        # Not an event you asked to be woken for.
        if ($WAKEUP_EVENTS -contains $key) {
            # A permission prompt and a Stop can land seconds apart; one alarm is plenty.
            if (Test-WakeupLockHeld) {
                Write-WakeupLog "skip $key (an alarm is already armed)"
            } else {
                $playScript = Join-Path $WakeupHome 'lib\play.ps1'
                # Detached: Start-Process spawns an independent process that survives
                # this hook exiting, same role nohup plays in wakeup.sh.
                # ArgumentList must be one pre-quoted string, not an array: Start-Process
                # joins array elements with bare spaces and won't quote a path that
                # contains one (this repo's own path does), silently truncating -File.
                $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$playScript`" `"$key`""
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList $argString `
                    -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
} catch {
    # A broken config or unexpected input must never break the session.
}

exit 0
