<#
.SYNOPSIS
    Static checks that need no Govee hardware. Run locally or in CI.

.DESCRIPTION
    CI cannot drive lights - it has no Govee Desktop and no devices. What it CAN do is
    guard the invariants that actually broke during development:

      * the App.config bindingRedirect surviving into build output. Losing it does not
        fail the build; it makes every Govee call time out at runtime while reporting a
        bogus "API GUID error". That is the single most expensive way this project can
        regress, and it is invisible to a compiler.
      * hooks.json staying in sync with the scripts and port it references.
      * every PowerShell script still parsing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
#>
[CmdletBinding()]
param([switch] $SkipBuildOutput)

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

Write-Host ''
Write-Host '=== Repository checks ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- JSON validity
Section 'JSON'
$jsonFiles = @(
    '.claude-plugin/plugin.json',
    '.claude-plugin/marketplace.json',
    'hooks/hooks.json',
    'config/config.example.json'
)
$parsed = @{}
foreach ($rel in $jsonFiles) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { No "$rel exists"; continue }
    try {
        $parsed[$rel] = Get-Content $p -Raw | ConvertFrom-Json
        Ok "$rel parses"
    } catch {
        No "$rel parses" $_.Exception.Message
    }
}

# ------------------------------------------------------------- plugin manifest
Section 'Plugin manifest'
if ($parsed['.claude-plugin/plugin.json'] -and $parsed['.claude-plugin/marketplace.json']) {
    $pluginName = $parsed['.claude-plugin/plugin.json'].name
    $marketName = $parsed['.claude-plugin/marketplace.json'].plugins[0].name
    if ($pluginName -eq $marketName) { Ok 'plugin.json and marketplace.json agree on the name' "'$pluginName'" }
    else { No 'plugin.json / marketplace.json name mismatch' "'$pluginName' vs '$marketName'" }

    if ($parsed['.claude-plugin/plugin.json'].version) { Ok 'plugin.json declares a version' $parsed['.claude-plugin/plugin.json'].version }
    else { No 'plugin.json declares a version' }
}

