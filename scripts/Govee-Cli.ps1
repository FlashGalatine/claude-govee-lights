<#
.SYNOPSIS
    Backend for the /govee slash command.

.EXAMPLE
    .\Govee-Cli.ps1 status
    .\Govee-Cli.ps1 test ToolShell
    .\Govee-Cli.ps1 off
    .\Govee-Cli.ps1 set Thinking --color FF0000 --hz 2
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

# Numbers that came back from the daemon (Hz, Tail, Depth, FullSeconds) must print the
# same way they are parsed - a bare "$($r.hz)" interpolation formats with the *current*
# culture, so 0.8 would render as "0,8" on a comma-decimal system even though only "0.8"
# is ever accepted as input.
function Format-Invariant($value) {
    if ($null -eq $value) { return '' }
    if ($value -is [double] -or $value -is [single] -or $value -is [decimal] -or `
        $value -is [int] -or $value -is [long]) {
        return $value.ToString($InvariantCulture)
    }
    return "$value"
}

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
    # ExtraFlags names the non-style flags this particular verb accepts (e.g. 'all' for
    # reset, 'seconds' for preview). Anything that is neither a known style field nor
    # in this list is a typo, not a silently-ignored no-op - '--colour' (not '--color')
    # is the realistic case, since the table header and detail view both print "colour".
    #
    # NoStyleFlagsFor names the verb when this call site never sends a patch at all
    # ('styles', 'theme'). Without it those verbs parse '--color FF0000' perfectly, drop
    # it on the floor and report success - the same "a typed argument silently did
    # nothing" defect the unknown-flag check above exists to prevent, reached through a
    # different door. Rejected here rather than in the branch so the message can name the
    # flag the user actually typed, in the order they typed it.
    param([string[]] $Tokens, [string[]] $ExtraFlags = @(), [string] $NoStyleFlagsFor)
    $positional = @()
    $patch = @{}
    $flags = @{}
    $i = 0
    while ($i -lt $Tokens.Count) {
        $t = $Tokens[$i]
        if ($t -like '--*') {
            $name = $t.Substring(2).ToLowerInvariant()
            if ($name -eq 'all') {
                if ($ExtraFlags -notcontains 'all') { throw "unknown flag --all" }
                $flags['all'] = $true; $i++; continue
            }
            if ($i + 1 -ge $Tokens.Count) { throw "missing value for --$name" }
            $value = $Tokens[$i + 1]
            # A value that itself looks like the next flag was very likely never typed -
            # "set Thinking --color --effect chase" almost certainly means --color was
            # left blank, not that the colour is literally "--effect".
            if ($value -like '--*') { throw "missing value for --$name" }

            if ($StyleFields.ContainsKey($name)) {
                if ($NoStyleFlagsFor) {
                    throw "--$name is a style field and '$NoStyleFlagsFor' does not take one; use '/govee set' to change a style, or '/govee preview' to try one."
                }
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
                    default {
                        # '#' starts a comment in both cmd.exe and POSIX shells, and
                        # $ARGUMENTS is interpolated unquoted by the slash command, so a
                        # literally-typed "--color #FF0000" never reaches here intact -
                        # accept the bare six hex digits people are forced to type instead
                        # and restore the '#' the rest of the pipeline expects.
                        $v = $value
                        if (($name -eq 'color' -or $name -eq 'color2') -and $v -match '^[0-9a-fA-F]{6}$') { $v = "#$v" }
                        $patch[$StyleFieldJson[$name]] = $v
                    }
                }
            } elseif ($ExtraFlags -contains $name) {
                $flags[$name] = $value
            } else {
                throw "unknown flag --$name"
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
        $resp = $_.Exception.Response
        if (-not $resp) {
            # No HTTP response object at all - refused, timed out, DNS failure. This
            # really is "nothing is listening", so LastErrorBody stays null and
            # Show-CallFailure below prints the offline message.
            return $null
        }

        # The daemon answered - a 400 unknown state, a 405 wrong verb, a 500 save
        # failure. That is a completely different failure than "nothing is listening",
        # and the caller deserves the daemon's own message.
        #
        # On PowerShell 5.1, Invoke-RestMethod has ALREADY drained the response stream
        # to populate $_.ErrorDetails.Message before this catch ever runs - calling
        # $resp.GetResponseStream() here returns an exhausted stream and reads back
        # empty. That silently reproduced the exact bug this whole fix exists for: a
        # 400 read as "daemon is not running". ErrorDetails.Message is also how PS7's
        # HttpResponseException carries the body, so it is checked first on both.
        $bodyText = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $bodyText = $_.ErrorDetails.Message.Trim() }

        # Fallback only for the case ErrorDetails came back empty but the response
        # object still exposes a readable stream (PS 5.1's HttpWebResponse). PS7's
        # Response is an HttpResponseMessage with no GetResponseStream method at all,
        # so this is skipped there rather than throwing.
        if (-not $bodyText -and ($resp.PSObject.Methods.Name -contains 'GetResponseStream')) {
            try {
                $stream = $resp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $text = $reader.ReadToEnd()
                if ($text) { $bodyText = $text.Trim() }
            } catch { }
        }

        if ($bodyText) {
            $script:LastErrorBody = $bodyText
        } else {
            # A response with no readable body still means "the daemon answered, just
            # not usefully" - this must never fall through to the offline message,
            # which would say the opposite of what actually happened.
            $code = $null
            try { $code = [int]$resp.StatusCode } catch { }
            $script:LastErrorBody = if ($code) { "The daemon refused the request (HTTP $code)." } else { "The daemon refused the request." }
        }
        return $null
    }
}

# Stop whatever is listening, start a fresh daemon through Ensure-Daemon, and return
# the new /health document - or $null if nothing answered. Shared by 'restart' and
# 'guid'; when nothing was running the shutdown call simply finds no one to tell.
function Restart-Daemon {
    Call '/shutdown' 'Post' | Out-Null
    Start-Sleep -Milliseconds 1200
    $ensure = Join-Path $PSScriptRoot 'Ensure-Daemon.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ensure | Out-Null
    Start-Sleep -Seconds 2
    return (Call '/health')
}

# Write the API GUID into config.json as a text splice. The daemon reads the file with
# JavaScriptSerializer and writes it back through its own pretty-printer, and users
# add _comment members by hand; a ConvertFrom-Json/ConvertTo-Json round-trip here
# would re-indent to four spaces and, on PowerShell 5.1, truncate Devices[].States at
# the default -Depth of 2. Replacing one value in place keeps every other byte.
# Property names are case-insensitive to the daemon, so the match is too.
function Set-ConfigGuid {
    param([string] $Path, [string] $Value)
    $text = if (Test-Path $Path) { [System.IO.File]::ReadAllText($Path) } else { "{`n}`n" }
    $m = [regex]::Match($text, '(?i)("ApiGuid"\s*:\s*")[^"]*(")')
    if ($m.Success) {
        $text = $text.Substring(0, $m.Index) + $m.Groups[1].Value + $Value + $m.Groups[2].Value +
                $text.Substring($m.Index + $m.Length)
    } else {
        $brace = $text.IndexOf('{')
        if ($brace -lt 0) { throw "$Path does not look like a JSON object; fix or delete it and try again." }
        $body = $text.Substring($brace + 1)
        # Borrow the file's own indent from its first indented member; two spaces is
        # what the daemon writes and what a brand-new file gets.
        $indentMatch = [regex]::Match($body, '(?m)^([ \t]+)"')
        $indent = if ($indentMatch.Success) { $indentMatch.Groups[1].Value } else { '  ' }
        $comma = if ($body -match '^\s*"') { ',' } else { '' }
        $text = $text.Substring(0, $brace + 1) + "`n" + $indent + '"ApiGuid": "' + $Value + '"' + $comma + $body
    }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $text)
}

