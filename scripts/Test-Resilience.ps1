<#
.SYNOPSIS
    Verify the daemon can never break Claude Code.

.DESCRIPTION
    The headline requirement is that a dead or hung daemon costs a session nothing.
    Hook latency is measured with Node, because Claude Code runs on Node - .NET stalls
    a full 2s on a refused loopback connection and would give a wrong answer here.
    See docs/HOOKS.md.
#>
[CmdletBinding()]
param([int] $Port = 17321)

$base = "http://127.0.0.1:$Port"
$root = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0

function Check($name, $ok, $detail) {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL  $name" -ForegroundColor Red;   $script:fail++ }
    if ($detail) { Write-Host "        $detail" -ForegroundColor DarkGray }
}

function Measure-HookLatency {
    # Node, not .NET - see the module comment.
    $js = @"
const http = require('http');
let n = 0, times = [];
function go() {
  const t0 = process.hrtime.bigint();
  const req = http.request({host:'127.0.0.1', port:$Port, path:'/hook?e=pre_tool', method:'POST', timeout:2000},
    res => { res.resume(); res.on('end', () => done(t0)); });
  req.on('error', () => done(t0));
  req.on('timeout', () => req.destroy());
  req.end(JSON.stringify({hook_event_name:'PreToolUse', session_id:'lat', tool_name:'Bash'}));
}
function done(t0) {
  times.push(Number(process.hrtime.bigint() - t0) / 1e6);
  if (++n < 8) go();
  else console.log(JSON.stringify({avg: times.reduce((a,b)=>a+b,0)/times.length, max: Math.max(...times)}));
}
go();
"@
    $f = Join-Path $env:TEMP ("hooklat-" + [guid]::NewGuid().ToString('N') + ".js")
    Set-Content -Path $f -Value $js -Encoding UTF8
    try { return (& node $f | ConvertFrom-Json) } finally { Remove-Item $f -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '=== Resilience suite ===' -ForegroundColor Cyan
Write-Host ''

# --- daemon alive ---
Write-Host 'With the daemon RUNNING:' -ForegroundColor White
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Ensure-Daemon.ps1') | Out-Null
Start-Sleep -Seconds 2
$live = Measure-HookLatency
Check 'hook latency under 50ms' ($live.avg -lt 50) ("avg {0:N2}ms  max {1:N2}ms" -f $live.avg, $live.max)

$h = $null
try { $h = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 3 } catch { }
Check 'daemon healthy' ($null -ne $h -and $h.ok) ("govee=$($h.goveeState)")

# --- daemon dead ---
Write-Host ''
Write-Host 'With the daemon KILLED:' -ForegroundColor White
try { Invoke-RestMethod -Uri "$base/shutdown" -Method Post -TimeoutSec 2 | Out-Null } catch { }
Start-Sleep -Milliseconds 1000
Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$dead = Measure-HookLatency
Check 'hook fails fast (under 50ms)' ($dead.avg -lt 50) ("avg {0:N2}ms  max {1:N2}ms - this is the guarantee that a crashed daemon never stalls a session" -f $dead.avg, $dead.max)

# --- recovery ---
Write-Host ''
Write-Host 'Recovery:' -ForegroundColor White
$payload = '{"hook_event_name":"SessionStart","session_id":"resilience","cwd":"' + ($root -replace '\\','\\') + '","source":"startup"}'
$sw = [Diagnostics.Stopwatch]::StartNew()
$payload | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Ensure-Daemon.ps1') | Out-Null
$code = $LASTEXITCODE
$sw.Stop()
Check 'Ensure-Daemon exits 0' ($code -eq 0) "exit=$code in $($sw.ElapsedMilliseconds)ms"

Start-Sleep -Seconds 2
$h2 = $null
try { $h2 = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 4 } catch { }
Check 'daemon restarted' ($null -ne $h2 -and $h2.ok) ("pid=$($h2.pid) govee=$($h2.goveeState)")
Check 'session registered by bootstrap' ($null -ne $h2 -and $h2.sessions -ge 1) ("sessions=$($h2.sessions)")

# --- single instance ---
Write-Host ''
Write-Host 'Single instance:' -ForegroundColor White
Start-Process -FilePath (Join-Path $root 'dist\daemon\GoveeLightsDaemon.exe') -WindowStyle Hidden
Start-Sleep -Seconds 3
$count = @(Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue).Count
Check 'duplicate instance exits' ($count -le 1) "instances=$count"

# --- cleanup ---
try {
    Invoke-RestMethod -Uri "$base/hook?e=session_end" -Method Post -TimeoutSec 2 `
        -Body '{"hook_event_name":"SessionEnd","session_id":"resilience"}' -ContentType 'application/json' | Out-Null
} catch { }

Write-Host ''
Write-Host ("=== $pass passed, $fail failed ===") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($fail -eq 0) { 0 } else { 1 })
