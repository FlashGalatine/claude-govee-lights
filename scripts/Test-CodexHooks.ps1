<#
.SYNOPSIS
    Hardware-free tests of the Codex hook adapter, using Windows PowerShell 5.1.
.DESCRIPTION
    Daemon startup and lifecycle delivery are mocked. Transport tests use only a
    test listener on an OS-assigned loopback port; no installed daemon is started
    or contacted. Subprocess checks use port 0 and disable daemon startup.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-CodexHooks.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$hookScript = Join-Path $PSScriptRoot 'Codex-Hook.ps1'
. $hookScript
$realSend = ${function:Send-GoveeHook}
$pass = 0
$fail = 0

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Test-Case([string] $Name, [scriptblock] $Run) {
    try {
        & $Run
        $script:pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-HookJson([string] $Name, $Response = $null) {
    return @{
        hook_event_name = $Name; session_id = 'session-123'
        cwd = 'C:\project'; tool_name = 'exec_command'; tool_response = $Response
        prompt = 'PRIVATE PROMPT'; tool_input = @{ command = 'PRIVATE COMMAND' }
        transcript_path = 'PRIVATE TRANSCRIPT'; tool_output = 'PRIVATE OUTPUT'
    } | ConvertTo-Json -Depth 8 -Compress
}

function Reset-Mocks([bool[]] $SendResults = @($true), [bool] $StartResult = $true,
        [bool] $StartThrows = $false) {
    $script:sendResults = $SendResults
    $script:sent = New-Object 'System.Collections.Generic.List[object]'
    $script:trace = New-Object 'System.Collections.Generic.List[string]'
    $script:successes = 0
    $script:starts = 0
    $script:startResult = $StartResult
    $script:startThrows = $StartThrows
}

function Send-GoveeHook([string] $Body, [int] $Port) {
    $attempt = $script:sent.Count
    $script:sent.Add(@{ Body = $Body; Port = $Port })
    $script:trace.Add('send')
    $ok = $attempt -lt $script:sendResults.Count -and $script:sendResults[$attempt]
    if ($ok) { $script:successes++ }
    return $ok
}

function Start-GoveeHookDaemon {
    $script:starts++
    $script:trace.Add('start')
    if ($script:startThrows) { throw 'Simulated startup failure' }
    return $script:startResult
}

Write-Host 'Codex hook adapter tests' -ForegroundColor Cyan

foreach ($eventName in @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
        'PermissionRequest', 'PreCompact', 'PostCompact', 'SubagentStart', 'SubagentStop',
        'Stop', 'Interrupt', 'SessionEnd')) {
    Test-Case "$eventName forwards a minimal, namespaced lifecycle event" {
        Reset-Mocks
        $output = @(Invoke-GoveeCodexHook -Raw (New-HookJson $eventName) -Port 42345 *>&1)
        Assert-True ($output.Count -eq 0) 'The hook emitted output.'
        Assert-True ($script:sent.Count -eq 1 -and $script:successes -eq 1) 'Expected exactly one successful send.'
        Assert-True ($script:starts -eq 0) 'A warm daemon must not be started again.'
        Assert-True ($script:sent[0].Port -eq 42345) 'The configured port was lost.'
        $payload = $script:sent[0].Body | ConvertFrom-Json
        $keys = @($payload.PSObject.Properties.Name | Sort-Object)
        Assert-True (($keys -join ',') -eq 'cwd,hook_event_name,session_id,tool_name') 'The payload must contain exactly four allowed fields.'
        Assert-True ($payload.hook_event_name -eq $eventName) 'The lifecycle name changed.'
        Assert-True ($payload.session_id -ceq 'codex:session-123') 'The session ID must use the Codex namespace.'
        Assert-True ($payload.cwd -eq 'C:\project' -and $payload.tool_name -eq 'exec_command') 'Routing context was lost.'
        Assert-True ($script:sent[0].Body -notmatch 'PRIVATE') 'Private prompt, arguments, output, or transcript data leaked.'
    }
}

foreach ($response in @(@{ exit_code = 1 }, @{ exit_code = -9 }, @{ exit_code = '2' }, @{ isError = $true })) {
    Test-Case ("Structured tool failure maps to PostToolUseFailure: " + ($response | ConvertTo-Json -Compress)) {
        $payload = ConvertTo-GoveeHook (New-HookJson 'PostToolUse' $response)
        Assert-True ($payload.hook_event_name -eq 'PostToolUseFailure') 'Structured failure was not recognized.'
    }
}

foreach ($response in @('error: process failed', @{ output = 'error: process failed' },
        @{ exit_code = 0 }, @{ isError = $false }, @{ isError = 'true' }, @{ exit_code = 'error' })) {
    Test-Case ("Unstructured text and nonfailure statuses remain PostToolUse: " + ($response | ConvertTo-Json -Compress)) {
        $payload = ConvertTo-GoveeHook (New-HookJson 'PostToolUse' $response)
        Assert-True ($payload.hook_event_name -eq 'PostToolUse') 'The adapter guessed a failure from unstructured content.'
    }
}

Test-Case 'Structured response does not rename other lifecycle events' {
    $payload = ConvertTo-GoveeHook (New-HookJson 'PreToolUse' @{ isError = $true })
    Assert-True ($payload.hook_event_name -eq 'PreToolUse') 'Failure conversion escaped PostToolUse.'
}

foreach ($raw in @('', '{invalid json', 'null', '[]', '"not an event"', '{}',
        '{"hook_event_name":"Stop"}', '{"hook_event_name":"Stop","session_id":"  "}',
        '{"hook_event_name":"Unknown","session_id":"session-123"}')) {
    Test-Case "Invalid or incomplete input is silently ignored: $raw" {
        Reset-Mocks
        $output = @(Invoke-GoveeCodexHook -Raw $raw *>&1)
        Assert-True ($output.Count -eq 0) 'Invalid input emitted output.'
        Assert-True ($script:sent.Count -eq 0 -and $script:starts -eq 0) 'Invalid input caused a send or daemon startup.'
    }
}

foreach ($eventName in @('SessionStart', 'UserPromptSubmit')) {
    Test-Case "$eventName starts a cold daemon and delivers once after readiness" {
        Reset-Mocks -SendResults @($false, $true)
        Invoke-GoveeCodexHook -Raw (New-HookJson $eventName) -Port 42345 -StartTimeoutSec 1
        Assert-True (($script:trace -join ',') -eq 'send,start,send') 'Expected failed send, startup, and successful retry in order.'
        Assert-True ($script:starts -eq 1 -and $script:successes -eq 1) 'Startup or successful delivery occurred more than once.'
        Assert-True ($script:sent[0].Body -ceq $script:sent[1].Body) 'The retry changed the lifecycle event.'
    }
}

foreach ($eventName in @('PreToolUse', 'PostToolUse', 'PermissionRequest', 'PreCompact',
        'PostCompact', 'SubagentStart', 'SubagentStop', 'Stop', 'Interrupt', 'SessionEnd')) {
    Test-Case "$eventName never starts a missing daemon" {
        Reset-Mocks -SendResults @($false)
        Invoke-GoveeCodexHook -Raw (New-HookJson $eventName) -StartTimeoutSec 1
        Assert-True ($script:sent.Count -eq 1 -and $script:starts -eq 0) 'A nonbootstrap event retried or started the daemon.'
    }
}

Test-Case 'Disabled bootstrap does not start a missing daemon' {
    Reset-Mocks -SendResults @($false)
    Invoke-GoveeCodexHook -Raw (New-HookJson 'SessionStart') -StartTimeoutSec 0
    Assert-True ($script:sent.Count -eq 1 -and $script:starts -eq 0) 'A zero startup timeout must disable bootstrap.'
}

Test-Case 'Missing daemon executable stops retries' {
    Reset-Mocks -SendResults @($false) -StartResult $false
    Invoke-GoveeCodexHook -Raw (New-HookJson 'SessionStart') -StartTimeoutSec 1
    Assert-True ($script:sent.Count -eq 1 -and $script:starts -eq 1) 'Failed startup must end the attempt without retries.'
}

Test-Case 'Startup exceptions are silent and do not escape into the session' {
    Reset-Mocks -SendResults @($false) -StartThrows $true
    $output = @(Invoke-GoveeCodexHook -Raw (New-HookJson 'SessionStart') -StartTimeoutSec 1 *>&1)
    Assert-True ($output.Count -eq 0 -and $script:sent.Count -eq 1 -and $script:starts -eq 1) 'The startup failure escaped or delivery continued.'
}

Test-Case 'Cold daemon readiness retries stop at the configured deadline' {
    Reset-Mocks -SendResults @($false)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-GoveeCodexHook -Raw (New-HookJson 'UserPromptSubmit') -StartTimeoutSec 1
    $timer.Stop()
    Assert-True ($script:starts -eq 1 -and $script:sent.Count -gt 1 -and $script:successes -eq 0) 'Expected one startup followed by failed readiness retries.'
    Assert-True ($timer.Elapsed.TotalSeconds -ge 0.9 -and $timer.Elapsed.TotalSeconds -lt 3) 'Readiness did not honor its bounded timeout.'
}

# A separate runspace accepts exactly one real HTTP request. TcpListener avoids
# HttpListener URL reservations and binds only to an ephemeral loopback port.
function New-TestEndpoint([int] $DelayMs = 0, [int] $StatusCode = 204) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $runner = [PowerShell]::Create()
    $null = $runner.AddScript({
        param($Listener, $DelayMs, $StatusCode)
        $client = $null
        try {
            $client = $Listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
            do {
                $next = $stream.ReadByte()
                if ($next -lt 0 -or $headerBytes.Count -gt 16384) { throw 'Incomplete HTTP headers.' }
                $headerBytes.Add([byte]$next)
                $headers = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
            } until ($headers.EndsWith("`r`n`r`n"))
            # Match MiniHttpServer: it waits for the body and does not implement
            # the optional HTTP 100 Continue handshake.
            if ($headers -notmatch '(?im)^Content-Length:\s*(\d+)') { throw 'Missing content length.' }
            $length = [int]$Matches[1]
            $bytes = New-Object byte[] $length
            $offset = 0
            while ($offset -lt $length) {
                $read = $stream.Read($bytes, $offset, $length - $offset)
                if ($read -eq 0) { throw 'Incomplete HTTP body.' }
                $offset += $read
            }
            $captured = @{ Headers = $headers; Body = [Text.Encoding]::UTF8.GetString($bytes) }
            if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
            $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $StatusCode Test`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            try { $stream.Write($response, 0, $response.Length) } catch { }
            return $captured
        } finally {
            if ($client) { $client.Dispose() }
            $Listener.Stop()
        }
    }).AddArgument($listener).AddArgument($DelayMs).AddArgument($StatusCode)
    return @{ Listener = $listener; Port = $listener.LocalEndpoint.Port; Runner = $runner; Pending = $runner.BeginInvoke() }
}

function Receive-TestEndpoint($Endpoint) {
    Assert-True ($Endpoint.Pending.AsyncWaitHandle.WaitOne(4000)) 'The test endpoint did not finish.'
    $captured = @($Endpoint.Runner.EndInvoke($Endpoint.Pending))
    Assert-True ($Endpoint.Runner.Streams.Error.Count -eq 0) ($Endpoint.Runner.Streams.Error | Out-String)
    Assert-True ($captured.Count -eq 1) 'The test endpoint did not capture exactly one request.'
    return $captured[0]
}

function Close-TestEndpoint($Endpoint) {
    $Endpoint.Listener.Stop()
    $Endpoint.Runner.Dispose()
}

function Invoke-TestProcess([string] $Exe, [string] $Arguments, [string] $InputText,
        [hashtable] $Environment = @{}) {
    $child = New-Object Diagnostics.Process
    $child.StartInfo.FileName = $Exe
    # Arguments is deliberately one raw Windows command line. Splitting/requoting
    # the cmd /c command here would change the shell parsing under test.
    $child.StartInfo.Arguments = $Arguments
    $child.StartInfo.UseShellExecute = $false
    $child.StartInfo.CreateNoWindow = $true
    $child.StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $child.StartInfo.RedirectStandardInput = $true
    $child.StartInfo.RedirectStandardOutput = $true
    $child.StartInfo.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) { $child.StartInfo.EnvironmentVariables[$key] = $Environment[$key] }
    try {
        $null = $child.Start()
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $child.StandardInput.Write($InputText)
        $child.StandardInput.Close()
        if (-not $child.WaitForExit(8000)) { $child.Kill(); throw 'The test subprocess did not finish in eight seconds.' }
        $child.WaitForExit()
        return @{ ExitCode = $child.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
    } finally { $child.Dispose() }
}

Test-Case 'Real transport POSTs exact UTF-8 JSON to /hook and accepts HTTP 204' {
    $endpoint = New-TestEndpoint
    try {
        $body = @{ hook_event_name = 'Stop'; session_id = 'codex:test'; cwd = ('C:\' + [char]0x96EA); tool_name = '' } | ConvertTo-Json -Compress
        $ok = & $realSend -Body $body -Port $endpoint.Port
        $captured = Receive-TestEndpoint $endpoint
        Assert-True $ok 'Transport rejected HTTP 204.'
        Assert-True ($captured.Headers -match '^POST /hook HTTP/1\.[01]') 'Unexpected HTTP method or route.'
        Assert-True ($captured.Headers -match '(?im)^Content-Type: application/json; charset=utf-8\r?$') 'Unexpected content type.'
        Assert-True ($captured.Headers -notmatch '(?im)^Expect:\s*100-continue') 'The transport requested a handshake that the daemon does not implement.'
        Assert-True ($captured.Body -ceq $body) 'UTF-8 JSON changed on the wire.'
    } finally { Close-TestEndpoint $endpoint }
}

Test-Case 'Real transport rejects an unsuccessful HTTP status without output' {
    $endpoint = New-TestEndpoint -StatusCode 500
    try {
        $output = @(& $realSend -Body '{}' -Port $endpoint.Port *>&1)
        $null = Receive-TestEndpoint $endpoint
        Assert-True ($output.Count -eq 1 -and $output[0] -is [bool] -and -not $output[0]) 'An HTTP error must return only false.'
    } finally { Close-TestEndpoint $endpoint }
}

Test-Case 'Real transport times out when the endpoint does not respond' {
    $endpoint = New-TestEndpoint -DelayMs 1500
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $ok = & $realSend -Body '{}' -Port $endpoint.Port
        $timer.Stop()
        Assert-True (-not $ok) 'A stalled endpoint unexpectedly succeeded.'
        Assert-True ($timer.Elapsed.TotalMilliseconds -lt 1200) 'The transport waited for the stalled response instead of timing out.'
        $null = Receive-TestEndpoint $endpoint
    } finally { Close-TestEndpoint $endpoint }
}

# Keep child process files in a unique scratch directory and verify its resolved
# target before recursive cleanup. No test modifies user configuration.
$scratchParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $scratchParent ('govee-codex-hooks-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    foreach ($raw in @('{invalid json', '{}', (New-HookJson 'Stop'))) {
        Test-Case "Standalone hook exits zero and prints only an empty object: $raw" {
            $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hookScript + '" -Port 0 -StartTimeoutSec 0'
            $result = Invoke-TestProcess -Exe (Join-Path $PSHOME 'powershell.exe') -Arguments $args -InputText $raw
            Assert-True ($result.ExitCode -eq 0) "The standalone hook exited $($result.ExitCode)."
            Assert-True ($result.Output.Trim() -ceq '{}') 'The standalone hook did not print exactly {}.'
            Assert-True ([string]::IsNullOrWhiteSpace($result.Error)) 'The standalone hook wrote to stderr.'
        }
    }

    # Simulate installation at a user-selected path. The manifest command must
    # read PLUGIN_ROOT as data in the child, even with shell punctuation in it.
    $fixtureRoot = Join-Path $scratch "installed user's plugin & lights"
    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    New-Item -ItemType Directory -Path $fixtureScripts -Force | Out-Null
    Copy-Item -LiteralPath $hookScript -Destination (Join-Path $fixtureScripts 'Codex-Hook.ps1')
    $manifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'codex/govee-lights/hooks/hooks.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $commands = @($manifest.hooks.PSObject.Properties | ForEach-Object {
        foreach ($group in $_.Value) {
            foreach ($hook in $group.hooks) {
                if ($hook.type -eq 'command') { $hook.command }
            }
        }
    } | Sort-Object -Unique)
    Test-Case 'Codex hook manifest supplies an executable command' {
        Assert-True ($commands.Count -gt 0) 'The Codex manifest contains no hook commands.'
    }
    foreach ($command in $commands) {
        Test-Case 'Packaged manifest command resolves a plugin path with spaces and punctuation through PowerShell' {
            $wrapper = Join-Path $scratch 'invoke-hook.ps1'
            [IO.File]::WriteAllText($wrapper, $command + "`r`n" + 'exit $LASTEXITCODE' + "`r`n")
            $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $wrapper + '"'
            $result = Invoke-TestProcess -Exe (Join-Path $PSHOME 'powershell.exe') -Arguments $args `
                -InputText '{invalid json' -Environment @{ PLUGIN_ROOT = $fixtureRoot }
            Assert-True ($result.ExitCode -eq 0) "The PowerShell hook command exited $($result.ExitCode): $($result.Error)"
            Assert-True ($result.Output.Trim() -ceq '{}') "The PowerShell hook command did not execute the packaged script: $($result.Output)"
            Assert-True ([string]::IsNullOrWhiteSpace($result.Error)) "The PowerShell hook command wrote to stderr: $($result.Error)"
        }
        Test-Case 'Packaged manifest command resolves a plugin path with spaces and punctuation through cmd' {
            $args = '/d /s /c "' + $command + '"'
            $result = Invoke-TestProcess -Exe $env:ComSpec -Arguments $args `
                -InputText '{invalid json' -Environment @{ PLUGIN_ROOT = $fixtureRoot }
            Assert-True ($result.ExitCode -eq 0) "The cmd hook command exited $($result.ExitCode): $($result.Error)"
            Assert-True ($result.Output.Trim() -ceq '{}') "The cmd hook command did not execute the packaged script: $($result.Output)"
            Assert-True ([string]::IsNullOrWhiteSpace($result.Error)) "The cmd hook command wrote to stderr: $($result.Error)"
        }
    }

    Test-Case 'Claude bootstrap reports a missing executable but still exits zero' {
        $ensureScript = Join-Path $fixtureScripts 'Ensure-Daemon.ps1'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Ensure-Daemon.ps1') -Destination $ensureScript
        $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ensureScript + '" -Port 0 -StartTimeoutSec 0'
        $result = Invoke-TestProcess -Exe (Join-Path $PSHOME 'powershell.exe') -Arguments $args -InputText '{}' `
            -Environment @{ CLAUDE_PLUGIN_ROOT = $fixtureRoot }
        Assert-True ($result.ExitCode -eq 0) "The missing daemon executable caused exit $($result.ExitCode)."
        Assert-True ($result.Error -match 'GoveeLightsDaemon.exe not found') 'The missing executable path was not exercised.'
        Assert-True ([string]::IsNullOrWhiteSpace($result.Output)) 'The missing executable produced unexpected stdout.'
    }
} finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
    $expectedPrefix = $scratchParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar + 'govee-codex-hooks-'
    if (-not $resolvedScratch.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a scratch path outside the expected test directory.'
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}

Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
