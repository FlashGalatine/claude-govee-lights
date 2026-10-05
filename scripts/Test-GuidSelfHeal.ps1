<#
.SYNOPSIS
    Integration test: the daemon self-heals a rejected API GUID - from a
    Govee-API-GUID.txt seed or from the GUIDs Govee Desktop accepted before - and
    says so loudly.

.DESCRIPTION
    Reproduces the failure from 2026-09-21, when config.json ended up holding a GUID
    Govee Desktop rejected and the daemon then emitted code 1001 silently for two
    weeks. With the self-heal in place the daemon must instead try the other GUIDs it
    knows, connect, and surface usingFallbackGuid so the drift is visible.

    Hardware-gated and hermetic. It needs Govee Desktop running and a known-good GUID
    (the repo seed, else the live config), and it runs a copy of the daemon from %TEMP%
    with --config-dir pointed at a scratch folder, on its own port. The real daemon and
    config are never touched, and neither are the lights: the scratch config names a
    device that does not exist, so the scratch daemon connects and reads the roster but
    never drives - or primes DreamView on - a real device. With no hardware it SKIPS
    (exit 0) rather than fails; it is deliberately not wired into CI, which has no Govee
    Desktop.

.EXAMPLE
    .\Test-GuidSelfHeal.ps1
#>
[CmdletBinding()]
param(
    [int] $Port = 17399,
    [string] $Exe,
    [string] $DllPath = 'C:\Program Files\Govee\Govee Desktop\GoveeAPI\GoveeAPI.dll'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0
function Ok($m)   { Write-Host "  PASS  $m" -ForegroundColor Green; $script:pass++ }
function No($m,$d){ Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fail++; if ($d) { Write-Host "        $d" -ForegroundColor DarkGray } }
function Skip($m) { Write-Host "  SKIP  $m" -ForegroundColor Yellow }

if (-not $Exe) { $Exe = Join-Path $root 'src\GoveeLights.Daemon\bin\Release\net48\GoveeLightsDaemon.exe' }

Write-Host ''
Write-Host '=== GUID self-heal suite ===' -ForegroundColor Cyan
Write-Host ''

# --- preconditions: skip cleanly rather than fail when the rig is not present ----
if (-not (Test-Path $Exe)) { Skip "daemon not built at $Exe (run Build.ps1)"; exit 0 }

# Never launch an exe that predates --config-dir. It would ignore the flag, load the
# REAL config, bind the real port if the live daemon is down, and drive the real lights.
# Asked of the binary without running it: C# string literals are stored as UTF-16.
$exeHex = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($Exe))
if (-not $exeHex.Contains([System.BitConverter]::ToString([System.Text.Encoding]::Unicode.GetBytes('--config-dir')))) {
    No 'daemon build knows --config-dir' "$Exe predates it - rebuild (it was not launched)"
    exit 1
}
if (-not (Test-Path $DllPath)) { Skip 'GoveeAPI.dll not present - not a Govee machine'; exit 0 }
if (-not (Get-Process GoveeDesktop -ErrorAction SilentlyContinue)) { Skip 'Govee Desktop not running'; exit 0 }

# The known-good GUID: repo seed first, else the live daemon's current config. We do not
# hardcode it - it is a credential and it differs per machine. It is only a candidate
# until the control scenario below proves Desktop accepts it.
$good = $null
$repoSeed = Join-Path $root 'Govee-API-GUID.txt'
if (Test-Path $repoSeed) { $good = (Get-Content $repoSeed -Raw).Trim() }
if (-not $good) {
    $liveCfg = Join-Path $env:LOCALAPPDATA 'ClaudeGovee\config.json'
    if (Test-Path $liveCfg) { try { $good = ((Get-Content $liveCfg -Raw | ConvertFrom-Json).ApiGuid) } catch { } }
}
if (-not $good) { Skip 'no known-good GUID available (no seed, no live config)'; exit 0 }

$bad  = '00000000-0000-0000-0000-000000000000'  # syntactically valid, InitConnect rejects it
$bad2 = '11111111-1111-1111-1111-111111111111'  # a second, different rejected GUID

$base = "http://127.0.0.1:$Port"
function Health {
    try { return Invoke-RestMethod -Uri "$base/health" -TimeoutSec 3 -ErrorAction Stop } catch { return $null }
}

# Something already answering here would make every assertion below test the wrong
# daemon - refuse rather than produce a false pass. Checked before anything is created,
# so a refusal leaves nothing behind.
if (Health) { No "port $Port is free before the suite starts" 'another daemon answers there; pass -Port'; exit 1 }

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("govee-heal-" + [Guid]::NewGuid().ToString('N'))
$cfgDir  = Join-Path $scratch 'ClaudeGovee'
$binDir  = Join-Path $scratch 'bin'
New-Item -ItemType Directory -Path $cfgDir, $binDir -Force | Out-Null
$seedPath    = Join-Path $cfgDir 'Govee-API-GUID.txt'
$historyPath = Join-Path $cfgDir 'known-guids.txt'

