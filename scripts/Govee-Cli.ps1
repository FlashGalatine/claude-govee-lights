<#
.SYNOPSIS
    Backend for the /govee slash command.

.EXAMPLE
    .\Govee-Cli.ps1 status
    .\Govee-Cli.ps1 test ToolShell
    .\Govee-Cli.ps1 off
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'status',
    [Parameter(Position = 1)] [string] $Argument,
    [int] $Port = 17321
)

$ErrorActionPreference = 'Continue'
$base = "http://127.0.0.1:$Port"

function Call {
    param([string]$Path, [string]$Method = 'Get', $Body = $null)
    try {
        if ($Body) {
            return Invoke-RestMethod -Uri "$base$Path" -Method $Method -Body ($Body | ConvertTo-Json -Compress) `
                -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop
        }
        return Invoke-RestMethod -Uri "$base$Path" -Method $Method -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Show-Offline {
    Write-Output "Govee daemon is not running on port $Port."
    Write-Output ""
    Write-Output "Start it with:"
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\Ensure-Daemon.ps1"
    Write-Output "Or build it first:"
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\Build.ps1 -Restart"
}

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
    }
}
