<#
.SYNOPSIS
    Replay a realistic Claude Code hook sequence against the daemon.

.DESCRIPTION
    Drives the daemon exactly as Claude Code would, without needing to provoke real
    sessions. Also exercises the coalescing rule: a burst of rapid Read calls must
    render as one continuous colour, not twenty separate flashes.
#>
[CmdletBinding()]
param(
    [int]    $Port = 17321,
    [string] $SessionId = 'replay-1',
    [double] $Speed = 1.0        # >1 = faster
)

$base = "http://127.0.0.1:$Port"

function Hook {
    param([string] $Event, [string] $Hint, [string] $Tool, [double] $Pause = 1.0)
    $body = @{
        hook_event_name = $Event
        session_id      = $SessionId
        cwd             = 'c:\dev\ClaudeGoveeLights'
        permission_mode = 'default'
    }
    if ($Tool) { $body.tool_name = $Tool }
    $url = "$base/hook"
    if ($Hint) { $url += "?e=$Hint" }

    $label = if ($Tool) { "$Event ($Tool)" } elseif ($Hint) { "$Event [$Hint]" } else { $Event }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-RestMethod -Uri $url -Method Post -Body ($body | ConvertTo-Json -Compress) `
            -ContentType 'application/json' -TimeoutSec 3 | Out-Null
        $sw.Stop()
        "  {0,-34} {1,4} ms" -f $label, $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        "  {0,-34} FAILED: {1}" -f $label, $_.Exception.Message
    }
    Start-Sleep -Milliseconds ([int]($Pause * 1000 / $Speed))
}

function Say($t) { Write-Host ''; Write-Host "  >> $t" -ForegroundColor Cyan }

Write-Host ''
Write-Host '=== Replaying a Claude Code session ===' -ForegroundColor Cyan

Say 'Session starts -> idle (dim blue)'
Hook 'SessionStart' '' '' 3

Say 'You submit a prompt -> thinking (purple breathe)'
Hook 'UserPromptSubmit' '' '' 4

Say 'Reading files -> cyan chase. 20 rapid calls must look like ONE state.'
for ($i = 0; $i -lt 20; $i++) {
    Hook 'PreToolUse' '' 'Read' 0.05
    Hook 'PostToolUse' '' 'Read' 0.05
}
Start-Sleep -Seconds 2

Say 'Editing -> green chase'
Hook 'PreToolUse' '' 'Edit' 3
Hook 'PostToolUse' '' 'Edit' 1

Say 'Shell command -> orange chase'
Hook 'PreToolUse' '' 'Bash' 3
Hook 'PostToolUse' '' 'Bash' 1

Say 'Subagent -> magenta comet'
Hook 'SubagentStart' 'subagent_start' '' 4
Hook 'SubagentStop' 'subagent_stop' '' 2

Say 'Permission prompt -> amber fast pulse (highest priority)'
Hook 'Notification' 'permission_prompt' '' 6

Say 'You approve, tool runs -> back to orange'
Hook 'PreToolUse' '' 'Bash' 3
Hook 'PostToolUseFailure' 'tool_error' 'Bash' 4

Say 'Turn ends -> green, then decays to idle after 4s'
Hook 'Stop' 'stop' '' 8

Say 'Session ends -> resting colour'
Hook 'SessionEnd' 'session_end' '' 2

Write-Host ''
Write-Host '=== Final status ===' -ForegroundColor Cyan
try {
    $s = Invoke-RestMethod -Uri "$base/status" -TimeoutSec 5
    "  state    : $($s.render.state)"
    "  sends    : $($s.render.sends)"
    "  sessions : $($s.sessions.Count)"
    "  connected: $($s.govee.connected)"
} catch { "  status failed: $($_.Exception.Message)" }
Write-Host ''
