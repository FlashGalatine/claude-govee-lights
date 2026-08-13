<#
.SYNOPSIS
    Backend for the /govee slash command.

.EXAMPLE
    .\Govee-Cli.ps1 status
    .\Govee-Cli.ps1 test ToolShell
    .\Govee-Cli.ps1 off
    .\Govee-Cli.ps1 set Thinking --color #FF0000 --hz 2
    .\Govee-Cli.ps1 theme apply muted
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'status',
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest,
    [int] $Port = 17321
)

$ErrorActionPreference = 'Continue'
$base = "http://127.0.0.1:$Port"
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Style fields, and how each is coerced before it goes on the wire. The daemon
# validates too - this exists so a typo fails here with a readable message instead
# of as a 400 from a route.
$StyleFields = @{
    'color'       = 'string'; 'color2'      = 'string'; 'effect'    = 'string'
    'direction'   = 'string'; 'easing'      = 'string'
    'hz'          = 'double'; 'tail'        = 'double'; 'depth'     = 'double'
    'fullseconds' = 'double'; 'brightness'  = 'int'
}
$StyleFieldJson = @{
    'color' = 'Color'; 'color2' = 'Color2'; 'effect' = 'Effect'
    'direction' = 'Direction'; 'easing' = 'Easing'; 'hz' = 'Hz'
    'tail' = 'Tail'; 'depth' = 'Depth'; 'fullseconds' = 'FullSeconds'
    'brightness' = 'Brightness'
}

function Parse-StyleArgs {
    param([string[]] $Tokens)
    $positional = @()
    $patch = @{}
    $flags = @{}
    $i = 0
    while ($i -lt $Tokens.Count) {
        $t = $Tokens[$i]
        if ($t -like '--*') {
            $name = $t.Substring(2).ToLowerInvariant()
            if ($name -eq 'all') { $flags['all'] = $true; $i++; continue }
            if ($i + 1 -ge $Tokens.Count) { throw "missing value for --$name" }
            $value = $Tokens[$i + 1]
            if ($StyleFields.ContainsKey($name)) {
                switch ($StyleFields[$name]) {
                    'double' {
                        $d = 0.0
                        if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::Float, $InvariantCulture, [ref] $d)) {
                            throw "--$name expects a number, got '$value'"
                        }
                        $patch[$StyleFieldJson[$name]] = $d
                    }
                    'int' {
                        $n = 0
                        if (-not [int]::TryParse($value, [System.Globalization.NumberStyles]::Integer, $InvariantCulture, [ref] $n)) {
                            throw "--$name expects a whole number, got '$value'"
                        }
                        $patch[$StyleFieldJson[$name]] = $n
                    }
                    default { $patch[$StyleFieldJson[$name]] = $value }
                }
            } else {
                $flags[$name] = $value
            }
            $i += 2
        } else {
            $positional += $t
            $i++
        }
    }
    return @{ Positional = $positional; Patch = $patch; Flags = $flags }
}

# Set whenever a call reaches the daemon but the daemon answers with a 4xx/5xx - a typo'd
# effect name, an unknown state, a missing POST body. Cleared at the top of every Call so
# a stale message from a previous command can never leak into an unrelated failure.
$script:LastErrorBody = $null

