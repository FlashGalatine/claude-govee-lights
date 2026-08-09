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
