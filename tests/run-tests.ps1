<#
Logic tests. No video is actually played: the worker runs in dry-run mode and
idle time is faked, so this is safe to run any time. Windows/PowerShell twin of
tests/run-tests.sh -- same fixtures, same scenarios.

  .\tests\run-tests.ps1
#>

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Fix = Join-Path $Here 'fixtures'
$Work = Join-Path $env:TEMP ("claude-wakeup-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work -Force | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:Log = $null
$script:Lock = $null
$script:LastFireExitCode = 0

function Test-Pass($msg) {
    Write-Host "  [PASS] $msg" -ForegroundColor Green
    $script:PassCount++
}
function Test-Fail($msg, $detail = '') {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    if ($detail) { Write-Host "     $detail" }
    $script:FailCount++
}

function Test-Setup($name) {
    $script:Log = Join-Path $Work "$name.log"
    $script:Lock = Join-Path $Work "$name.lock"
    New-Item -ItemType File -Path $script:Log -Force | Out-Null
    if (Test-Path $script:Lock) { Remove-Item -Recurse -Force $script:Lock -ErrorAction SilentlyContinue }
}

# Run the hook exactly as Claude Code would: JSON on stdin.
function Invoke-Fire {
    param([string]$Fixture, [hashtable]$EnvVars = @{})
    $allVars = @{ WAKEUP_LOG = $script:Log; WAKEUP_LOCK = $script:Lock; WAKEUP_DRY_RUN = '1' } + $EnvVars
    $envBackup = @{}
    foreach ($k in $allVars.Keys) {
        $envBackup[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, [string]$allVars[$k])
    }
    try {
        Get-Content $Fixture -Raw -ErrorAction SilentlyContinue |
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'wakeup.ps1') | Out-Null
        $script:LastFireExitCode = $LASTEXITCODE
    } finally {
        foreach ($k in $envBackup.Keys) { [Environment]::SetEnvironmentVariable($k, $envBackup[$k]) }
    }
}

# Poll instead of sleeping a fixed amount: keeps the suite fast and non-flaky.
function Wait-ForLog {
    param([string]$Pattern, [int]$TimeoutSecs = 8)
    $deadline = (Get-Date).AddSeconds($TimeoutSecs)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $script:Log) -and (Select-String -Path $script:Log -Pattern $Pattern -CaseSensitive -Quiet -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Test-LogHasPlay {
    return [bool](Select-String -Path $script:Log -Pattern 'PLAY ' -CaseSensitive -Quiet -ErrorAction SilentlyContinue)
}

# Wait for every spawned worker to finish so the next test starts clean.
function Wait-Settle {
    $i = 0
    while ((Test-Path $script:Lock) -and $i -lt 100) { Start-Sleep -Milliseconds 100; $i++ }
}

Write-Host ''
Write-Host 'claude-code-wakeup -- logic tests (PowerShell)'
Write-Host ''

# 1 -----------------------------------------------------------------------
Test-Setup 't1'
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60' }
if (Wait-ForLog 'PLAY ') { Test-Pass "permission prompt while you're away (idle 60s) plays the alarm" }
else { Test-Fail "permission prompt while you're away (idle 60s) plays the alarm" (Get-Content $script:Log -Raw) }
Wait-Settle

# 2 -----------------------------------------------------------------------
Test-Setup 't2'
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '2' }
$sawHere = Wait-ForLog "skipped: you're here"
if ($sawHere -and -not (Test-LogHasPlay)) { Test-Pass "permission prompt while you're at the desk (idle 2s) stays silent" }
else { Test-Fail "permission prompt while you're at the desk (idle 2s) stays silent" (Get-Content $script:Log -Raw) }
Wait-Settle

# 3 -----------------------------------------------------------------------
Test-Setup 't3'
Invoke-Fire (Join-Path $Fix 'stop.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60' }
if (Wait-ForLog 'PLAY .*trigger=stop') { Test-Pass "Claude finishing a task while you're away plays the alarm" }
else { Test-Fail "Claude finishing a task while you're away plays the alarm" (Get-Content $script:Log -Raw) }
Wait-Settle

# 4 -----------------------------------------------------------------------
Test-Setup 't4'
Invoke-Fire (Join-Path $Fix 'auth_success.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60' }
Start-Sleep -Seconds 2
if ((Get-Item $script:Log).Length -eq 0) { Test-Pass "an event you didn't subscribe to (auth_success) is ignored" }
else { Test-Fail "an event you didn't subscribe to (auth_success) is ignored" (Get-Content $script:Log -Raw) }
Wait-Settle