# Run a COPY of the exe from outside the repo. The daemon also looks for seeds by
# walking up from its own exe, and from inside the repo that walk reaches the repo-root
# Govee-API-GUID.txt - which would make the "nothing to fall back to" scenario heal
# anyway. From %TEMP% the only seed it can find is the one a scenario places.
Copy-Item -Path (Join-Path (Split-Path $Exe -Parent) 'GoveeLightsDaemon.exe*') -Destination $binDir
$scratchExe = Join-Path $binDir 'GoveeLightsDaemon.exe'

# Every daemon this suite starts, so the finally block can kill survivors. Without it an
# assertion that throws mid-scenario skips Stop-Scratch and strands a daemon on $Port
# holding a lock on the scratch exe, which then also defeats the cleanup.
$script:started = New-Object System.Collections.ArrayList

function Write-ScratchConfig([string] $Guid) {
    # Devices names one device that does not exist. With no Devices list the renderer
    # adopts every LAN device and primes DreamView on it - on the user's real lights,
    # under the live daemon's feet. An unmatched name leaves the render roster empty
    # (one device_missing warning); connection and /health, which is all this suite
    # asserts, are unaffected.
    $cfg = @{
        Enabled = $true; ApiGuid = $Guid; Port = $Port
        Devices = @(@{ Name = '__guid_selfheal_test_no_such_device__'; Enabled = $true })
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $cfgDir 'config.json'), $cfg)
}