function Call {
    param([string]$Path, [string]$Method = 'Get', $Body = $null)
    $script:LastErrorBody = $null
    try {
        if ($Body) {
            return Invoke-RestMethod -Uri "$base$Path" -Method $Method -Body ($Body | ConvertTo-Json -Compress) `
                -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop
        }
        return Invoke-RestMethod -Uri "$base$Path" -Method $Method -TimeoutSec 5 -ErrorAction Stop
    } catch {
        # A response that carries a real HTTP status (400 unknown state, 405 wrong verb,
        # 500 save failed, ...) means the daemon is up and answered - that is a completely
        # different failure than "nothing is listening on the port", and the caller
        # deserves the daemon's own message rather than being told to go start it. Only a
        # true connection failure (refused, timed out, DNS) has no Response object at all,
        # so that case falls through with LastErrorBody left null.
        $resp = $_.Exception.Response
        if ($resp) {
            try {
                $stream = $resp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $text = $reader.ReadToEnd()
                if ($text) { $script:LastErrorBody = $text.Trim() }
            } catch { }
        }
        return $null
    }
}

function Show-Offline {
    if ($script:LastErrorBody) {
        Write-Output $script:LastErrorBody
        return
    }
    Write-Output "Govee daemon is not running on port $Port."
    Write-Output ""
    Write-Output "Start it with:"
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\Ensure-Daemon.ps1"
    Write-Output "Or build it first:"
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\Build.ps1 -Restart"
}

# Everything below can throw a plain string error (Parse-StyleArgs on a bad --hz, the
# --seconds parse in 'preview') for input a user just typed. Catching it here - once,
# around the whole dispatch - turns that into one readable line instead of a stack trace,
# without cluttering every verb below with its own try/catch.
try {

switch ($Command.ToLowerInvariant()) {

    'status' {
        $s = Call '/status'
        if (-not $s) { Show-Offline; break }
        Write-Output "Govee lights daemon v$($s.version)"
        Write-Output "  uptime      : $([math]::Round($s.uptimeSec))s"
        Write-Output "  enabled     : $($s.enabled)"
        Write-Output "  quiet hours : $($s.quietHours)"
        Write-Output "  govee       : $(if ($s.govee.connected) { 'connected' } else { "OFFLINE - $($s.govee.lastError)" })"
        Write-Output "  state       : $($s.render.state)"
        Write-Output "  sends       : $($s.render.sends)"
        Write-Output ""
        Write-Output "Devices:"
        foreach ($d in $s.render.devices) {
            Write-Output ("  {0,-24} {1,3} segments  animate={2}  brightness={3}" -f `
                $d.name, $d.segments, $d.animate, $d.brightness)
        }
        Write-Output ""
        if ($s.sessions.Count -eq 0) {
            Write-Output "No live sessions."
        } else {
            Write-Output "Sessions:"
            foreach ($x in $s.sessions) {
                Write-Output ("  {0,-16} {1,-14} {2}s  {3}" -f $x.sessionId, $x.state, $x.forSeconds, $x.cwd)
            }
        }
    }

    'devices' {
        $d = Call '/devices'
        if (-not $d) { Show-Offline; break }
        Write-Output "Discovered devices (from Govee Desktop):"
        Write-Output ""
        Write-Output ("  {0,-24} {1,-8} {2,8}  {3}" -f 'NAME', 'SKU', 'SEGMENTS', 'LAN')
        foreach ($x in $d.discovered) {
            Write-Output ("  {0,-24} {1,-8} {2,8}  {3}" -f $x.name, $x.sku, $x.segments,
                $(if ($x.lanOn) { 'on' } else { 'OFF - cannot be driven' }))
        }
        Write-Output ""
        Write-Output "Currently driven:"
        foreach ($x in $d.render.devices) { Write-Output "  $($x.name)" }
        Write-Output ""
        Write-Output "LAN control is enabled per device in the Govee Home mobile app."
    }

    'test' {
        $Argument = if ($Rest.Count -gt 0) { $Rest[0] } else { $null }
        if (-not $Argument) {
            Write-Output "Usage: /govee test <state>"
            Write-Output ""
            Write-Output "States: Idle Thinking ToolRead ToolEdit ToolShell ToolWeb ToolMcp"
            Write-Output "        ToolAgent ToolOther Compacting WaitingUser Error Done Offline"
            break
        }
        $r = Call '/test' 'Post' @{ state = $Argument; holdMs = 8000 }
        if (-not $r) { Show-Offline; break }
        Write-Output "Forcing state '$($r.state)' for $([math]::Round($r.holdMs/1000))s - watch your lights."
    }

    { $_ -in 'on', 'enable' } {
        $r = Call '/enable' 'Post'
        if (-not $r) { Show-Offline; break }
        Write-Output "Lights enabled."
    }

    { $_ -in 'off', 'disable' } {
        $r = Call '/disable' 'Post'
        if (-not $r) { Show-Offline; break }
        Write-Output "Lights disabled. Hooks are still accepted; nothing is rendered."
    }

    'refresh' {
        $r = Call '/refresh' 'Post'
        if (-not $r) { Show-Offline; break }
        Write-Output "Device list refreshed from Govee Desktop."
    }

    'restart' {
        Call '/shutdown' 'Post' | Out-Null
        Start-Sleep -Milliseconds 1200
        $ensure = Join-Path $PSScriptRoot 'Ensure-Daemon.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ensure | Out-Null
        Start-Sleep -Seconds 2
        $h = Call '/health'
        if ($h) { Write-Output "Restarted. govee=$($h.goveeState) pid=$($h.pid)" }
        else { Write-Output "Restart failed - see logs." }
    }

    'logs' {
        $dir = Join-Path $env:LOCALAPPDATA 'ClaudeGovee\logs'
        $f = Get-ChildItem $dir -Filter 'daemon-*.log' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $f) { Write-Output "No logs in $dir"; break }
        Write-Output "Last 30 entries from $($f.Name):"
        Write-Output ""
        Get-Content $f.FullName -Tail 30 | ForEach-Object {
            try {
                $o = $_ | ConvertFrom-Json
                $extra = @()
                foreach ($p in $o.PSObject.Properties) {
                    if ($p.Name -notin 'ts','lvl','evt','msg','stack') { $extra += "$($p.Name)=$($p.Value)" }
                }
                Write-Output ("  {0} {1,-5} {2,-22} {3} {4}" -f `
                    $o.ts.Substring(11), $o.lvl, $o.evt, $o.msg, ($extra -join ' '))
            } catch { Write-Output "  $_" }
        }
    }

    'doctor' {
        Write-Output "Govee lights diagnostics"
        Write-Output ""

        $dll = 'C:\Program Files\Govee\Govee Desktop\GoveeAPI\GoveeAPI.dll'
        Write-Output ("  GoveeAPI.dll present     : {0}" -f (Test-Path $dll))

        $p = Get-Process GoveeDesktop -ErrorAction SilentlyContinue
        Write-Output ("  Govee Desktop running    : {0}" -f [bool]$p)

        # Elevated Govee Desktop makes the pipe unwritable by normal processes - this is
        # the single most common way to break the whole integration.
        $writable = $false
        try {
            $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'GoveeDesktopPipe', [System.IO.Pipes.PipeDirection]::InOut)
            $c.Connect(1500); $writable = $true; $c.Dispose()
        } catch { }
        Write-Output ("  Pipe writable            : {0}" -f $writable)
        if (-not $writable -and $p) {
            Write-Output "     ^ Govee Desktop is running AS ADMINISTRATOR. Restart it normally."
        }

        foreach ($n in @('ScenicDreamView','RazerDreamView','DreamView')) {
            $q = Get-Process $n -ErrorAction SilentlyContinue
            if ($q) { Write-Output "  WARNING: $n is running and conflicts with this API." }
        }

        $h = Call '/health'
        Write-Output ("  Daemon responding        : {0}" -f [bool]$h)
        if ($h) { Write-Output ("  Govee connection         : {0}" -f $h.goveeState) }

        $cfgPath = Join-Path $env:LOCALAPPDATA 'ClaudeGovee\config.json'
        Write-Output ("  Config                   : {0}" -f $cfgPath)
        if (Test-Path $cfgPath) {
            try {
                $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
                Write-Output ("  apiGuid set              : {0}" -f [bool]$c.ApiGuid)
            } catch { Write-Output "  Config is not valid JSON." }
        }
    }

    'styles' {
        $parsed = Parse-StyleArgs $Rest
        $state = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0] } else { $null }
        $path = if ($state) { "/styles?state=$state" } else { '/styles' }
        $s = Call $path
        if (-not $s) { Show-Offline; break }

        if ($state) {
            $r = $s.states[0]
            Write-Output "$($r.state)"
            Write-Output "  colour     : $($r.color)$(if ($r.color2) { " -> $($r.color2)" })"
            Write-Output "  effect     : $($r.effect)"
            Write-Output "  rate       : $($r.hz) Hz"
            Write-Output "  brightness : $($r.brightness)"
            Write-Output "  direction  : $($r.direction)   easing: $($r.easing)"
            Write-Output "  tail       : $($r.tail)   depth: $($r.depth)   fullSeconds: $($r.fullSeconds)"
            Write-Output "  source     : $($r.source)"
        } else {
            Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f 'STATE','COLOUR','EFFECT','HZ','BRIGHT','SOURCE')
            foreach ($r in $s.states) {
                Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f `
                    $r.state, $r.color, $r.effect, $r.hz, $r.brightness, $r.source)
            }
            Write-Output ""
            if ($s.dirty) { Write-Output "Unsaved changes. '/govee save' to keep them, '/govee revert' to discard." }
            else { Write-Output "No unsaved changes." }
        }
    }

    'set' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Positional.Count -lt 1 -or $parsed.Patch.Count -eq 0) {
            Write-Output "Usage: /govee set <state> --color #RRGGBB [--effect chase] [--hz 0.8] ..."
            Write-Output ""
            Write-Output "Fields: color color2 effect hz brightness direction easing tail depth fullseconds"
            break
        }
        $r = Call '/styles/set' 'Post' @{ state = $parsed.Positional[0]; patch = $parsed.Patch }
        if (-not $r) { Show-Offline; break }
        Write-Output "Applied to $($parsed.Positional[0]). Unsaved - '/govee save' to keep it."
    }

    'reset' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Flags.ContainsKey('all')) {
            $r = Call '/styles/reset' 'Post' @{ all = $true }
            if (-not $r) { Show-Offline; break }
            Write-Output "All states reset to built-in defaults. Unsaved - '/govee save' to keep it."
        } elseif ($parsed.Positional.Count -ge 1) {
            $r = Call '/styles/reset' 'Post' @{ state = $parsed.Positional[0] }
            if (-not $r) { Show-Offline; break }
            Write-Output "$($parsed.Positional[0]) reset to its built-in default. Unsaved - '/govee save' to keep it."
        } else {
            Write-Output "Usage: /govee reset <state>   |   /govee reset --all"
        }
    }

    'save' {
        $r = Call '/styles/save' 'Post'
        if (-not $r) { Show-Offline; break }
        if ($r.saved) { Write-Output "Saved to config.json. Comments and other settings were left alone." }
        else { Write-Output "Nothing to save." }
    }

    'revert' {
        $r = Call '/styles/revert' 'Post'
        if (-not $r) { Show-Offline; break }
        Write-Output "Unsaved changes discarded."
    }

    'preview' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Positional.Count -lt 1) {
            Write-Output "Usage: /govee preview <state> [--effect comet] [--tail 2.5] [--seconds 8]"
            break
        }
        $hold = 8000
        if ($parsed.Flags.ContainsKey('seconds')) {
            # TryParse, not a bare [double] cast: a cast throws on the current culture's
            # rules and a bad value here should read like every other field's error
            # instead of an unrelated-looking type-conversion exception.
            $secs = 0.0
            if (-not [double]::TryParse($parsed.Flags['seconds'], [System.Globalization.NumberStyles]::Float, $InvariantCulture, [ref] $secs)) {
                throw "--seconds expects a number, got '$($parsed.Flags['seconds'])'"
            }
            $hold = [int]($secs * 1000)
        }
        $r = Call '/preview' 'Post' @{ state = $parsed.Positional[0]; patch = $parsed.Patch; holdMs = $hold }
        if (-not $r) { Show-Offline; break }
        Write-Output "Previewing $($r.state) for $([math]::Round($r.holdMs / 1000))s - watch your lights. Nothing was changed."
    }

    'theme' {
        $parsed = Parse-StyleArgs $Rest
        $sub = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0].ToLowerInvariant() } else { 'list' }
        $name = if ($parsed.Positional.Count -gt 1) { $parsed.Positional[1] } else { $null }

        switch ($sub) {
            'list' {
                $t = Call '/themes'
                if (-not $t) { Show-Offline; break }
                Write-Output ("  {0,-14}{1,-10}{2}" -f 'NAME','KIND','DESCRIPTION')
                foreach ($x in $t.themes) {
                    $kind = if ($x.builtin) { if ($x.shadowed) { 'built-in*' } else { 'built-in' } } else { 'saved' }
                    Write-Output ("  {0,-14}{1,-10}{2}" -f $x.name, $kind, $x.description)
                }
                if ($t.themes | Where-Object { $_.shadowed }) {
                    Write-Output ""
                    Write-Output "* shadowed by a saved theme of the same name."
                }
            }
            'apply' {
                if (-not $name) { Write-Output "Usage: /govee theme apply <name>"; break }

                # Applying a theme is total by design (StyleRoutes.ThemeApply): it replaces
                # whatever was pending, not just the states this theme mentions. The API
                # response only says "dirty":true, which does not distinguish "nothing was
                # pending" from "your edits were just wiped" - so ask first, while it still
                # matters, and say so afterward if it does.
                $before = Call '/styles'
                $hadPending = [bool]($before -and $before.dirty)

                $r = Call '/themes/apply' 'Post' @{ name = $name }
                if (-not $r) { Show-Offline; break }
                Write-Output "Applied theme '$($r.theme)'. Unsaved - '/govee save' to keep it."
                if ($hadPending) {
                    Write-Output "Your pending 'set'/'reset' edits were discarded - applying a theme replaces the whole palette."
                }
            }
            'save' {
                if (-not $name) { Write-Output "Usage: /govee theme save <name>"; break }
                $r = Call '/themes/save' 'Post' @{ name = $name }
                if (-not $r) { Show-Offline; break }
                if ($r.saved) { Write-Output "Saved current styles as theme '$name'." }
                else { Write-Output "Nothing to save - no styles are set yet." }
            }
            default { Write-Output "Usage: /govee theme list | apply <name> | save <name>" }
        }
    }

    default {
        Write-Output "Usage: /govee <command>"
        Write-Output ""
        Write-Output "  status    daemon state, devices, live sessions"
        Write-Output "  devices   all Govee devices and which can be driven"
        Write-Output "  test <s>  force a state for 8s so you can see it"
        Write-Output "  on | off  enable or disable rendering"
        Write-Output "  refresh   re-read the device list"
        Write-Output "  restart   restart the daemon"
        Write-Output "  logs      tail the daemon log"
        Write-Output "  doctor    diagnose a broken setup"
        Write-Output "  styles    show every state's colour and effect"
        Write-Output "  set       change a state, e.g. set Thinking --color #FF0000 --hz 2"
        Write-Output "  preview   try a style for a few seconds without changing anything"
        Write-Output "  reset     put a state (or --all) back to its built-in default"
        Write-Output "  save      write pending changes to config.json"
        Write-Output "  revert    discard pending changes"
        Write-Output "  theme     list | apply <name> | save <name>"
    }
}

} catch {
    Write-Output $_.Exception.Message
}
