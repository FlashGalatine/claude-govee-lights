<#
.SYNOPSIS
    Emission-timing tests: what the renderer actually sends, headlessly.

.DESCRIPTION
    The 2026-08-15 camera investigation proved the failure modes of this daemon are
    invisible at the frame level: Effects computed perfect chase frames for weeks while
    the strip showed nothing, because the EMISSION pattern (transition bursts at 25/s,
    segment writes landing inside the DreamView engagement window) is what the hardware
    actually reacts to. --dump-frames cannot see any of that; these tests assert on the
    wire-call log from --dump-emits, which runs the real Renderer against a recording
    transport in real time.

    Real time means real sleeps: this file takes ~10s. Margins are generous (tick is
    20ms in the test configs; assertions allow 3-4 ticks of jitter) so CI noise does
    not flake them.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Emits.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path $PSScriptRoot -Parent
$pass = 0
$fail = 0

function Ok($msg, $detail) {
    Write-Host "  PASS  $msg" -ForegroundColor Green
    if ($detail) { Write-Host "        $detail" -ForegroundColor DarkGray }
    $script:pass++
}
function No($msg, $detail) {
    Write-Host "  FAIL  $msg" -ForegroundColor Red
    if ($detail) { Write-Host "        $detail" -ForegroundColor Yellow }
    $script:fail++
}
function Section($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

$exe = @(
    (Join-Path $root 'src/GoveeLights.Daemon/bin/Release/net48/GoveeLightsDaemon.exe'),
    (Join-Path $root 'dist/daemon/GoveeLightsDaemon.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $exe) {
    Write-Host 'No build output found - run scripts\Build.ps1 first.' -ForegroundColor Yellow
    exit 1
}

$work = Join-Path $env:TEMP 'govee-emit-tests'
New-Item -ItemType Directory -Force $work | Out-Null

# Base config all tests share; each test overrides Render knobs. Brightness 0 on every
# state = "leave alone", so no Brightness calls muddy the traces.
function Write-TestConfig($name, $render) {
    $cfg = @{
        Enabled = $true; ApiGuid = 'test'; GoveeDllPath = 'unused'; Port = 17321
        LogLevel = 'WARN'; IdleShutdownMinutes = 0; SessionTtlMinutes = 30
        IsGradientOff = 1
        Render = $render
        Devices = @()
        States = @{
            ToolOther = @{ Color = '#404040'; Effect = 'solid';   Brightness = 0 }
            ToolShell = @{ Color = '#FF7A18'; Effect = 'chase';   Hz = 0.2; Depth = 0.3; Brightness = 0 }
            ToolWeb   = @{ Effect = 'rainbow'; Hz = 1.0; Brightness = 0 }
        }
        QuietHours = @{ Enabled = $false; Start = '23:30'; End = '08:00' }
    }
    $p = Join-Path $work "$name.json"
    $cfg | ConvertTo-Json -Depth 6 | Out-File $p -Encoding utf8
    return $p
}

# Runs the exe with a hard timeout so a regression that hangs (or a --dump-emits that
# falls through to a real daemon boot) cannot hang the suite.
function Invoke-Emits($cfgPath, $script, $extra) {
    $outFile = Join-Path $work 'out.txt'
    $errFile = Join-Path $work 'err.txt'
    $argv = @('--dump-emits', '--config', "`"$cfgPath`"", '--script', "`"$script`"", '--segments', '10') + @($extra)
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit(15000)) {
        try { $p.Kill() } catch {}
        return @{ ok = $false; why = 'timeout (15s) - exe hung'; lines = @() }
    }
    # PS 5.1 quirk: ExitCode is null after a timed WaitForExit until the no-arg
    # overload flushes the process handle.
    $p.WaitForExit()
    if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) {
        $err = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        return @{ ok = $false; why = "exit $($p.ExitCode): $err"; lines = @() }
    }
    $lines = @(Get-Content $outFile -ErrorAction SilentlyContinue)
    return @{ ok = $true; lines = $lines }
}

# Parses "ms|call|device|detail" rows; force markers are "ms|force|<state>".
function ConvertFrom-EmitLines($lines) {
    $rows = @()
    foreach ($l in $lines) {
        if ($l.StartsWith('#')) { continue }
        $parts = $l.Split('|')
        if ($parts.Count -lt 2) { continue }
        $rows += [pscustomobject]@{
            ms     = [double]$parts[0]
            call   = $parts[1]
            device = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            detail = if ($parts.Count -gt 3) { ($parts[3..($parts.Count-1)] -join '|') } else { '' }
        }
    }
    return $rows
}

Write-Host ''
Write-Host '=== Emission-timing tests ===' -ForegroundColor Cyan
Write-Host "exe: $exe" -ForegroundColor DarkGray

# --------------------------------------------------------------- harness contract
Section 'Harness'
$cfgDefault = Write-TestConfig 'default' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 400; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 0; SegmentRePrimeSeconds = 300
}
$r = Invoke-Emits $cfgDefault 'ToolOther:400' @()
if ($r.ok -and $r.lines.Count -gt 0 -and $r.lines[0].StartsWith('# emits')) {
    Ok '--dump-emits runs and prints its header'
} else {
    $why = if ($r.why) { $r.why } else { "first line: '$($r.lines | Select-Object -First 1)'" }
    No '--dump-emits runs and prints its header' $why
}

