<#
Live test -- this one really plays the video, with sound, fullscreen.
Windows/PowerShell twin of tests/live-test.sh.

  .\tests\live-test.ps1          # fakes "you're away", plays, then fakes you coming back
  .\tests\live-test.ps1 -Real    # no faking: take your hands off the keyboard and wait
#>
param(
    [switch]$Real
)

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Work = Join-Path $env:TEMP ("claude-wakeup-live-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$Log = Join-Path $Work 'live.log'
$Lock = Join-Path $Work 'live.lock'

function Test-PlayerProcessRunning {
    if (Get-Process -Name 'ffplay' -ErrorAction SilentlyContinue) { return $true }
    if (Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'wpf-player\.ps1' }) { return $true }
    return $false
}

try {
    if ($Real) {
        Write-Host ''
        Write-Host 'Real end-to-end test.'
        Write-Host "Take your hands off the keyboard and mouse now -- pretend you're on your phone."
        Write-Host 'The alarm should fire in about 10 seconds, and stop the moment you touch anything.'
        Write-Host ''
        foreach ($i in 5, 4, 3, 2, 1) { Write-Host -NoNewline "`r  starting in $i " ; Start-Sleep -Seconds 1 }
        Write-Host "`r                        "

        $env:WAKEUP_LOG = $Log
        $env:WAKEUP_LOCK = $Lock
        Get-Content (Join-Path $Here 'fixtures\permission_prompt.json') -Raw |
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'wakeup.ps1') | Out-Null
        Remove-Item Env:\WAKEUP_LOG, Env:\WAKEUP_LOCK -ErrorAction SilentlyContinue

        Write-Host 'hook returned. waiting...'
        Start-Sleep -Seconds 25
        Write-Host ''
        Get-Content $Log
        exit 0
    }

    $Idle = Join-Path $Work 'idle'
    Set-Content -Path $Idle -Value '60'

    Write-Host ''
    Write-Host "1/2  playing the alarm (pretending you've been away 60s)"
    $env:WAKEUP_LOG = $Log
    $env:WAKEUP_LOCK = $Lock
    $env:WAKEUP_DELAY_SECS = '1'
    $env:WAKEUP_IDLE_OVERRIDE_FILE = $Idle
    Get-Content (Join-Path $Here 'fixtures\permission_prompt.json') -Raw |
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'wakeup.ps1') | Out-Null
    Remove-Item Env:\WAKEUP_LOG, Env:\WAKEUP_LOCK, Env:\WAKEUP_DELAY_SECS, Env:\WAKEUP_IDLE_OVERRIDE_FILE -ErrorAction SilentlyContinue

    # Give it the grace period plus a moment to launch the player.
    Start-Sleep -Seconds 4

    if (Test-PlayerProcessRunning) {
        Write-Host '     [OK] video is playing'
    } else {
        Write-Host '     [FAIL] nothing is playing'
        Get-Content $Log
        exit 1
    }

    Write-Host '2/2  simulating you coming back to the desk...'
    Set-Content -Path $Idle -Value '0'

    $stopped = $false
    for ($i = 0; $i -lt 60; $i++) {
        if (-not (Test-PlayerProcessRunning)) { $stopped = $true; break }
        Start-Sleep -Milliseconds 250
    }

    if (-not $stopped) {
        Write-Host '     [FAIL] player is still running -- it should have stopped'
        Get-Process -Name 'ffplay' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Content $Log
        exit 1
    }

    Write-Host "     [OK] alarm cut out when you came back"
    Write-Host ''
    Get-Content $Log
} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
