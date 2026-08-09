<#
.SYNOPSIS
    Slow, narrated visual test across every LAN-enabled Govee device.

.DESCRIPTION
    Each step is announced before it fires and held long enough to watch. Also A/B
    tests the two genuinely ambiguous parameters - isGradientOff and the Razer
    switch - which only a human eye can settle, since both return 0 either way.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Demo-Govee.ps1
#>
[CmdletBinding()]
param(
    [double] $Hold = 2.5,       # seconds to hold each colour
    [int]    $Brightness = 85
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GoveeShim.ps1')

function Step($n, $text, $colour) {
    Write-Host ''
    Write-Host ("  [{0}] {1}" -f $n, $text) -ForegroundColor $colour
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor DarkCyan
Write-Host '  GOVEE VISUAL TEST - look at your lights now' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor DarkCyan

$g = New-GoveeClient
$all = $g.DeviceList()
$lan = @($all | Where-Object { $_.IsLANOn -eq 1 })

Write-Host ''
Write-Host "  Driving $($lan.Count) LAN-enabled device(s):" -ForegroundColor Gray
$lan | ForEach-Object { Write-Host ("    - {0}  ({1} segments)" -f $_.Name, $_.SegmentNums) -ForegroundColor Gray }

# Every command goes to every LAN device so the whole room moves together.
function All-Do([scriptblock] $Action) {
    foreach ($d in $lan) { & $Action $d | Out-Null }
}

Write-Host ''
Write-Host '  Starting in 3 seconds...' -ForegroundColor DarkGray
Start-Sleep -Seconds 3

# --- 1. on + brightness ---------------------------------------------------------
Step 1 "Switching everything ON at $Brightness% brightness" 'White'
All-Do { param($d) $g.Switch($d.Name, 1) }
Start-Sleep -Milliseconds 400
All-Do { param($d) $g.Brightness($d.Name, $Brightness) }
Start-Sleep -Seconds 1

# --- 2. primary colours ---------------------------------------------------------
$colours = @(
    @{ n = 'RED';    r = 255; g = 0;   b = 0   ; c = 'Red' }
    @{ n = 'GREEN';  r = 0;   g = 255; b = 0   ; c = 'Green' }
    @{ n = 'BLUE';   r = 0;   g = 40;  b = 255 ; c = 'Blue' }
    @{ n = 'PURPLE'; r = 123; g = 77;  b = 255 ; c = 'Magenta' }
    @{ n = 'AMBER';  r = 255; g = 176; b = 0   ; c = 'Yellow' }
)
foreach ($c in $colours) {
    Step 2 "Whole-device colour: $($c.n)" $c.c
    All-Do { param($d) $g.Color($d.Name, $c.r, $c.g, $c.b) }
    Start-Sleep -Seconds $Hold
}

# --- 3. breathe (proves daemon-driven animation is smooth) ----------------------
Step 3 'Breathing purple - this is what "thinking" will look like' 'Magenta'
Write-Host '      (daemon-computed animation; the API has no effects of its own)' -ForegroundColor DarkGray
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 6) {
    $phase = [math]::Sin($sw.Elapsed.TotalSeconds * 2 * [math]::PI * 0.5)
    $k = 0.35 + 0.65 * (($phase + 1) / 2)
    $r = [int](123 * $k); $gg = [int](77 * $k); $b = [int](255 * $k)
    All-Do { param($d) $g.Color($d.Name, $r, $gg, $b) }
    Start-Sleep -Milliseconds 60
}

# --- 4. fast pulse (the "needs your attention" state) --------------------------
Step 4 'Fast amber pulse - this is the "waiting for your permission" state' 'Yellow'
for ($i = 0; $i -lt 8; $i++) {
    All-Do { param($d) $g.Color($d.Name, 255, 176, 0) }
    Start-Sleep -Milliseconds 160
    All-Do { param($d) $g.Color($d.Name, 25, 15, 0) }
    Start-Sleep -Milliseconds 160
}

# --- 5. segments: the two ambiguous flags --------------------------------------
$segDevices = @($lan | Where-Object { $_.SegmentNums -gt 1 })
if ($segDevices.Count -gt 0) {

    Step 5 'Enabling Razer/DreamView mode (required for per-segment colour)' 'Cyan'
    foreach ($d in $segDevices) { $g.Razer($d.Name, 1) | Out-Null }
    Start-Sleep -Milliseconds 600
    $g.DevicesJson() | Out-Null      # docs: re-sync before segment sends
    Start-Sleep -Milliseconds 400

    function Rainbow([int] $n) {
        (0..($n - 1) | ForEach-Object {
            $h = ($_ / [double]$n) * 360.0
            $x = [int](255 * (1 - [math]::Abs((($h / 60.0) % 2) - 1)))
            switch ([int][math]::Floor($h / 60.0) % 6) {
                0 { '#FF{0:X2}00' -f $x } 1 { '#{0:X2}FF00' -f $x }
                2 { '#00FF{0:X2}' -f $x } 3 { '#00{0:X2}FF' -f $x }
                4 { '#{0:X2}00FF' -f $x } 5 { '#FF00{0:X2}' -f $x }
            }
        }) -join ','
    }

    Write-Host ''
    Write-Host '  >>> POLARITY TEST - which of these two looks BLENDED vs HARD-EDGED?' -ForegroundColor Yellow

    Step '5a' 'Rainbow with isGradientOff = 1' 'Cyan'
    foreach ($d in $segDevices) { $g.Segments($d.Name, (Rainbow $d.SegmentNums), 1) | Out-Null }
    Start-Sleep -Seconds 4

    Step '5b' 'Rainbow with isGradientOff = 0' 'Cyan'
    foreach ($d in $segDevices) { $g.Segments($d.Name, (Rainbow $d.SegmentNums), 0) | Out-Null }
    Start-Sleep -Seconds 4

    # --- 6. chase ---------------------------------------------------------------
    Step 6 'Segment chase - this is what "running a tool" will look like' 'Green'
    for ($pass = 0; $pass -lt 3; $pass++) {
        $maxSeg = ($segDevices | Measure-Object -Property SegmentNums -Maximum).Maximum
        for ($i = 0; $i -lt $maxSeg; $i++) {
            foreach ($d in $segDevices) {
                $n = [int]$d.SegmentNums
                $pos = [int]($i * $n / $maxSeg)
                $cells = (0..($n - 1) | ForEach-Object {
                    $dist = [math]::Abs($_ - $pos)
                    if     ($dist -eq 0) { '#FF7A18' }
                    elseif ($dist -eq 1) { '#5A2B08' }
                    elseif ($dist -eq 2) { '#1A0C02' }
                    else                 { '#000000' }
                }) -join ','
                $g.Segments($d.Name, $cells, 0) | Out-Null
            }
            Start-Sleep -Milliseconds 70
        }
    }
} else {
    Write-Host ''
    Write-Host '  (No multi-segment LAN devices; skipping segment tests.)' -ForegroundColor DarkGray
}

# --- 7. rest --------------------------------------------------------------------
Step 7 'Settling to a warm resting colour' 'DarkYellow'
All-Do { param($d) $g.Color($d.Name, 255, 217, 160) }
Start-Sleep -Milliseconds 300
All-Do { param($d) $g.Brightness($d.Name, 60) }

Write-Host ''
Write-Host '=========================================================' -ForegroundColor DarkCyan
Write-Host '  Done.' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Please report:' -ForegroundColor White
Write-Host '    1. Did the colours change at all?' -ForegroundColor Gray
Write-Host '    2. Did step 5a or 5b look blended (gradient) vs hard-edged?' -ForegroundColor Gray
Write-Host '    3. Did the chase in step 6 actually move across the segments?' -ForegroundColor Gray
Write-Host ''