# ------------------------------------------------------------ T1 prime at sync
Section 'Razer priming happens at roster sync, not lazily'
$r = Invoke-Emits $cfgDefault 'ToolOther:600' @()
$rows = ConvertFrom-EmitLines $r.lines
$razer = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
$segs  = @($rows | Where-Object { $_.call -eq 'segments' })
$cols  = @($rows | Where-Object { $_.call -eq 'color' })
if ($razer.Count -ge 1 -and $razer[0].ms -lt 300) {
    Ok 'Razer(on) fired at sync during a solid-only script' ("t=$($razer[0].ms)ms")
} else {
    No 'Razer(on) fired at sync during a solid-only script' `
       "razer calls: $($razer.Count) $(if ($razer.Count) { 'first at ' + $razer[0].ms + 'ms' }); a lazy prime never fires when no segment state is entered"
}
# Solid states on a segment-capable device must go out as uniform segment CSVs, not
# DeviceColorControl: a Color write kills DreamView on H6066 panels, so the Color
# path would make every solid state cost a re-engagement dwell on the next effect.
if ($cols.Count -eq 0 -and $segs.Count -ge 1) {
    Ok 'solid state rendered as uniform segment CSVs, zero Color writes' "$($segs.Count) segment writes"
} else {
    No 'solid state rendered as uniform segment CSVs, zero Color writes' `
       "color: $($cols.Count), segments: $($segs.Count)"
}

# ------------------------------------------------- T2 jump-cut transitions
Section 'Transitions into a segment state jump-cut instead of cross-fading'
# Dwell off, pacing off: isolates the blend behaviour. Without the fix the 400ms fade
# interpolates a fresh CSV every 20ms tick (~15+ distinct); with it, only pure chase
# frames go out (1-2 distinct across 400ms at Hz 0.2).
$r = Invoke-Emits $cfgDefault 'ToolOther:600,ToolShell:1000' @()
$rows = ConvertFrom-EmitLines $r.lines
$f2 = @($rows | Where-Object { $_.call -eq 'force' -and $_.device -eq 'ToolShell' })
if ($f2.Count -eq 1) {
    $t0 = $f2[0].ms
    $inFade = @($rows | Where-Object { $_.call -eq 'segments' -and $_.ms -ge $t0 -and $_.ms -lt ($t0 + 400) })
    $distinct = @($inFade | ForEach-Object { $_.detail } | Sort-Object -Unique)
    if ($distinct.Count -le 3) {
        Ok 'fade window carries only pure target CSVs' "$($inFade.Count) writes, $($distinct.Count) distinct CSVs"
    } else {
        No 'fade window carries only pure target CSVs' `
           "$($distinct.Count) distinct CSVs in the 400ms fade window - blended segment frames are the 25/s burst that wedges the strip"
    }
} else {
    No 'fade window carries only pure target CSVs' "force marker for ToolShell not found ($($f2.Count))"
}

# ------------------------------------------------- T3 segment write pacing
Section 'Segment writes are paced by MinSegmentIntervalMs'
$cfgPaced = Write-TestConfig 'paced' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 250; SegmentEngageMs = 0; SegmentRePrimeSeconds = 300
}
$r = Invoke-Emits $cfgPaced 'ToolWeb:1300' @()
$rows = ConvertFrom-EmitLines $r.lines
$segs = @($rows | Where-Object { $_.call -eq 'segments' -and $_.ms -gt 100 })
if ($segs.Count -ge 3) {
    $gaps = @(); for ($i = 1; $i -lt $segs.Count; $i++) { $gaps += ($segs[$i].ms - $segs[$i-1].ms) }
    $minGap = ($gaps | Measure-Object -Minimum).Minimum
    if ($minGap -ge 210) {
        Ok 'rainbow writes gapped >= interval' ("$($segs.Count) writes, min gap $([math]::Round($minGap))ms")
    } else {
        No 'rainbow writes gapped >= interval' `
           "min gap $([math]::Round($minGap))ms with MinSegmentIntervalMs=250 - unpaced rainbow is the sustained flood that wedges the strip"
    }
} else {
    No 'rainbow writes gapped >= interval' "only $($segs.Count) segment writes recorded"
}