# 5 -----------------------------------------------------------------------
Test-Setup 't5'
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60' }
Invoke-Fire (Join-Path $Fix 'stop.json') @{ WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60' }
Wait-ForLog 'PLAY ' | Out-Null
Start-Sleep -Seconds 2
$count = @(Select-String -Path $script:Log -Pattern 'PLAY ' -CaseSensitive -ErrorAction SilentlyContinue).Count
if ($count -eq 1) { Test-Pass "two events firing at once produce exactly one alarm" }
else { Test-Fail "two events firing at once produce exactly one alarm" "got $count PLAY lines" }
Wait-Settle

# 6 -----------------------------------------------------------------------
Test-Setup 't6'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{ WAKEUP_DELAY_SECS = '30'; WAKEUP_IDLE_OVERRIDE = '60' }
$sw.Stop()
# Looser budget than the bash suite's 500ms -- powershell.exe startup overhead is real.
if ($sw.ElapsedMilliseconds -lt 1500) { Test-Pass "the hook never blocks Claude Code (returned in $($sw.ElapsedMilliseconds)ms)" }
else { Test-Fail "the hook never blocks Claude Code" "took $($sw.ElapsedMilliseconds)ms" }
$pidFile = Join-Path $script:Lock 'pid'
if (Test-Path $pidFile) {
    $lockPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($lockPid) { Stop-Process -Id $lockPid -Force -ErrorAction SilentlyContinue }
}
if (Test-Path $script:Lock) { Remove-Item -Recurse -Force $script:Lock -ErrorAction SilentlyContinue }

# 7 -----------------------------------------------------------------------
Test-Setup 't7'
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{ WAKEUP_DELAY_SECS = '2'; WAKEUP_IDLE_OVERRIDE = '60' }
if (Test-LogHasPlay) { Test-Fail "the worker outlives the hook process" "played before the hook returned" }
elseif (Wait-ForLog 'PLAY ' 6) { Test-Pass "the worker outlives the hook process and plays after the grace period" }
else { Test-Fail "the worker outlives the hook process" (Get-Content $script:Log -Raw) }
Wait-Settle

# 8 -----------------------------------------------------------------------
Test-Setup 't8'
Invoke-Fire (Join-Path $Fix 'malformed.json')
$rcBad = $script:LastFireExitCode
Invoke-Fire (Join-Path $Fix 'empty.json')
$rcEmpty = $script:LastFireExitCode
Start-Sleep -Milliseconds 500
if ($rcBad -eq 0 -and $rcEmpty -eq 0 -and (Get-Item $script:Log).Length -eq 0) {
    Test-Pass "malformed and empty hook input exit 0 silently"
} else {
    Test-Fail "malformed and empty hook input exit 0 silently" "rc=$rcBad/$rcEmpty log=$(Get-Content $script:Log -Raw)"
}
Wait-Settle

# 9 -----------------------------------------------------------------------
Test-Setup 't9'
Invoke-Fire (Join-Path $Fix 'permission_prompt.json') @{
    WAKEUP_DELAY_SECS = '1'; WAKEUP_IDLE_OVERRIDE = '60'
    WAKEUP_VIDEO = (Join-Path $Work 'does-not-exist.mp4')
}
$sawWarn = Wait-ForLog 'WARN nothing to play'
if ($sawWarn -and -not (Test-LogHasPlay)) { Test-Pass "a missing video file warns instead of breaking anything" }
else { Test-Fail "a missing video file warns instead of breaking anything" (Get-Content $script:Log -Raw) }
Wait-Settle

# 10 ----------------------------------------------------------------------
Test-Setup 't10'
$env:WAKEUP_LOG = $script:Log
. (Join-Path $Root 'lib\common.ps1')
$video = Resolve-WakeupVideo
Remove-Item Env:\WAKEUP_LOG -ErrorAction SilentlyContinue
if ($video -and (Test-Path $video)) { Test-Pass "media\ auto-discovery finds $(Split-Path -Leaf $video)" }
else { Test-Fail "media\ auto-discovery finds a clip" "got '$video'" }

Write-Host ''
if ($script:FailCount -eq 0) {
    Write-Host "$($script:PassCount) passed" -ForegroundColor Green
} else {
    Write-Host "$($script:PassCount) passed, $($script:FailCount) failed" -ForegroundColor Red
}
Write-Host ''

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue

if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
