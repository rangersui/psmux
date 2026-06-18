$ErrorActionPreference = "Continue"
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX) {
    $cmd = Get-Command psmux -EA Stop
    $PSMUX = if ($cmd.Path) { $cmd.Path } elseif ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
}
if (-not $PSMUX) {
    Write-Host "FATAL: could not resolve psmux executable path" -ForegroundColor Red
    exit 1
}
$SESSION = "pipe_pane_test_$PID"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Session([string]$Name, [int]$TimeoutMs = 10000) {
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
            if ($port -match '^\d+$') { return $true }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

Write-Host "`n=== pipe-pane Forwarding Tests ===" -ForegroundColor Cyan

$logFile  = Join-Path $env:TEMP "psmux_pipe_pane_test_$([guid]::NewGuid().ToString('N')).txt"
$logFile2 = Join-Path $env:TEMP "psmux_pipe_pane_toggle_$([guid]::NewGuid().ToString('N')).txt"
$logFile3 = Join-Path $env:TEMP "psmux_pipe_pane_quoting_$([guid]::NewGuid().ToString('N')).txt"

Cleanup
try {

& $PSMUX new-session -d -s $SESSION -x 120 -y 30 | Out-Null
if (-not (Wait-Session $SESSION)) {
    Write-Host "FATAL: failed to create test session" -ForegroundColor Red
    exit 1
}

# Test 1: pipe-pane forwards pane output to command stdin
$pipeCmd = "`$input | Out-File -FilePath '$logFile' -Encoding utf8 -Append"
& $PSMUX pipe-pane -t $SESSION $pipeCmd 2>&1 | Out-Null
Start-Sleep -Milliseconds 1000  # allow pipe process to spawn (cold start needs more)

$marker = "PIPE_FORWARD_TEST_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 5000  # first write needs extra time: server cold start + PowerShell pipe init

if ((Test-Path $logFile) -and ((Get-Content $logFile -Raw -EA SilentlyContinue) -match [regex]::Escape($marker))) {
    Write-Pass "pipe-pane forwards pane output to pipe process stdin"
} else {
    Write-Fail "pipe-pane did not forward output (log file empty or missing marker)"
    if (Test-Path $logFile) {
        $size = (Get-Item $logFile).Length
        Write-Host "    log file exists, size=$size bytes" -ForegroundColor Yellow
    } else {
        Write-Host "    log file does not exist" -ForegroundColor Yellow
    }
}

# Test 2: pipe-pane captures multiple commands
$marker2 = "SECOND_MARKER_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker2" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 3000

if ((Test-Path $logFile) -and ((Get-Content $logFile -Raw -EA SilentlyContinue) -match [regex]::Escape($marker2))) {
    Write-Pass "pipe-pane captures subsequent output (persistent forwarding)"
} else {
    Write-Fail "pipe-pane did not capture second marker"
}

# Test 3: pipe-pane close (no args = stop piping)
& $PSMUX pipe-pane -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$marker3 = "AFTER_CLOSE_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker3" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500

if ((Test-Path $logFile) -and ((Get-Content $logFile -Raw -EA SilentlyContinue) -match [regex]::Escape($marker3))) {
    Write-Fail "pipe-pane still forwarding after close"
} else {
    Write-Pass "pipe-pane stops forwarding after close (no-arg call)"
}

# Test 4: -o toggle starts then stops
$pipeCmd2 = "`$input | Out-File -FilePath '$logFile2' -Encoding utf8 -Append"
& $PSMUX pipe-pane -t $SESSION -o $pipeCmd2 2>&1 | Out-Null
Start-Sleep -Milliseconds 500   # allow pipe process to spawn

$marker4 = "TOGGLE_ON_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker4" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 3000

$toggleOnOk = (Test-Path $logFile2) -and ((Get-Content $logFile2 -Raw -EA SilentlyContinue) -match [regex]::Escape($marker4))

# Toggle off (same -o call with existing pipe)
& $PSMUX pipe-pane -t $SESSION -o $pipeCmd2 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$marker5 = "TOGGLE_OFF_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker5" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500

$toggleOffOk = -not ((Get-Content $logFile2 -Raw -EA SilentlyContinue) -match [regex]::Escape($marker5))

if ($toggleOnOk -and $toggleOffOk) {
    Write-Pass "pipe-pane -o toggle: on then off"
} elseif (-not $toggleOnOk) {
    Write-Fail "pipe-pane -o toggle: did not capture output when on"
} else {
    Write-Fail "pipe-pane -o toggle: still capturing after toggle off"
}

# Test 5: command with special chars (quotes, flags) round-trips correctly
$pipeCmdQuoted = "`$input | Out-File -FilePath '$logFile3' -Encoding utf8 -Append"
& $PSMUX pipe-pane -t $SESSION $pipeCmdQuoted 2>&1 | Out-Null
Start-Sleep -Milliseconds 500   # allow pipe process to spawn

$marker6 = "QUOTE_TEST_$(Get-Random)"
& $PSMUX send-keys -t $SESSION "echo $marker6" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 3000

& $PSMUX pipe-pane -t $SESSION 2>&1 | Out-Null

if ((Test-Path $logFile3) -and ((Get-Content $logFile3 -Raw -EA SilentlyContinue) -match [regex]::Escape($marker6))) {
    Write-Pass "pipe-pane command with -FilePath/-Encoding flags preserved through quoting"
} else {
    Write-Fail "pipe-pane command with special flags was mangled (quoting issue)"
}

} finally {
    Cleanup
    Remove-Item $logFile  -Force -EA SilentlyContinue
    Remove-Item $logFile2 -Force -EA SilentlyContinue
    Remove-Item $logFile3 -Force -EA SilentlyContinue
}

Write-Host "`n=== pipe-pane Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
