<#
.SYNOPSIS
    SessionStart bootstrap: make sure the daemon is running, then forward the hook.

.DESCRIPTION
    Wired as the only `command` hook in the plugin (async, so it never blocks Claude
    Code). It must be fast and it must ALWAYS exit 0 - a command hook exiting 2 is a
    blocking error that would surface to the user.

    Reads the hook payload from stdin and forwards it once the daemon answers, so the
    session is registered even on the very first run when nothing was listening yet.
#>
[CmdletBinding()]
param(
    [int] $Port = 17321,
    [int] $StartTimeoutSec = 6
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

# Read stdin before anything else - if we exit early we still want the payload.
$payload = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw -and $raw.Trim()) { $payload = $raw }
} catch { }

function Test-Daemon {
    # Check the process first. A refused loopback connection costs .NET a full 2s
    # (Node returns ECONNREFUSED in under 1ms, but this script is PowerShell), so
    # probing /health when nothing is running would waste 2s on every cold start.
    if (-not (Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue)) { return $false }
    try {
        $r = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 2 -ErrorAction Stop
        return [bool]$r.ok
    } catch { return $false }
}

function Send-Payload {
    # No ?e= hint: the daemon reads hook_event_name from the body, which is correct
    # for every event this bootstrap is wired to. Only Notification and StopFailure
    # need the hint, and neither is a command hook.
    if (-not $payload) { return }
    try {
        Invoke-RestMethod -Uri "$base/hook" -Method Post -Body $payload `
            -ContentType 'application/json' -TimeoutSec 3 -ErrorAction Stop | Out-Null
    } catch { }
}

try {
    # SessionStart has no parallel HTTP hook, so register warm sessions here too.
    # UserPromptSubmit already has an HTTP sender and must not be double-posted.
    if (Test-Daemon) {
        if ($payload -and ($payload | ConvertFrom-Json).hook_event_name -eq 'SessionStart') { Send-Payload }
        exit 0
    }

    # Locate the executable: published output first, then a dev build.
    $root = if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { Split-Path $PSScriptRoot -Parent }
    $candidates = @(
        (Join-Path $root 'dist\daemon\GoveeLightsDaemon.exe'),
        (Join-Path $root 'src\GoveeLights.Daemon\bin\Release\net48\GoveeLightsDaemon.exe'),
        (Join-Path $root 'src\GoveeLights.Daemon\bin\Debug\net48\GoveeLightsDaemon.exe')
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $exe) {
        Write-Error "GoveeLightsDaemon.exe not found. Run scripts\Build.ps1 first." -ErrorAction Continue
        exit 0    # deliberately not 2 - a missing daemon must not break Claude Code
    }

    Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Daemon) { Send-Payload; exit 0 }
        Start-Sleep -Milliseconds 250
    }

    Write-Error "Daemon did not become healthy within ${StartTimeoutSec}s." -ErrorAction Continue
} catch {
    # Swallow everything. Ambient lighting is never worth interrupting a session for.
    Write-Error "Ensure-Daemon failed: $($_.Exception.Message)" -ErrorAction Continue
}

exit 0