function Start-Scratch {
    param([string] $Guid, [string] $Seed, [string[]] $History = @())
    # Fresh config, seed, history and logs each scenario, so nothing one scenario
    # leaves behind - including the history a successful connect writes - can satisfy
    # the next.
    Remove-Item (Join-Path $cfgDir 'logs') -Recurse -Force -ErrorAction SilentlyContinue
    Write-ScratchConfig $Guid
    if ($Seed) { [System.IO.File]::WriteAllText($seedPath, $Seed) }
    elseif (Test-Path $seedPath) { Remove-Item $seedPath -Force }
    if ($History.Count -gt 0) { [System.IO.File]::WriteAllLines($historyPath, $History) }
    elseif (Test-Path $historyPath) { Remove-Item $historyPath -Force }

    $p = Start-Process -FilePath $scratchExe -ArgumentList @('--config-dir', "`"$cfgDir`"") -PassThru -WindowStyle Hidden
    [void]$script:started.Add($p)

    # /health binds before InitConnect finishes, so the first answer can still say
    # offline. Poll until it reports ready or ~12s pass; scenarios expected to stay
    # offline run the full window.
    $h = $null
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { break }
        $h = Health
        if ($h -and $h.goveeState -eq 'ready') { break }
    }
    if ($h -and $h.pid -ne $p.Id) { $h = $null }   # answered by some other process
    return @{ Proc = $p; Health = $h }
}
function Stop-Scratch($p) {
    try { Invoke-RestMethod -Uri "$base/shutdown" -Method Post -TimeoutSec 3 -ErrorAction Stop | Out-Null } catch { }
    # Wait for the exit, not a fixed sleep: the next scenario deletes the logs folder,
    # and a daemon still shutting down would keep writing into it.
    if ($p -and -not $p.WaitForExit(5000)) { try { $p.Kill(); [void]$p.WaitForExit(3000) } catch { } }
}
# @(...) around the whole read, not inside an if-expression: assigning an if-expression
# unrolls a one-line array back to a bare string, and [0] of that is its first character.
function Read-History { return ,@(if (Test-Path $historyPath) { Get-Content $historyPath }) }
function Latest-Log {
    $d = Join-Path $cfgDir 'logs'
    if (-not (Test-Path $d)) { return '' }
    $f = Get-ChildItem $d -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return (Get-Content $f.FullName -Raw) } else { return '' }
}

try {
    # --- Control, and the precondition for everything else ---------------------------
    # If Desktop refuses the "known-good" GUID - say the live config is the stale one -
    # every heal scenario below would fail for a reason that is not the code's. That one
    # case is inconclusive, so it SKIPs. It is only that case when OUR daemon answered and
    # reported a GUID rejection: no answer, an exit, or any other error is the daemon
    # failing, and fails the suite.
    Write-Host 'Good config GUID (control):' -ForegroundColor White
    $r = Start-Scratch -Guid $good
    $h = $r.Health
    if (-not ($h -and $h.goveeState -eq 'ready')) {
        $st = $null
        if ($h) { try { $st = Invoke-RestMethod -Uri "$base/status" -TimeoutSec 3 -ErrorAction Stop } catch { } }
        $lastError = if ($st) { [string]$st.govee.lastError } else { '' }
        Stop-Scratch $r.Proc
        if ($h -and $lastError -eq 'API GUID rejected.') {
            Skip ("Govee Desktop rejected the known-good GUID (...{0}) - this run is inconclusive, not a failure." -f $good.Substring([Math]::Max(0, $good.Length - 4)))
            Skip 'Put the GUID from Govee Desktop > Settings > API in the repo-root Govee-API-GUID.txt and re-run.'
            exit 0
        }
        No 'the control daemon connected on the known-good GUID' ("answered=$([bool]$h) exited=$($r.Proc.HasExited) lastError='$lastError'")
        exit 1
    }
    Ok 'connected on the configured GUID'
    if (-not $h.usingFallbackGuid) { Ok 'usingFallbackGuid = false when the configured GUID works' }
    else { No 'usingFallbackGuid = false when the configured GUID works' }
    $log = Latest-Log
    if ($log -notmatch 'govee_guid_selfhealed') { Ok 'no self-heal log when the configured GUID is fine' }
    else { No 'no self-heal log when the configured GUID is fine' 'self-heal fired unexpectedly' }
    Stop-Scratch $r.Proc
    $hist = Read-History
    if ($hist.Count -ge 1 -and $hist[0].Trim() -eq $good) { Ok 'an accepted GUID is recorded in known-guids.txt' }
    else { No 'an accepted GUID is recorded in known-guids.txt' "entries=$($hist.Count)" }
    if ($log -notmatch [regex]::Escape($good)) { Ok 'the full GUID is not written to the log' }
    else { No 'the full GUID is not written to the log' 'a full GUID leaked into the log' }

    # --- Bad config GUID, good seed -> self-heal --------------------------------------
    Write-Host ''
    Write-Host 'Bad config GUID + good seed:' -ForegroundColor White
    $r = Start-Scratch -Guid $bad -Seed $good
    $h = $r.Health
    if ($h -and $h.goveeState -eq 'ready') { Ok 'connected despite the bad configured GUID' }
    else { No 'connected despite the bad configured GUID' "goveeState=$($h.goveeState)" }
    if ($h -and $h.usingFallbackGuid) { Ok '/health reports usingFallbackGuid = true' }
    else { No '/health reports usingFallbackGuid = true' "usingFallbackGuid=$($h.usingFallbackGuid)" }
    $log = Latest-Log
    if ($log -match '"evt":"govee_guid_selfhealed"' -and $log -match '"lvl":"ERROR","evt":"govee_guid_selfhealed"') { Ok 'logged govee_guid_selfhealed at ERROR (loud)' }
    else { No 'logged govee_guid_selfhealed at ERROR (loud)' 'not found in daemon log' }
    if ($log -notmatch [regex]::Escape($bad) -and $log -notmatch [regex]::Escape($good)) { Ok 'full GUIDs are not written to the log (only tails)' }
    else { No 'full GUIDs are not written to the log' 'a full GUID leaked into the log' }

    # config.json hot-reloads. Once it holds the GUID in use, the fallback flag - and
    # doctor's "config.json's is WRONG" - must clear without a restart.
    Write-ScratchConfig $good
    $h2 = $null
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; $h2 = Health; if ($h2 -and -not $h2.usingFallbackGuid) { break } }
    if ($h2 -and -not $h2.usingFallbackGuid) { Ok 'fixing config.json clears usingFallbackGuid without a restart' }
    else { No 'fixing config.json clears usingFallbackGuid without a restart' "usingFallbackGuid=$($h2.usingFallbackGuid)" }
    Stop-Scratch $r.Proc

    # --- The 2026-09-21 shape: config and seed agree on a rejected GUID ----------------
    # /govee guid writes one value to both. If the user followed a GUID Desktop showed
    # only for a while, then Desktop went back, neither file holds the GUID that works
    # any more. Only the history - GUIDs Desktop accepted before - can heal this.
    Write-Host ''
    Write-Host 'Config and seed both rejected, good GUID in history (flip-back):' -ForegroundColor White
    $r = Start-Scratch -Guid $bad2 -Seed $bad2 -History @($bad2, $good)
    $h = $r.Health
    if ($h -and $h.goveeState -eq 'ready' -and $h.usingFallbackGuid) { Ok 'healed from the known-good history' }
    else { No 'healed from the known-good history' "goveeState=$($h.goveeState) fallback=$($h.usingFallbackGuid)" }
    Stop-Scratch $r.Proc
    $hist = Read-History
    if ($hist.Count -ge 1 -and $hist[0].Trim() -eq $good) { Ok 'the GUID that healed moves to the front of the history' }
    else { No 'the GUID that healed moves to the front of the history' "entries=$($hist.Count)" }

    # --- Bad GUID, nothing to fall back to -> offline, loud once, then throttled -------
    Write-Host ''
    Write-Host 'Bad config GUID + no seed + no history:' -ForegroundColor White
    $r = Start-Scratch -Guid $bad
    $h = $r.Health
    if ($h -and $h.goveeState -ne 'ready' -and -not $h.usingFallbackGuid) { Ok 'stays offline and does not claim a fallback' }
    else { No 'stays offline and does not claim a fallback' "goveeState=$($h.goveeState) fallback=$($h.usingFallbackGuid)" }
    $log = Latest-Log
    $failLines = @($log -split "`n" | Where-Object { $_ -match '"evt":"govee_init_failed"' })
    if ($failLines.Count -ge 1 -and $failLines[0] -match '"lvl":"ERROR"' -and $failLines[0] -match '/govee guid') {
        Ok 'first failure logged loudly (ERROR, naming /govee guid)'
    } else { No 'first failure logged loudly (ERROR, naming /govee guid)' ("lines: " + ($failLines -join ' | ')) }

    # The throttle. Retries run on the renderer tick (5s backoff first), so the ~12s window
    # holds at least two attempts. The old code logged every one - the flood that hid a
    # two-week outage. Now only the first of an unchanged streak may reach the log.
    $st = $null
    try { $st = Invoke-RestMethod -Uri "$base/status" -TimeoutSec 3 -ErrorAction Stop } catch { }
    $attempts = if ($st) { [int]$st.govee.initFailures } else { 0 }
    if ($attempts -ge 2 -and $failLines.Count -eq 1) { Ok "repeat failures are throttled ($attempts attempts, 1 log line)" }
    else { No 'repeat failures are throttled' "attempts=$attempts loggedLines=$($failLines.Count)" }

    # The obvious manual fix - paste the GUID from Settings > API into config.json - must
    # work without a restart: config hot-reloads and the daemon reads its GUID live, so
    # the next retry tries it. The window covers the backoff (next retry is <= ~30 s off).
    Write-ScratchConfig $good
    $h2 = $null
    for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 500; $h2 = Health; if ($h2 -and $h2.goveeState -eq 'ready') { break } }
    if ($h2 -and $h2.goveeState -eq 'ready' -and -not $h2.usingFallbackGuid) { Ok 'a hand-fixed config.json connects without a restart' }
    else { No 'a hand-fixed config.json connects without a restart' "goveeState=$($h2.goveeState) fallback=$($h2.usingFallbackGuid)" }
    Stop-Scratch $r.Proc

    # --- Empty GUID in config, seed beside it -> seeded at startup --------------------
    Write-Host ''
    Write-Host 'Empty config GUID + seed:' -ForegroundColor White
    $r = Start-Scratch -Guid '' -Seed $good
    $h = $r.Health
    if ($h -and $h.goveeState -eq 'ready') { Ok 'started and connected from the seed instead of refusing' }
    else { No 'started and connected from the seed instead of refusing' "goveeState=$($h.goveeState) exited=$($r.Proc.HasExited)" }
    if ((Latest-Log) -match '"evt":"guid_seeded"') { Ok 'logged guid_seeded' }
    else { No 'logged guid_seeded' 'not found in daemon log' }
    Stop-Scratch $r.Proc

    # --- Empty GUID, no seed -> the documented fail-fast (exit 2) ---------------------
    # The same contract CI asserts on a clean runner; checked here through --config-dir
    # so it can never touch a real config.
    Write-Host ''
    Write-Host 'Empty config GUID + no seed:' -ForegroundColor White
    Remove-Item (Join-Path $cfgDir 'logs') -Recurse -Force -ErrorAction SilentlyContinue
    Write-ScratchConfig ''
    Remove-Item $seedPath, $historyPath -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $scratchExe -ArgumentList @('--config-dir', "`"$cfgDir`"") -PassThru -WindowStyle Hidden
    [void]$script:started.Add($p)
    if ($p.WaitForExit(30000)) {
        if ($p.ExitCode -eq 2) { Ok 'exits 2 (no_guid) when there is no GUID and no seed' }
        else { No 'exits 2 (no_guid) when there is no GUID and no seed' "exit=$($p.ExitCode)" }
    } else { $p.Kill(); No 'exits fast when there is no GUID and no seed' 'still running after 30s' }
}
finally {
    foreach ($sp in $script:started) {
        if (-not $sp.HasExited) { try { $sp.Kill(); [void]$sp.WaitForExit(3000) } catch { } }
    }
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
