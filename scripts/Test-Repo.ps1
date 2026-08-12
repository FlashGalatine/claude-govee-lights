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
    $effects = @('solid','breathe','pulse','blink','chase','comet')

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
                # Task 4 adds wipe, progress, sparkle and rainbow - wipe/progress/rainbow are
                # spatial and sparkle paints per segment too, so extend $spatial then.
                $spatial = @('chase','comet')
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

    # Goldens.
    foreach ($e in $effects) {
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
}

# --------------------------------------------------------------- housekeeping
Section 'Housekeeping'
$gitignore = Get-Content (Join-Path $root '.gitignore') -Raw -ErrorAction SilentlyContinue
if ($gitignore -match 'Govee-API-GUID\.txt') { Ok '.gitignore excludes the API GUID' }
else { No '.gitignore excludes the API GUID' 'The GUID is a credential.' }

if (Test-Path (Join-Path $root 'LICENSE')) { Ok 'LICENSE present' } else { No 'LICENSE present' }
if (Test-Path (Join-Path $root 'docs/API-NOTES.md')) { Ok 'docs/API-NOTES.md present' } else { No 'docs/API-NOTES.md present' }

Write-Host ''
Write-Host ("=== $pass passed, $fail failed ===") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
if ($fail -gt 0) { exit 1 } else { exit 0 }
