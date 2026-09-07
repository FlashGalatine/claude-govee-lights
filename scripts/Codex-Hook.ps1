<#
.SYNOPSIS
    Forward Codex lifecycle events to the shared Govee daemon. Always exits 0.
.DESCRIPTION
    Synchronous, bounded delivery preserves lifecycle order. Only session start and
    prompt submission can bootstrap the daemon. No prompt, tool arguments, output,
    or transcript contents are sent to the daemon.
#>
[CmdletBinding()]
param([int] $Port = 17321, [int] $StartTimeoutSec = 6)

function ConvertTo-GoveeHook {
    param([string] $Raw)
    $event = $Raw | ConvertFrom-Json -ErrorAction Stop
    $name = [string]$event.hook_event_name
    $known = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
        'PermissionRequest', 'PreCompact', 'PostCompact', 'SubagentStart',
        'SubagentStop', 'Stop', 'Interrupt', 'SessionEnd')
    if ($name -notin $known -or [string]::IsNullOrWhiteSpace([string]$event.session_id)) { return $null }

    # Codex reports failures through PostToolUse, rather than a separate event.
    # Recognize structured status only; arbitrary output text is not a contract.
    if ($name -eq 'PostToolUse') {
        $response = $event.tool_response
        if ($null -ne $response -and $response -isnot [string]) {
            $exitCode = 0
            $hasExit = $null -ne $response.exit_code -and
                [int]::TryParse([string]$response.exit_code, [ref]$exitCode)
            if (($response.isError -is [bool] -and $response.isError) -or ($hasExit -and $exitCode -ne 0)) {
                $name = 'PostToolUseFailure'
            }
        }
    }
    return [ordered]@{
        hook_event_name = $name
        session_id = 'codex:' + [string]$event.session_id
        cwd = [string]$event.cwd
        tool_name = [string]$event.tool_name
    }
}

function Send-GoveeHook {
    param([string] $Body, [int] $Port)
    $request = $null
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/hook")
        $request.Proxy = $null
        $request.Method = 'POST'
        $request.ContentType = 'application/json; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $request.Timeout = 250
        $request.ReadWriteTimeout = 250
        $request.KeepAlive = $false
        # MiniHttpServer reads the body directly and does not implement the
        # 100-continue handshake. Its default wait exceeds our request timeout.
        $request.ServicePoint.Expect100Continue = $false
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $reply = $request.GetResponse()
        try { return [int]$reply.StatusCode -eq 204 } finally { $reply.Dispose() }
    } catch { return $false }
    finally { if ($request) { $request.Abort() } }
}

function Start-GoveeHookDaemon {
    # Resolve from this script so source checkouts and installed copies behave alike.
    $pluginRoot = Split-Path $PSScriptRoot -Parent
    $exe = Join-Path $pluginRoot 'dist/daemon/GoveeLightsDaemon.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    if (-not (Get-Process GoveeLightsDaemon -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $exe -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
    return $true
}

function Invoke-GoveeCodexHook {
    param([string] $Raw, [int] $Port = 17321, [int] $StartTimeoutSec = 6)
    try {
        $payload = ConvertTo-GoveeHook -Raw $Raw
        if ($null -eq $payload) { return }
        $body = $payload | ConvertTo-Json -Compress
        if (Send-GoveeHook -Body $body -Port $Port) { return }
        if ($payload.hook_event_name -notin @('SessionStart', 'UserPromptSubmit') -or $StartTimeoutSec -le 0) { return }
        if (-not (Start-GoveeHookDaemon)) { return }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt $StartTimeoutSec) {
            Start-Sleep -Milliseconds 100
            if (Send-GoveeHook -Body $body -Port $Port) { return }
        }
    } catch { } # Lighting must never block a prompt, approve a tool, or request continuation.
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-GoveeCodexHook -Raw ([Console]::In.ReadToEnd()) -Port $Port -StartTimeoutSec $StartTimeoutSec
    } catch { }
    # Valid empty hook output, including Stop and SubagentStop. No decisions.
    [Console]::Out.WriteLine('{}')
    exit 0
}