# ---------------------------------------------------------------------- hooks
Section 'Hooks'
$hooksPath = Join-Path $root 'hooks/hooks.json'
if ($parsed['hooks/hooks.json']) {
    $raw = Get-Content $hooksPath -Raw
    $events = $parsed['hooks/hooks.json'].hooks.PSObject.Properties.Name
    Ok "hooks.json declares $($events.Count) events" ($events -join ', ')

    # Every http URL must target the same loopback port, or some events would
    # silently talk to nothing after a port change.
    # @() matters: a single unique result comes back as a scalar string, and
    # indexing a string yields a character rather than the value.
    $ports = @([regex]::Matches($raw, '127\.0\.0\.1:(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($ports.Count -eq 1) { Ok 'all hook URLs use one port' $ports[0] }
    else { No 'hook URLs disagree on the port' ($ports -join ', ') }

    # Everything must be loopback-only. A non-loopback host would expose the daemon.
    $urlHosts = @([regex]::Matches($raw, '"url"\s*:\s*"http://([^:/"]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if (@($urlHosts | Where-Object { $_ -ne '127.0.0.1' }).Count -eq 0) {
        Ok 'all hook URLs are loopback-only' ($urlHosts -join ', ')
    } else {
        No 'a hook URL is not loopback' ($urlHosts -join ', ')
    }

    # Scripts referenced from command hooks must exist.
    $refs = @([regex]::Matches($raw, '\$\{CLAUDE_PLUGIN_ROOT\}/([^"\\]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    foreach ($r in $refs) {
        if (Test-Path (Join-Path $root $r)) { Ok "referenced script exists" $r }
        else { No "referenced script missing" $r }
    }

    # Regression guard. The daemon idles out, and only a `command` hook can restart it.
    # SessionStart alone is NOT enough: it never fires again inside an already-running
    # session, so a daemon that exited mid-session stayed dead and every subsequent
    # hook returned connection-refused. UserPromptSubmit is the recovery point.
    $bootstrapped = @(
        $parsed['hooks/hooks.json'].hooks.PSObject.Properties |
        Where-Object {
            ($_.Value | ConvertTo-Json -Depth 8 -Compress) -match 'Ensure-Daemon\.ps1'
        } | ForEach-Object { $_.Name }
    )
    foreach ($required in @('SessionStart', 'UserPromptSubmit')) {
        if ($bootstrapped -contains $required) {
            Ok "$required can restart the daemon"
        } else {
            No "$required has no Ensure-Daemon bootstrap" `
               'Without it a daemon that idles out mid-session can never recover.'
        }
    }

    # The example config's port must match, or the docs contradict the wiring.
    if ($parsed['config/config.example.json'] -and $ports.Count -eq 1) {
        $cfgPort = $parsed['config/config.example.json'].Port
        if ("$cfgPort" -eq $ports[0]) { Ok 'config.example.json port matches hooks.json' $cfgPort }
        else { No 'config.example.json port does not match hooks.json' "config=$cfgPort hooks=$($ports[0])" }
    }
}

# ------------------------------------------------------------------- commands
Section 'Slash commands'
$cmd = Join-Path $root 'commands/govee.md'
if (Test-Path $cmd) {
    $c = Get-Content $cmd -Raw
    if ($c -match '(?s)^---.*?---') { Ok 'commands/govee.md has frontmatter' }
    else { No 'commands/govee.md has frontmatter' }

    foreach ($m in [regex]::Matches($c, '\$\{CLAUDE_PLUGIN_ROOT\}/([^"\s`]+\.ps1)')) {
        $rel = $m.Groups[1].Value
        if (Test-Path (Join-Path $root $rel)) { Ok 'command references an existing script' $rel }
        else { No 'command references a missing script' $rel }
    }
} else { No 'commands/govee.md exists' }

# ---------------------------------------------------------- PowerShell parsing
Section 'PowerShell syntax'
$scripts = Get-ChildItem (Join-Path $root 'scripts') -Filter *.ps1 -File
foreach ($s in $scripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        No "$($s.Name) parses" ($errors[0].Message)
    } else {
        Ok "$($s.Name) parses"
    }
}

# ------------------------------------------------- THE binding redirect check
Section 'Binding redirect (the runtime-critical invariant)'
$appConfig = Join-Path $root 'src/GoveeLights.Daemon/App.config'
function Test-Redirect($path, $label) {
    if (-not (Test-Path $path)) { No "$label exists" $path; return }
    try {
        $x = [xml](Get-Content $path -Raw)
        $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
        $ns.AddNamespace('a', 'urn:schemas-microsoft-com:asm.v1')
        $node = $x.SelectSingleNode("//a:dependentAssembly[a:assemblyIdentity/@name='System.Runtime.CompilerServices.Unsafe']", $ns)
        if (-not $node) {
            No "$label has the Unsafe bindingRedirect" 'Without it every Govee call times out and misreports as error 1001.'
            return
        }
        $new = $node.bindingRedirect.newVersion
        if ($new -eq '6.0.0.0') { Ok "$label redirects Unsafe to 6.0.0.0" }
        else { No "$label redirects Unsafe to the wrong version" "newVersion=$new, expected 6.0.0.0" }
    } catch {
        No "$label is valid XML" $_.Exception.Message
    }
}
Test-Redirect $appConfig 'App.config'

if (-not $SkipBuildOutput) {
    $built = @(
        (Join-Path $root 'dist/daemon/GoveeLightsDaemon.exe.config'),
        (Join-Path $root 'src/GoveeLights.Daemon/bin/Release/net48/GoveeLightsDaemon.exe.config'),
        (Join-Path $root 'src/GoveeLights.Daemon/bin/Debug/net48/GoveeLightsDaemon.exe.config')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($built) { Test-Redirect $built 'built exe.config' }
    else { Write-Host '  SKIP  no build output found (run scripts\Build.ps1)' -ForegroundColor DarkGray }
}

# ------------------------------------------------- cold-start roster recovery
Section 'Cold-start roster recovery'
# Govee Desktop reports every device as IsLANOn:0 for ~48s after launch (docs/API-NOTES.md),
# so a daemon started alongside it reads an empty roster. Both halves of the recovery fail
# SILENTLY when removed - nothing errors, the lights just never come on until someone runs
# /govee refresh:
#   * without the retry, that first empty roster is cached for the life of the process;
#   * without the callback, a retry updates Devices and rebuilds nothing observable.
$clientCs = Join-Path $root 'src/GoveeLights.Daemon/GoveeClient.cs'
$programCs = Join-Path $root 'src/GoveeLights.Daemon/Program.cs'

if (Test-Path $clientCs) {
    $cs = Get-Content $clientCs -Raw
    if ($cs -match 'ScheduleDeviceRetry') {
        Ok 'GoveeClient re-reads a roster with no LAN-capable devices'
    } else {
        No 'GoveeClient has no roster retry' `
           'A cold-start roster of all-IsLANOn:0 would be cached until the daemon restarts.'
    }

    if ($cs -match 'DevicesLoaded') {
        Ok 'GoveeClient exposes a DevicesLoaded callback'
    } else {
        No 'GoveeClient has no DevicesLoaded callback' `
           'A late roster would have no way to reach the renderer.'
    }
} else { No 'GoveeClient.cs exists' $clientCs }

if (Test-Path $programCs) {
    $ps = Get-Content $programCs -Raw
    if ($ps -match 'DevicesLoaded[^\r\n]*SyncDevices') {
        Ok 'Program wires DevicesLoaded to Renderer.SyncDevices'
    } else {
        No 'Program does not wire DevicesLoaded to the renderer' `
           'Retries would refresh Devices and change nothing the lights can show.'
    }
} else { No 'Program.cs exists' $programCs }

# ------------------------------------------------------- effects engine
Section 'Effects engine'
# Effects is pure and deterministic, so CI can assert on real render output with no
# hardware. The goldens are the regression net for the pipeline refactor: any change
# to the six original effects' output is a bug unless it is deliberate.
$exe = @(
    (Join-Path $root 'dist/daemon/GoveeLightsDaemon.exe'),
    (Join-Path $root 'src/GoveeLights.Daemon/bin/Release/net48/GoveeLightsDaemon.exe'),
    (Join-Path $root 'src/GoveeLights.Daemon/bin/Debug/net48/GoveeLightsDaemon.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Quote-DumpArg([string] $a) {
    # Start-Process's array-form -ArgumentList does not escape embedded double quotes
    # (Windows PowerShell 5.1 joins the array with spaces and lets CreateProcess's
    # argv parser see the raw '"' characters), which corrupts the JSON --style payload
    # before the daemon ever reads it. Build the command line by hand instead.
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Invoke-Dump {
    param([string[]] $DumpArgs)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # Start-Process, not '&': the daemon is a WinExe, so stdout must be explicitly
        # redirected for the parent to see anything.
        $cmdLine = ((@('--dump-frames') + $DumpArgs) | ForEach-Object { Quote-DumpArg $_ }) -join ' '
        Start-Process -FilePath $exe -ArgumentList $cmdLine `
            -NoNewWindow -Wait -RedirectStandardOutput $tmp | Out-Null
        return @(Get-Content $tmp)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

if (-not $exe) {
    Write-Host '  SKIP  no build output found (run scripts\Build.ps1)' -ForegroundColor DarkGray
} else {
    $effects = @('solid','breathe','pulse','blink','chase','comet','wipe','progress','sparkle','rainbow')
    $golden  = @('solid','breathe','pulse','blink','chase','comet')

    # Renders at all three segment shapes: 1 (whole-device), 3 (short strip), 10 (typical).
    foreach ($e in $effects) {
        $bad = $false
        foreach ($n in 1, 3, 10) {
            $lines = Invoke-Dump @('--style', "{`"Color`":`"#3366CC`",`"Effect`":`"$e`",`"Hz`":0.6}",
                                   '--segments', "$n", '--seconds', '0.4')
            $rows = @($lines | Where-Object { $_ -notmatch '^#' -and $_ })
            if ($rows.Count -lt 1) { $bad = $true; break }
            foreach ($r in $rows) {
                $cells = $r.Split(',')[1..($r.Split(',').Count - 1)]
                # chase and comet paint per segment; the rest render one whole-device cell via
                # Effects.Whole(), which deliberately skips the segment array because
                # DeviceColorControl is cheaper for uniform colour. Spatial effects fall back to
                # breathe at one segment, so they collapse to a single cell there too.
                # This is "paints per segment", which is deliberately not the same list as
                # Palette.IsSpatial: sparkle paints per segment but is not spatial, because at
                # one segment it reads fine as a random blink and needs no breathe fallback.
                $spatial = @('chase','comet','wipe','progress','sparkle','rainbow')
                $wantCells = if (($spatial -contains $e) -and $n -gt 1) { $n } else { 1 }
                if ($cells.Count -ne $wantCells) { $bad = $true; break }
                foreach ($c in $cells) { if ($c -notmatch '^#[0-9A-F]{6}$') { $bad = $true; break } }
            }
        }
        if ($bad) { No "$e renders at 1, 3 and 10 segments" } else { Ok "$e renders at 1, 3 and 10 segments" }
    }

    # Determinism. Without it the goldens below are meaningless and sparkle (Task 4)
    # would strobe differently on every frame.
    $a = Invoke-Dump @('--style','{"Color":"#3366CC","Effect":"chase","Hz":0.6}','--segments','10','--seconds','1')
    $b = Invoke-Dump @('--style','{"Color":"#3366CC","Effect":"chase","Hz":0.6}','--segments','10','--seconds','1')
    if (($a -join "`n") -eq ($b -join "`n")) { Ok 'identical inputs produce identical frames' }
    else { No 'render output is not deterministic' 'Goldens and sparkle both depend on this.' }

    # Goldens. Only the six original effects have golden files.
    foreach ($e in $golden) {
        $goldenPath = Join-Path $root "tests/golden/$e.csv"
        if (-not (Test-Path $goldenPath)) { No "golden exists for $e" $goldenPath; continue }
        $got = Invoke-Dump @('--style', "{`"Color`":`"#3366CC`",`"Effect`":`"$e`",`"Hz`":0.6}",
                             '--segments','10','--seconds','4','--fps','25')
        $want = @(Get-Content $goldenPath)
        if (($got -join "`n") -eq ($want -join "`n")) { Ok "$e matches its golden frames" }
        else { No "$e output changed" "Compare against tests/golden/$e.csv" }
    }

    # The bug this whole refactor exists to fix: an entry that sets only Hz used to be
    # discarded wholesale because it carried no Color - the deleted Palette.For guard
    # keyed on Color being present. Neither style below sets Color, so both fall back to
    # the same grey; any frame difference can only come from Hz being honoured. The
    # header line is stripped from both sides first, since it echoes "hz=2" vs "hz=0.6"
    # regardless of whether Effects.Render ever reads style.Hz.
    $partial = @(Invoke-Dump @('--style','{"Effect":"breathe","Hz":2.0}','--segments','1','--seconds','1')) -notmatch '^#'
    $full    = @(Invoke-Dump @('--style','{"Effect":"breathe","Hz":0.6}','--segments','1','--seconds','1')) -notmatch '^#'
    if (($partial -join "`n") -ne ($full -join "`n")) { Ok 'Hz is honoured independently of other fields' }
    else { No 'Hz had no effect' 'Partial overrides are being discarded.' }

    # Depth is an inherited effect default, not a per-state one: breathe's resolved style
    # must carry Depth=0.35 even though no state specifies it. This checks the resolved
    # header field rather than rendered brightness, since Effects.Render does not read
    # style.Depth yet (Task 3 wires that up) - the 0.35 breathe floor in the maths today
    # is still a literal, so measuring rendered output here would pass even if
    # EffectDefaults's breathe entry were deleted.
    $b = Invoke-Dump @('--style','{"Effect":"breathe","Hz":0.6,"Color":"#FFFFFF"}','--segments','1','--seconds','2')
    if (($b | Where-Object { $_ -match '^#' }) -match 'depth=0\.35') { Ok 'breathe inherits its 0.35 depth floor' }
    else { No 'breathe did not inherit its depth floor' (($b | Where-Object { $_ -match '^#' })) }

    # Direction is an array transform, so reverse must be an exact mirror of forward. A
    # field-count guard and a genuine-difference check keep this from passing vacuously
    # if frames ever collapsed to a single colour column (the Finding-1 bug class: that
    # collapse would make forward and reverse trivially identical single-cell rows).
    $fwd = Invoke-Dump @('--style','{"Effect":"chase","Hz":0.6,"Color":"#3366CC","Direction":"forward"}','--segments','10','--seconds','1')
    $rev = Invoke-Dump @('--style','{"Effect":"chase","Hz":0.6,"Color":"#3366CC","Direction":"reverse"}','--segments','10','--seconds','1')
    $mirrorOk = $true
    $sawFullWidth = $true
    $sawDifference = $false
    $fwdRows = @($fwd | Where-Object { $_ -notmatch '^#' -and $_ })
    $revRows = @($rev | Where-Object { $_ -notmatch '^#' -and $_ })
    if ($fwdRows.Count -ne $revRows.Count -or $fwdRows.Count -eq 0) { $mirrorOk = $false }
    else {
        for ($i = 0; $i -lt $fwdRows.Count; $i++) {
            $f = $fwdRows[$i].Split(','); $r = $revRows[$i].Split(',')
            if ($f.Count -le 2 -or $r.Count -le 2) { $sawFullWidth = $false; break }
            $fc = $f[1..($f.Count-1)]; $rc = $r[1..($r.Count-1)]
            if (($fc -join ',') -ne ($rc -join ',')) { $sawDifference = $true }
            [array]::Reverse($rc)
            if (($fc -join '') -ne ($rc -join '')) { $mirrorOk = $false; break }
        }
    }
    if (-not $sawFullWidth) { No 'reverse test rows collapsed to fewer than 10 cells' }
    elseif (-not $sawDifference) { No 'forward and reverse never differed' 'A collapsed frame would pass vacuously.' }
    elseif ($mirrorOk) { Ok 'Direction reverse is the exact mirror of forward' }
    else { No 'reverse is not a mirror of forward' }

    # Depth must floor the output at depth * colour, and must not also cap the ceiling -
    # asserting only the minimum would pass for a shape stuck flat at 0.5.
    $d = Invoke-Dump @('--style','{"Effect":"blink","Hz":2.0,"Color":"#FFFFFF","Depth":0.5}','--segments','1','--seconds','2')
    $dv = @($d | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        [Convert]::ToInt32($_.Split(',')[1].Substring(1,2), 16) })
    $dmin = ($dv | Measure-Object -Minimum).Minimum
    $dmax = ($dv | Measure-Object -Maximum).Maximum
    if ($dmin -ge 126 -and $dmin -le 129 -and $dmax -ge 253) {
        Ok 'Depth floors the output' "min channel $dmin, max channel $dmax"
    } else { No 'Depth floor not applied' "min channel $dmin (want ~128), max channel $dmax (want ~255)" }

    # Color2 replaces "scale toward black" with a blend between two colours, so the
    # dimmest frame should be Color2 rather than near-black, and the brightest should
    # still be Color - asserting only the low end would pass for a Mix that always
    # returned Color2. Depth is pinned to 0: blink defaults to Depth 0.06, which would
    # lift the low end off Color2 exactly.
    $c2 = Invoke-Dump @('--style','{"Effect":"blink","Hz":2.0,"Color":"#FFFFFF","Color2":"#FF0000","Depth":0}','--segments','1','--seconds','2')
    $c2rows = @($c2 | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object { $_.Split(',')[1] })
    $c2u = $c2rows | Sort-Object -Unique
    if (($c2u -contains '#FF0000') -and ($c2u -contains '#FFFFFF')) { Ok 'Color2 is used as the low end of the blend' }
    else { No 'Color2 was not blended' ($c2u -join ' ') }

    # Pingpong must fold time into a genuine bounce, not mirror a circularly wrapping
    # head (Finding 2). A raw "brightest segment index" comparison cannot tell a real
    # bounce from CircularDistance's ordinary once-per-lap ring seam: chase already
    # aliases index (n-1) to index 0 there once a head every lap - forward chase does
    # this too, harmlessly - so an index-jump threshold flags that normal seam crossing
    # exactly as loudly as the bug and cannot tell them apart (confirmed by hand: both
    # the pre-fix and the fixed build show the same raw index jump at the seam).
    #
    # What actually distinguishes a bounce is symmetry: folding time makes tShape retrace
    # itself around the turnaround, so the rendered frames on either side of it must be an
    # exact mirror image of each other - not just "no big jump". Hz is chosen so 1/Hz is a
    # whole number of frames (2 seconds at 25 fps = frame 50), landing the turnaround
    # exactly on a sample instead of between two of them.
    $pp = Invoke-Dump @('--style','{"Effect":"chase","Hz":0.5,"Color":"#3366CC","Direction":"pingpong"}','--segments','10','--seconds','4','--fps','25')
    $ppRows = @($pp | Where-Object { $_ -notmatch '^#' -and $_ })
    $mid = 50
    $ppOk = $ppRows.Count -ge ($mid * 2)
    if ($ppOk) {
        for ($k = 1; $k -lt $mid; $k++) {
            $before = ($ppRows[$mid - $k] -split ',', 2)[1]
            $after  = ($ppRows[$mid + $k] -split ',', 2)[1]
            if ($before -ne $after) { $ppOk = $false; break }
        }
    }
    if ($ppOk) { Ok 'Pingpong is a true mirror image around its turnaround' }
    else { No 'Pingpong does not bounce cleanly at the turnaround' }

    # Easing with no golden coverage: sine and expo must each actually change pulse's
    # output relative to linear for the same effect and Hz.
    $easeLinear = (Invoke-Dump @('--style','{"Effect":"pulse","Hz":0.6,"Color":"#FFFFFF","Easing":"linear"}','--segments','1','--seconds','1')) -notmatch '^#'
    $easeSine   = (Invoke-Dump @('--style','{"Effect":"pulse","Hz":0.6,"Color":"#FFFFFF","Easing":"sine"}','--segments','1','--seconds','1'))   -notmatch '^#'
    $easeExpo   = (Invoke-Dump @('--style','{"Effect":"pulse","Hz":0.6,"Color":"#FFFFFF","Easing":"expo"}','--segments','1','--seconds','1'))   -notmatch '^#'
    if ((($easeSine -join "`n") -ne ($easeLinear -join "`n")) -and (($easeExpo -join "`n") -ne ($easeLinear -join "`n"))) {
        Ok 'sine and expo easing change pulse output'
    } else { No 'easing had no effect on rendered output' }

    # Tail with no golden coverage: a wider Tail must widen comet's falloff, lighting
    # more segments above a brightness threshold in the same (deterministic, t=0) frame.
    $tailNarrow = Invoke-Dump @('--style','{"Effect":"comet","Hz":0.6,"Color":"#FFFFFF","Tail":1.0}','--segments','20','--seconds','0.1')
    $tailWide   = Invoke-Dump @('--style','{"Effect":"comet","Hz":0.6,"Color":"#FFFFFF","Tail":2.5}','--segments','20','--seconds','0.1')
    $narrowRow = @($tailNarrow | Where-Object { $_ -notmatch '^#' -and $_ } | Select-Object -First 1)[0]
    $wideRow   = @($tailWide   | Where-Object { $_ -notmatch '^#' -and $_ } | Select-Object -First 1)[0]
    $narrowAbove = @($narrowRow.Split(',')[1..20] | ForEach-Object { [Convert]::ToInt32($_.Substring(1,2), 16) } | Where-Object { $_ -ge 150 }).Count
    $wideAbove   = @($wideRow.Split(',')[1..20]   | ForEach-Object { [Convert]::ToInt32($_.Substring(1,2), 16) } | Where-Object { $_ -ge 150 }).Count
    if ($wideAbove -gt $narrowAbove) {
        Ok 'Tail widens the comet falloff' "tail=1.0 -> $narrowAbove segments, tail=2.5 -> $wideAbove segments"
    } else { No 'Tail had no effect on comet falloff' "tail=1.0 -> $narrowAbove, tail=2.5 -> $wideAbove" }

    # progress is driven by time-in-state, so it must be monotonically non-decreasing.
    $p = Invoke-Dump @('--style','{"Effect":"progress","Color":"#FFFFFF","FullSeconds":2}','--segments','10','--seconds','3')
    $lit = @($p | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        @($_.Split(',')[1..10] | Where-Object { $_ -ne '#000000' }).Count })
    $mono = $true
    for ($i = 1; $i -lt $lit.Count; $i++) { if ($lit[$i] -lt $lit[$i-1]) { $mono = $false; break } }
    # first=0 is a rise guard: without it, a shape stuck at all-lit from the very first
    # frame is trivially monotonic and trivially ends at 10, so "fills" would never
    # actually be observed to happen.
    if ($mono -and $lit[0] -eq 0 -and $lit[-1] -eq 10) { Ok 'progress fills monotonically and reaches full' }
    else { No 'progress does not fill monotonically to full' "first=$($lit[0]) last=$($lit[-1])" }

    # rainbow must actually span hues rather than painting one colour.
    $rb = Invoke-Dump @('--style','{"Effect":"rainbow","Hz":0.2,"Color":"#FFFFFF"}','--segments','10','--seconds','0.2')
    $first = @($rb | Where-Object { $_ -notmatch '^#' -and $_ })[0].Split(',')[1..10]
    if (@($first | Sort-Object -Unique).Count -ge 8) { Ok 'rainbow spans distinct hues across segments' }
    else { No 'rainbow is not spanning hues' (@($first | Sort-Object -Unique).Count) }

    # ...and its hues must actually advance over time, not just across segments: the
    # previous check inspects row 0 only, so deleting the "t * s.Hz" phase term from
    # Effects.Render's rainbow branch would still pass it.
    $rbTime = Invoke-Dump @('--style','{"Effect":"rainbow","Hz":0.5,"Color":"#FFFFFF"}','--segments','10','--seconds','1')
    $rbRows = @($rbTime | Where-Object { $_ -notmatch '^#' -and $_ })
    $rbFirstRow = ($rbRows[0].Split(',')[1..10]) -join ','
    $rbLastRow  = ($rbRows[-1].Split(',')[1..10]) -join ','
    if ($rbFirstRow -ne $rbLastRow) { Ok 'rainbow hues advance over time' }
    else { No 'rainbow hues do not change over time' 'Deleting the t * s.Hz phase term would still pass the hue-span check.' }

    # wipe has no golden coverage, so give it a direct behavioural check: over one full
    # Hz cycle the lit count must rise from empty to fully lit and fall back to empty,
    # with no discontinuity where the fill phase hands off to the clear phase. Hz and
    # fps are chosen so the midpoint (cycle=0.5) lands exactly on a sampled frame.
    $wp = Invoke-Dump @('--style','{"Effect":"wipe","Hz":0.5,"Color":"#FFFFFF"}','--segments','10','--seconds','2','--fps','20')
    $wpLit = @($wp | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        @($_.Split(',')[1..10] | Where-Object { $_ -ne '#000000' }).Count })
    $half = [int]($wpLit.Count / 2)
    $risesOk = $true
    for ($i = 1; $i -le $half; $i++) { if ($wpLit[$i] -lt $wpLit[$i-1]) { $risesOk = $false; break } }
    $fallsOk = $true
    for ($i = $half + 1; $i -lt $wpLit.Count; $i++) { if ($wpLit[$i] -gt $wpLit[$i-1]) { $fallsOk = $false; break } }
    $peak = ($wpLit | Measure-Object -Maximum).Maximum
    $noJump = $true
    for ($i = 1; $i -lt $wpLit.Count; $i++) { if ([Math]::Abs($wpLit[$i] - $wpLit[$i-1]) -gt 2) { $noJump = $false; break } }
    if ($risesOk -and $fallsOk -and $peak -eq 10 -and $noJump) {
        Ok 'wipe rises to full and falls back with no discontinuity at the midpoint'
    } else {
        No 'wipe fill/clear shape is wrong' "rises=$risesOk falls=$fallsOk peak=$peak(want 10) noJump=$noJump"
    }

    # sparkle is hashed rather than random: same input, same frames. Already covered by
    # the global determinism check, but assert it directly since it is the one effect
    # where non-determinism would be easy to reintroduce.
    $s1 = Invoke-Dump @('--style','{"Effect":"sparkle","Hz":8,"Color":"#FFFFFF"}','--segments','10','--seconds','1')
    $s2 = Invoke-Dump @('--style','{"Effect":"sparkle","Hz":8,"Color":"#FFFFFF"}','--segments','10','--seconds','1')
    if (($s1 -join "`n") -eq ($s2 -join "`n")) { Ok 'sparkle is deterministic' }
    else { No 'sparkle is not deterministic' 'Use the hash, not Random.' }

    # ...and that it actually twinkles. Compare only the cell columns: every row carries a
    # distinct timestamp in column 0, so uniquing whole rows would pass no matter what.
    $spatterns = @($s1 | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        ($_.Split(',')[1..10]) -join '' })
    if (@($spatterns | Sort-Object -Unique).Count -gt 3) { Ok 'sparkle varies over time' }
    else { No 'sparkle output is static' (@($spatterns | Sort-Object -Unique).Count) }

    # ...and it must light a proper subset near the 0.28 threshold, not "all" or "none":
    # the variety check above would still pass a hash that only ever lit 1 of 10 segments,
    # or one that alternated between all-lit and all-dark whole frames. Depth is forced to
    # 0 here (sparkle defaults to 0.06) so an "off" cell renders as literal #000000 - with
    # the default depth every cell is a non-zero shade and this whole check is vacuous.
    $sd = Invoke-Dump @('--style','{"Effect":"sparkle","Hz":8,"Color":"#FFFFFF","Depth":0}','--segments','10','--seconds','1')
    $sdRows = @($sd | Where-Object { $_ -notmatch '^#' -and $_ })
    $sdLitPerRow = @($sdRows | ForEach-Object {
        @($_.Split(',')[1..10] | Where-Object { $_ -ne '#000000' }).Count })
    $sdTotalLit = ($sdLitPerRow | Measure-Object -Sum).Sum
    $sdFraction = $sdTotalLit / ($sdRows.Count * 10)
    $sdMixedRows = @($sdLitPerRow | Where-Object { $_ -gt 0 -and $_ -lt 10 }).Count
    if ($sdFraction -gt 0.15 -and $sdFraction -lt 0.45 -and $sdMixedRows -gt ($sdRows.Count * 0.5)) {
        Ok 'sparkle lights a plausible, proper subset of segments' "lit fraction=$([Math]::Round($sdFraction, 2))"
    } else {
        No 'sparkle lit fraction is not plausible' "lit fraction=$([Math]::Round($sdFraction, 2)), mixed rows=$sdMixedRows/$($sdRows.Count)"
    }

    # Per-device overrides layer on top of the global States map. CeilingStrip pins
    # Thinking to solid while inheriting the colour; DeskStrip inherits everything.
    $fixture = Join-Path $root 'tests/fixtures/device-override.json'
    $ceiling = Invoke-Dump @('--config',$fixture,'--state','Thinking','--device','CeilingStrip','--segments','1','--seconds','1')
    $desk    = Invoke-Dump @('--config',$fixture,'--state','Thinking','--device','DeskStrip','--segments','1','--seconds','1')

    if (($ceiling | Where-Object { $_ -match '^#' }) -match 'effect=solid') { Ok 'device override changes the effect' }
    else { No 'device override was ignored' ($ceiling | Where-Object { $_ -match '^#' }) }

    if (($ceiling | Where-Object { $_ -match '^#' }) -match 'color=#3366CC') { Ok 'device override inherits unset fields' }
    else { No 'device override did not inherit Color' ($ceiling | Where-Object { $_ -match '^#' }) }

    if (($desk | Where-Object { $_ -match '^#' }) -match 'effect=breathe') { Ok 'a device with no override uses the global style' }
    else { No 'unoverridden device did not use the global style' ($desk | Where-Object { $_ -match '^#' }) }

    # A blend must start at the outgoing frame and end at the incoming one.
    $plain = @(Invoke-Dump @('--state','Error','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })
    $blend = @(Invoke-Dump @('--from','Done','--state','Error','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })
    $pureFrom = @(Invoke-Dump @('--state','Done','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })

    if ($blend.Count -eq $plain.Count -and $blend.Count -gt 1) { Ok 'blended dump has the expected frame count' }
    else { No 'blended dump frame count is wrong' "$($blend.Count) vs $($plain.Count)" }

    if ($blend[0] -eq $pureFrom[0]) { Ok 'blend at mix 0 equals the outgoing frame' }
    else { No 'blend at mix 0 is not the outgoing frame' }

    if ($blend[-1] -eq $plain[-1]) { Ok 'blend at mix 1 equals the incoming frame' }
    else { No 'blend at mix 1 is not the incoming frame' }

    # The middle must be neither endpoint, or nothing is actually being blended.
    $mid = $blend[[int]($blend.Count / 2)]
    if ($mid -ne $plain[[int]($blend.Count / 2)] -and $mid -ne $pureFrom[[int]($blend.Count / 2)]) {
        Ok 'blend midpoint differs from both endpoints'
    } else { No 'blend midpoint matches an endpoint' 'Frames are not being mixed.' }

    # Error and Done are both non-spatial (blink and solid collapse to a single
    # whole-device cell), so the checks above never exercise Blend's segment-array path -
    # a Blend that forgot Segments entirely would still pass all four. ToolEdit (chase)
    # and ToolAgent (comet) are both spatial at 10 segments, so this transition must carry
    # a full 10-cell array through the midpoint.
    $spBlend = @(Invoke-Dump @('--from','ToolEdit','--state','ToolAgent','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })
    $spMidCells = $spBlend[[int]($spBlend.Count / 2)].Split(',')
    if ($spMidCells.Count -eq 11) { Ok 'blend midpoint keeps the full segment array for two spatial states' }
    else { No 'blend midpoint lost the segment array' "$($spMidCells.Count) columns (want 11)" }

    # ...and the cells must actually differ across the row - a Blend that lerped only
    # Solid and broadcast it to every cell would still produce 11 columns but with every
    # cell identical, which the column-count check above cannot tell apart from a real
    # per-cell blend.
    $spMidUniqueCells = @($spMidCells[1..10] | Sort-Object -Unique).Count
    if ($spMidUniqueCells -gt 1) { Ok 'blend midpoint cells vary across the segment array' }
    else { No 'blend midpoint cells are uniform' 'Segments may have been broadcast from Solid instead of blended per-cell.' }
}

# Shipping an example config that names an effect the engine does not implement
# would silently render everything as solid.
$known = @('solid','breathe','pulse','blink','chase','comet','wipe','progress','sparkle','rainbow')
if ($parsed['config/config.example.json']) {
    $badEffects = @()
    # Both the live States block and the _examples_states showcase, since a broken
    # example is exactly what a user would copy.
    foreach ($blockName in 'States', '_examples_states') {
        $block = $parsed['config/config.example.json'].$blockName
        if (-not $block) { continue }
        foreach ($p in $block.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $e = $p.Value.Effect
            if ($e -and ($known -notcontains $e)) { $badEffects += "$blockName.$($p.Name)=$e" }
        }
    }
    if ($badEffects.Count -eq 0) { Ok 'config.example.json names only known effects' }
    else { No 'config.example.json names an unknown effect' ($badEffects -join ', ') }
}

# --------------------------------------------------------------- housekeeping
Section 'Housekeeping'
$gitignore = Get-Content (Join-Path $root '.gitignore') -Raw -ErrorAction SilentlyContinue
if ($gitignore -match 'Govee-API-GUID\.txt') { Ok '.gitignore excludes the API GUID' }
else { No '.gitignore excludes the API GUID' 'The GUID is a credential.' }

if (Test-Path (Join-Path $root 'LICENSE')) { Ok 'LICENSE present' } else { No 'LICENSE present' }
if (Test-Path (Join-Path $root 'docs/API-NOTES.md')) { Ok 'docs/API-NOTES.md present' } else { No 'docs/API-NOTES.md present' }
if (Test-Path (Join-Path $root 'docs/EFFECTS.md')) { Ok 'docs/EFFECTS.md present' } else { No 'docs/EFFECTS.md present' }

Write-Host ''
Write-Host ("=== $pass passed, $fail failed ===") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
if ($fail -gt 0) { exit 1 } else { exit 0 }