function Show-CallFailure {
    if ($script:LastErrorBody) {
        # This is the daemon's own message, not "nothing is running" - it answered.
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
        if (-not $s) { Show-CallFailure; break }
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
        if (-not $d) { Show-CallFailure; break }
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
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Forcing state '$($r.state)' for $([math]::Round($r.holdMs/1000))s - watch your lights."
    }

    { $_ -in 'on', 'enable' } {
        $r = Call '/enable' 'Post'
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Lights enabled."
    }

    { $_ -in 'off', 'disable' } {
        $r = Call '/disable' 'Post'
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Lights disabled. Hooks are still accepted; nothing is rendered."
    }

    'refresh' {
        $r = Call '/refresh' 'Post'
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Device list refreshed from Govee Desktop."
    }

    'restart' {
        $h = Restart-Daemon
        if ($h) { Write-Output "Restarted. govee=$($h.goveeState) pid=$($h.pid)" }
        else { Write-Output "Restart failed - see logs." }
    }

    'guid' {
        # The one verb that cannot go through the daemon: a missing GUID is the single
        # condition under which it refuses to run (no_guid, exit 2), so on the very
        # first setup nothing is listening to take a request.
        $noRestart = $false
        $positional = @()
        if ($Rest) {
            foreach ($a in $Rest) {
                if ($a -ieq '--no-restart') { $noRestart = $true } else { $positional += $a }
            }
        }
        if ($positional.Count -lt 1) {
            Write-Output "Usage: /govee guid <value> [--no-restart]"
            Write-Output ""
            Write-Output "The value is in Govee Desktop under Settings > API. It is written to config.json"
            Write-Output "and the daemon is restarted so it takes effect."
            break
        }
        $value = $positional[0].Trim()
        $ignored = [Guid]::Empty
        if (-not [Guid]::TryParse($value, [ref]$ignored)) {
            throw "'$value' is not a GUID. Copy it from Govee Desktop > Settings > API."
        }
        $cfgPath = Join-Path $env:LOCALAPPDATA 'ClaudeGovee\config.json'
        Set-ConfigGuid $cfgPath $value
        Write-Output "Saved API GUID to $cfgPath."
        if ($noRestart) { break }

        $h = Restart-Daemon
        if ($h) { Write-Output "Daemon started. govee=$($h.goveeState) pid=$($h.pid) - '/govee doctor' to check it sees your lights." }
        else {
            Write-Output "The daemon did not come up. If it has not been built yet, run Build.ps1 -Restart;"
            Write-Output "otherwise '/govee logs' says why."
        }
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
        $guidHint = "     ^ run '/govee guid <value>' with the GUID from Govee Desktop > Settings > API."
        if (Test-Path $cfgPath) {
            try {
                $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
                Write-Output ("  apiGuid set              : {0}" -f [bool]$c.ApiGuid)
                if (-not $c.ApiGuid) { Write-Output $guidHint }
            } catch { Write-Output "  Config is not valid JSON." }
        } else {
            Write-Output "  apiGuid set              : False (no config yet)"
            Write-Output $guidHint
        }
    }

    'styles' {
        # 'styles' only ever reads - it has no patch to put a style field into.
        $parsed = Parse-StyleArgs $Rest -NoStyleFlagsFor 'styles'
        $state = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0] } else { $null }
        $path = if ($state) { "/styles?state=$([uri]::EscapeDataString($state))" } else { '/styles' }
        $s = Call $path
        if (-not $s) { Show-CallFailure; break }

        if ($state) {
            # A 200 with an empty states array should not happen (the route 400s for an
            # unknown state), but daemon behaviour is not this script's to assume - print
            # something readable instead of indexing into nothing.
            if (-not $s.states -or $s.states.Count -eq 0) {
                Write-Output "No style data returned for '$state'."
                break
            }
            $r = $s.states[0]
            Write-Output "$($r.state)"
            Write-Output "  colour     : $($r.color)$(if ($r.color2) { " -> $($r.color2)" })"
            Write-Output "  effect     : $($r.effect)"
            Write-Output "  rate       : $(Format-Invariant $r.hz) Hz"
            Write-Output "  brightness : $($r.brightness)"
            Write-Output "  direction  : $($r.direction)   easing: $($r.easing)"
            Write-Output "  tail       : $(Format-Invariant $r.tail)   depth: $(Format-Invariant $r.depth)   fullSeconds: $(Format-Invariant $r.fullSeconds)"
            Write-Output "  source     : $($r.source)"
        } else {
            Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f 'STATE','COLOUR','EFFECT','HZ','BRIGHT','SOURCE')
            foreach ($r in $s.states) {
                Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f `
                    $r.state, $r.color, $r.effect, (Format-Invariant $r.hz), $r.brightness, $r.source)
            }
            Write-Output ""
            if ($s.dirty) { Write-Output "Unsaved changes. '/govee save' to keep them, '/govee revert' to discard." }
            else { Write-Output "No unsaved changes." }
        }
    }

    'set' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Positional.Count -lt 1 -or $parsed.Patch.Count -eq 0) {
            Write-Output "Usage: /govee set <state> --color RRGGBB [--effect chase] [--hz 0.8] ..."
            Write-Output ""
            Write-Output "Fields: color color2 effect hz brightness direction easing tail depth fullseconds"
            Write-Output "Colours are six hex digits with no '#' - '#' starts a comment in the shell."
            break
        }
        $r = Call '/styles/set' 'Post' @{ state = $parsed.Positional[0]; patch = $parsed.Patch }
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Applied to $($parsed.Positional[0]). Unsaved - '/govee save' to keep it."
    }

    'reset' {
        $parsed = Parse-StyleArgs $Rest -ExtraFlags @('all')
        if ($parsed.Flags.ContainsKey('all')) {
            $r = Call '/styles/reset' 'Post' @{ all = $true }
            if (-not $r) { Show-CallFailure; break }
            Write-Output "All states reset to built-in defaults. Unsaved - '/govee save' to keep it."
        } elseif ($parsed.Positional.Count -ge 1) {
            $r = Call '/styles/reset' 'Post' @{ state = $parsed.Positional[0] }
            if (-not $r) { Show-CallFailure; break }
            Write-Output "$($parsed.Positional[0]) reset to its built-in default. Unsaved - '/govee save' to keep it."
        } else {
            Write-Output "Usage: /govee reset <state>   |   /govee reset --all"
        }
    }

    'save' {
        $r = Call '/styles/save' 'Post'
        if (-not $r) { Show-CallFailure; break }
        if ($r.saved) {
            Write-Output "Saved to config.json. Comments and other settings were left alone."
            # The write can succeed while the daemon fails to re-read the file. It says so
            # rather than clearing the pending edits (see StyleRoutes.Save), and that is
            # worth repeating here: the user would otherwise see "Saved." followed by
            # /styles still reporting unsaved changes, with nothing explaining why.
            if ($r.warning) { Write-Output $r.warning }
        }
        else { Write-Output "Nothing to save." }
    }

    'revert' {
        $r = Call '/styles/revert' 'Post'
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Unsaved changes discarded."
    }

    'preview' {
        $parsed = Parse-StyleArgs $Rest -ExtraFlags @('seconds')
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
            # NaN and Infinity are rejected alongside a parse failure: .NET's TryParse
            # accepts both by name, and either one survives the clamp below to throw a raw
            # cast error - the very thing the clamp is there to prevent.
            if (-not [double]::TryParse($parsed.Flags['seconds'], [System.Globalization.NumberStyles]::Float, $InvariantCulture, [ref] $secs) -or
                [double]::IsNaN($secs) -or [double]::IsInfinity($secs)) {
                throw "--seconds expects a number, got '$($parsed.Flags['seconds'])'"
            }
            # Clamp BEFORE the cast, to the same 0.5s-60s window /preview enforces. A bare
            # [int] cast of something like --seconds 999999999 overflows and throws a raw
            # conversion error, which the outer catch prints verbatim - nothing like the
            # tidy "--seconds expects a number" one line above it.
            $hold = [int][math]::Round([math]::Max(500.0, [math]::Min(60000.0, $secs * 1000)))
        }
        $body = @{ state = $parsed.Positional[0]; holdMs = $hold }
        # Only send a patch when one was actually typed. StyleRoutes.Preview treats a
        # non-null empty object as a patch and registers a preview slot for it, so a bare
        # '/govee preview Thinking' would otherwise make /styles report
        # "+ preview (unsaved)" for eight seconds while contributing nothing to the look.
        if ($parsed.Patch.Count -gt 0) { $body['patch'] = $parsed.Patch }
        $r = Call '/preview' 'Post' $body
        if (-not $r) { Show-CallFailure; break }
        Write-Output "Previewing $($r.state) for $([math]::Round($r.holdMs / 1000))s - watch your lights. Nothing was changed."
    }

    'theme' {
        # A theme IS the palette - none of list/apply/save sends a patch, so
        # 'theme apply muted --color FF0000' has no colour to apply and must say so
        # rather than reporting a clean success it did not deliver.
        # 'install --all' is the one flag this verb takes; it is neither a style field
        # nor a positional name.
        $parsed = Parse-StyleArgs $Rest -ExtraFlags @('all') -NoStyleFlagsFor 'theme'
        $sub = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0].ToLowerInvariant() } else { 'list' }
        $name = if ($parsed.Positional.Count -gt 1) { $parsed.Positional[1] } else { $null }
        if ($parsed.Flags['all'] -and $sub -ne 'install') {
            # Same rule as unknown flags: a typed flag that does nothing must not
            # report a clean success it did not deliver.
            throw "--all only applies to 'theme install'"
        }

        # Example themes ship with the plugin as themes/*.json, one directory above this
        # script. The daemon never sees that folder - it launches with no arguments and
        # knows only %LOCALAPPDATA%\ClaudeGovee\themes (Themes.UserDir) - so 'install'
        # is a plain file copy from the one to the other, done here. Once copied, an
        # example is an ordinary saved theme: it lists as 'saved', it shadows a built-in
        # of the same name, and deleting the file uninstalls it.
        $exampleDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'themes'
        $userThemeDir = Join-Path $env:LOCALAPPDATA 'ClaudeGovee\themes'
        $examples = @(if (Test-Path $exampleDir) { Get-ChildItem $exampleDir -Filter '*.json' | Sort-Object Name })
        function Get-ExampleDescription($file) {
            try { $d = (Get-Content $file.FullName -Raw | ConvertFrom-Json).Description } catch { $d = $null }
            if ($d) { "$d" } else { '(example theme)' }
        }
        function Test-ExampleInstalled($file) {
            Test-Path (Join-Path $userThemeDir $file.Name)
        }

        switch ($sub) {
            'list' {
                $t = Call '/themes'
                if (-not $t) { Show-CallFailure; break }
                Write-Output ("  {0,-14}{1,-10}{2}" -f 'NAME','KIND','DESCRIPTION')
                foreach ($x in $t.themes) {
                    $kind = if ($x.builtin) { if ($x.shadowed) { 'built-in*' } else { 'built-in' } } else { 'saved' }
                    Write-Output ("  {0,-14}{1,-10}{2}" -f $x.name, $kind, $x.description)
                }
                # Shipped examples that are not yet in the user's themes folder. The
                # daemon cannot list these (it has never seen the file), so they would
                # otherwise be invisible until someone reads the README. An installed
                # example already appears above as 'saved', so it is not repeated here.
                $notInstalled = @($examples | Where-Object { -not (Test-ExampleInstalled $_) })
                foreach ($f in $notInstalled) {
                    Write-Output ("  {0,-14}{1,-10}{2}" -f $f.BaseName, 'example', (Get-ExampleDescription $f))
                }
                if ($t.themes | Where-Object { $_.shadowed }) {
                    Write-Output ""
                    Write-Output "* shadowed by a saved theme of the same name."
                }
                if ($notInstalled.Count -gt 0) {
                    Write-Output ""
                    Write-Output "example = ships with the plugin; '/govee theme install <name>' (or --all) copies it into your themes."
                }
            }
            'install' {
                $wantAll = [bool]$parsed.Flags['all']
                if (-not $name -and -not $wantAll) { Write-Output "Usage: /govee theme install <name> | --all"; break }
                if ($name -and $wantAll) { Write-Output "Give a name or --all, not both."; break }
                if ($examples.Count -eq 0) { Write-Output "No example themes found at $exampleDir."; break }

                $targets = if ($wantAll) { $examples } else {
                    @($examples | Where-Object { $_.BaseName -ieq $name })
                }
                if ($targets.Count -eq 0) {
                    Write-Output "No example theme named '$name'. Available: $(($examples | ForEach-Object { $_.BaseName }) -join ', ')."
                    break
                }

                New-Item -ItemType Directory -Force -Path $userThemeDir | Out-Null
                $installed = @()
                foreach ($f in $targets) {
                    # Never overwrite: an installed copy may have been edited, and 'save'
                    # to the same name is the user's own theme now. Idempotent by design -
                    # running install twice is safe and says so.
                    if (Test-ExampleInstalled $f) {
                        Write-Output "'$($f.BaseName)' is already installed - edit or delete $(Join-Path $userThemeDir $f.Name) to change it."
                        continue
                    }
                    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $userThemeDir $f.Name)
                    $installed += $f.BaseName
                }
                if ($installed.Count -eq 1) {
                    Write-Output "Installed '$($installed[0])' - '/govee theme apply $($installed[0])' to try it."
                } elseif ($installed.Count -gt 1) {
                    Write-Output "Installed $($installed.Count) themes: $($installed -join ', ') - '/govee theme apply <name>' to try one."
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
                if (-not $r) {
                    Show-CallFailure
                    # The daemon only knows built-ins and installed files. If the name
                    # matches an example that was never installed, that is the fix.
                    $ex = @($examples | Where-Object { $_.BaseName -ieq $name -and -not (Test-ExampleInstalled $_) })
                    if ($script:LastErrorBody -match 'no such theme' -and $ex.Count -gt 0) {
                        Write-Output "'$($ex[0].BaseName)' is an example theme that is not installed yet - '/govee theme install $($ex[0].BaseName)' first."
                    }
                    break
                }
                Write-Output "Applied theme '$($r.theme)'. Unsaved - '/govee save' to keep it."
                if ($hadPending) {
                    Write-Output "Your pending 'set'/'reset' edits were discarded - applying a theme replaces the whole palette."
                }
            }
            'save' {
                if (-not $name) { Write-Output "Usage: /govee theme save <name>"; break }
                $r = Call '/themes/save' 'Post' @{ name = $name }
                if (-not $r) { Show-CallFailure; break }
                if ($r.saved) { Write-Output "Saved current styles as theme '$name'." }
                else { Write-Output "Nothing to save - no styles are set yet." }
            }
            default { Write-Output "Usage: /govee theme list | apply <name> | save <name> | install <name>|--all" }
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
        Write-Output "  guid <v>  save the API GUID from Govee Desktop > Settings > API and start the daemon"
        Write-Output "  styles    show every state's colour and effect"
        Write-Output "  set       change a state, e.g. set Thinking --color FF0000 --hz 2"
        Write-Output "  preview   try a style for a few seconds without changing anything"
        Write-Output "  reset     put a state (or --all) back to its built-in default"
        Write-Output "  save      write pending changes to config.json"
        Write-Output "  revert    discard pending changes"
        Write-Output "  theme     list | apply <name> | save <name> | install <name>|--all"
    }
}

} catch {
    Write-Output $_.Exception.Message
    # Otherwise this exits 0 - a caller (the slash command, a script) has no way to
    # tell "set Thinking --hz abc" apart from a command that actually succeeded.
    exit 1
}