# ------------------------------------------- T4 engagement dwell after prime
Section 'Segment writes wait out the DreamView engagement dwell'
$cfgDwell = Write-TestConfig 'dwell' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 600; SegmentRePrimeSeconds = 300
}
# The dwell fallback must itself be a SEGMENT write (uniform CSV): DeviceColorControl
# knocks H6066 panels out of DreamView (camera kill-test 2026-08-16), so a Color-based
# dwell murders the very engagement it is waiting for. A uniform CSV pre-engagement
# flattens to exactly itself - same look, mode survives.
function Test-UniformCsv($detail) {
    $csv = ($detail -split '\|')[0]
    $cells = @($csv -split ',' | Sort-Object -Unique)
    return $cells.Count -eq 1
}
$r = Invoke-Emits $cfgDwell 'ToolShell:1300' @()
$rows = ConvertFrom-EmitLines $r.lines
$razer = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
if ($razer.Count -ge 1) {
    $p0 = $razer[0].ms
    $inDwell = @($rows | Where-Object { $_.call -eq 'segments' -and $_.ms -lt ($p0 + 500) })
    $varied  = @($inDwell | Where-Object { -not (Test-UniformCsv $_.detail) })
    $colors  = @($rows | Where-Object { $_.call -eq 'color' -and $_.ms -ge $p0 })
    $late    = @($rows | Where-Object { $_.call -eq 'segments' -and $_.ms -ge ($p0 + 550) } |
                Where-Object { -not (Test-UniformCsv $_.detail) })
    if ($varied.Count -eq 0 -and $inDwell.Count -ge 1) {
        Ok 'dwell carries only uniform segment CSVs' "$($inDwell.Count) uniform writes"
    } else {
        No 'dwell carries only uniform segment CSVs' `
           "$($varied.Count) varied of $($inDwell.Count) segment writes inside the dwell"
    }
    if ($colors.Count -eq 0) { Ok 'no Color writes after the prime' }
    else { No 'no Color writes after the prime' "$($colors.Count) color writes - DeviceColorControl kills DreamView on H6066 panels" }
    if ($late.Count -ge 1) { Ok 'varied segment writes begin after the dwell' ("first at " + $late[0].ms + "ms") }
    else { No 'varied segment writes begin after the dwell' 'none seen' }
} else {
    No 'dwell carries only uniform segment CSVs' 'no razer prime recorded at all'
    No 'no Color writes after the prime' 'no razer prime recorded at all'
    No 'varied segment writes begin after the dwell' 'no razer prime recorded at all'
}

# ------------------------------- T7 the prime survives solid states entirely
Section 'Solid interludes neither send Color nor cost a re-engagement'
# Since solids ride the segments path on segment-capable devices, the prime never
# dies mid-session: after a solid interlude the next effect resumes varied segment
# writes immediately - no Color, no extra razer, no dwell.
$cfgKill = Write-TestConfig 'colorkill' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 100; SegmentRePrimeSeconds = 300
}
$r = Invoke-Emits $cfgKill 'ToolShell:700,ToolOther:600,ToolShell:700' @()
$rows = ConvertFrom-EmitLines $r.lines
$razer  = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
$colors = @($rows | Where-Object { $_.call -eq 'color' })
$f3 = @($rows | Where-Object { $_.call -eq 'force' -and $_.device -eq 'ToolShell' } | Select-Object -Last 1)
$resumed = @($rows | Where-Object { $_.call -eq 'segments' -and $f3 -and $_.ms -ge $f3.ms -and $_.ms -lt ($f3.ms + 400) } |
            Where-Object { -not (Test-UniformCsv $_.detail) })
if ($colors.Count -eq 0 -and $razer.Count -eq 1 -and $resumed.Count -ge 1) {
    Ok 'no Color, no re-prime, varied segments resume immediately' `
       ("varied resume at " + [math]::Round($resumed[0].ms) + "ms, " + $razer.Count + " razer total")
} else {
    No 'no Color, no re-prime, varied segments resume immediately' `
       "color: $($colors.Count), razer: $($razer.Count), varied within 400ms of re-entry: $($resumed.Count)"
}

# --------------------------------------------- T5 re-prime after segment idle
Section 'Re-prime when entering segments after idle'
$cfgIdle = Write-TestConfig 'reprime' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 100; SegmentRePrimeSeconds = 1
}
$r = Invoke-Emits $cfgIdle 'ToolShell:800,ToolOther:1400,ToolShell:700' @()
$rows = ConvertFrom-EmitLines $r.lines
$razer = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
$f3 = @($rows | Where-Object { $_.call -eq 'force' -and $_.device -eq 'ToolShell' } | Select-Object -Last 1)
if ($razer.Count -ge 2 -and $f3 -and $razer[-1].ms -ge ($f3.ms - 50)) {
    Ok 're-primed on segment re-entry after idle' ("razer at " + (($razer | ForEach-Object { [math]::Round($_.ms) }) -join ', ') + "ms")
} else {
    No 're-primed on segment re-entry after idle' `
       "razer count $($razer.Count) - a device power-cycled during the idle gap has DreamView off and a stale prime flag"
}

# ------------------------------------- T5b periodic re-prime during active use
Section 'Re-prime periodically while segments are flowing'
# DreamView engagement decays after minutes even under continuous segment writes
# (camera-verified: a chase rendered right after a prime and was flat minutes later
# with identical traffic). An idle-gated re-prime never fires during active use, so
# the prime must refresh on a period.
$cfgPeriodic = Write-TestConfig 'periodic' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 100; SegmentRePrimeSeconds = 2
}
$r = Invoke-Emits $cfgPeriodic 'ToolShell:6500' @()
$rows = ConvertFrom-EmitLines $r.lines
$razer = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
if ($razer.Count -ge 3) {
    $gaps = @(); for ($i = 1; $i -lt $razer.Count; $i++) { $gaps += ($razer[$i].ms - $razer[$i-1].ms) }
    Ok 'razer refreshed on the configured period' `
       ("$($razer.Count) primes, gaps " + (($gaps | ForEach-Object { [math]::Round($_/100)/10 }) -join ', ') + "s")
} else {
    No 'razer refreshed on the configured period' `
       "$($razer.Count) prime(s) across 6.5s with SegmentRePrimeSeconds=2 - engagement expires mid-use and every segment write flattens"
}

# ------------------------------------- T6 roster resync preserves prime state
Section 'SyncDevices carries runtime state across rebuilds'
$cfgSync = Write-TestConfig 'resync' @{
    TickMs = 20; IdleTickMs = 20; MinDeviceIntervalMs = 20; MaxCallsPerSecGlobal = 500
    KeepaliveSeconds = 300; TransitionMs = 0; RgbQuantize = 3
    MinSegmentIntervalMs = 0; SegmentEngageMs = 100; SegmentRePrimeSeconds = 300
}
$r = Invoke-Emits $cfgSync 'ToolShell:1500' @('--resync-at', '700')
$rows = ConvertFrom-EmitLines $r.lines
$razer = @($rows | Where-Object { $_.call -eq 'razer' -and $_.detail -eq 'on' })
if ($razer.Count -eq 1) {
    Ok 'config-reload resync does not re-prime an engaged device' 'exactly one razer call'
} else {
    No 'config-reload resync does not re-prime an engaged device' `
       "$($razer.Count) razer calls - losing RazerPrimed on resync restarts the 5s engagement dwell on every config save"
}

Write-Host ''
Write-Host ("=== {0} passed, {1} failed ===" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $fail
