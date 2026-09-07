<#
.SYNOPSIS
    Test Claude Code and Codex activity mapping without a daemon or Govee hardware.

.DESCRIPTION
    Compiles the actual mapper and session store in memory. Only logging is replaced
    with a no-op, so there are no daemon processes, config writes or network calls.
    Uses explicit timestamps instead of sleeps to test queued state transitions.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = @('using System; using System.Collections.Generic; using System.Linq;')
foreach ($name in @('HookMapper.cs', 'SessionStore.cs')) {
    $path = Join-Path $root "src/GoveeLights.Daemon/$name"
    $source += (Get-Content -LiteralPath $path -Raw) -replace '(?m)^using [^;]+;\r?\n', ''
}
$source += @'
namespace GoveeLights {
    public static class Log {
        public static void Debug(string evt, string msg = null, object data = null) { }
        public static void Info(string evt, string msg = null, object data = null) { }
    }
}
'@
Add-Type -TypeDefinition ($source -join "`n") -Language CSharp

$script:passed = 0
function Assert-Equal($Name, $Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "$Name : expected '$Expected', got '$Actual'." }
    $script:passed++
}

$sessions = New-Object GoveeLights.SessionStore
$mapper = New-Object GoveeLights.HookMapper -ArgumentList $sessions, $null

# Keep the old tool classifications stable while adding the Codex equivalents.
$toolCases = @{
    Bash = 'ToolShell'; BashOutput = 'ToolShell'; KillShell = 'ToolShell'; PowerShell = 'ToolShell'
    Edit = 'ToolEdit'; MultiEdit = 'ToolEdit'; Write = 'ToolEdit'; NotebookEdit = 'ToolEdit'
    Read = 'ToolRead'; Glob = 'ToolRead'; Grep = 'ToolRead'; NotebookRead = 'ToolRead'
    WebFetch = 'ToolWeb'; WebSearch = 'ToolWeb'
    Task = 'ToolAgent'; Agent = 'ToolAgent'; SendMessage = 'ToolAgent'; Workflow = 'ToolAgent'
    exec_command = 'ToolShell'; shell = 'ToolShell'; shell_command = 'ToolShell'
    local_shell = 'ToolShell'; write_stdin = 'ToolShell'; apply_patch = 'ToolEdit'
    read_file = 'ToolRead'; list_dir = 'ToolRead'; grep_files = 'ToolRead'; view_image = 'ToolRead'
    web = 'ToolWeb'; 'web.run' = 'ToolWeb'; web__run = 'ToolWeb'
    spawn_agent = 'ToolAgent'; send_message = 'ToolAgent'; wait_agent = 'ToolAgent'
    wait = 'ToolAgent'; close_agent = 'ToolAgent'; resume_agent = 'ToolAgent'
    followup_task = 'ToolAgent'; list_agents = 'ToolAgent'; interrupt_agent = 'ToolAgent'
    request_user_input = 'WaitingUser'; request_user_input_async = 'WaitingUser'
    mcp__server__tool = 'ToolMcp'; future_unknown_tool = 'ToolOther'
}
foreach ($tool in $toolCases.Keys) {
    Assert-Equal "classify $tool" ($mapper.ClassifyTool($tool).ToString()) $toolCases[$tool]
}
Assert-Equal 'missing tool name' ($mapper.ClassifyTool($null).ToString()) 'ToolOther'
Assert-Equal 'tool names are case-insensitive' ($mapper.ClassifyTool('APPLY_PATCH').ToString()) 'ToolEdit'

$overrides = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$overrides['exec_command'] = 'read'
$customMapper = New-Object GoveeLights.HookMapper -ArgumentList $sessions, $overrides
Assert-Equal 'user tool class override wins' ($customMapper.ClassifyTool('exec_command').ToString()) 'ToolRead'

$mapper.Handle('SessionStart', $null, 'claude:one', 'C:\work', $null)
$claude = $sessions.GetOrAdd('claude:one', $null)
Assert-Equal 'Claude session starts idle' ($claude.State.ToString()) 'Idle'
$mapper.Handle('UserPromptSubmit', $null, 'claude:one', $null, $null)
Assert-Equal 'Claude prompt starts thinking' ($claude.State.ToString()) 'Thinking'
$mapper.Handle('PreToolUse', $null, 'claude:one', $null, 'Bash')
Assert-Equal 'Claude shell activity' ($claude.State.ToString()) 'ToolShell'
$mapper.Handle('PostToolUse', $null, 'claude:one', $null, 'Bash')
$claude.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
$sessions.Tick()
Assert-Equal 'Claude tool completion settles to thinking' ($claude.State.ToString()) 'Thinking'

# Both interactive Codex tools must latch while waiting and release after an answer.
foreach ($tool in @('request_user_input', 'request_user_input_async')) {
    $sid = "codex:$tool"
    $mapper.Handle('PreToolUse', $null, $sid, 'C:\work', $tool)
    $state = $sessions.GetOrAdd($sid, $null)
    Assert-Equal "$tool waits on user" ($state.State.ToString()) 'WaitingUser'
    Assert-Equal "$tool holds waiting state" ($state.StickyUntil -gt [datetime]::UtcNow.AddMinutes(14)) $true
    $mapper.Handle('PostToolUse', $null, $sid, $null, $tool)
    Assert-Equal "$tool response releases latch" $state.StickyUntil ([datetime]::MinValue)
    $state.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
    $sessions.Tick()
    Assert-Equal "$tool response settles to thinking" ($state.State.ToString()) 'Thinking'
}

$mapper.Handle('PermissionRequest', $null, 'codex:approval', 'C:\work', 'exec_command')
$approval = $sessions.GetOrAdd('codex:approval', $null)
Assert-Equal 'approval waits on user' ($approval.State.ToString()) 'WaitingUser'
$mapper.Handle('PostToolUse', $null, 'codex:approval', $null, 'exec_command')
$approval.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
$sessions.Tick()
Assert-Equal 'approved tool completion releases waiting' ($approval.State.ToString()) 'Thinking'

# Cancel immediately, before the minimum hold expires, with queued work present.
# The neighbouring Claude session must retain its higher-priority waiting state.
$mapper.Handle('PermissionRequest', $null, 'claude:one', $null, 'Bash')
$interruptStates = @{ PermissionRequest = 'WaitingUser'; PreToolUse = 'ToolShell'; StopFailure = 'Error'; Stop = 'Done' }
foreach ($event in @('PermissionRequest', 'PreToolUse', 'StopFailure', 'Stop')) {
    $sid = "codex:interrupt-$event"
    $mapper.Handle('SubagentStart', $null, $sid, 'C:\cancelled-work', $null)
    $sessions.GetOrAdd($sid, $null).MinUntil = [datetime]::MinValue
    $mapper.Handle($event, $null, $sid, $null, 'exec_command')
    $before = $sessions.GetOrAdd($sid, $null)
    Assert-Equal "$event enters the state under test" ($before.State.ToString()) $interruptStates[$event]
    $before.MinUntil = [datetime]::UtcNow.AddMinutes(1)
    $sessions.Schedule($before, [GoveeLights.Activity]::Thinking)
    $before.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
    $mapper.Handle('Interrupt', $null, $sid, $null, $null)
    $after = $sessions.GetOrAdd($sid, $null)
    Assert-Equal "$event interruption becomes idle immediately" ($after.State.ToString()) 'Idle'
    Assert-Equal "$event interruption clears sticky state" $after.StickyUntil ([datetime]::MinValue)
    Assert-Equal "$event interruption clears minimum hold" $after.MinUntil ([datetime]::MinValue)
    Assert-Equal "$event interruption clears queued work" ($null -eq $after.Pending) $true
    Assert-Equal "$event interruption resets subagents" $after.SubagentDepth 0
    Assert-Equal "$event interruption preserves working directory" $after.Cwd 'C:\cancelled-work'
    $sessions.Tick()
    Assert-Equal "$event cancelled work stays idle after tick" ($after.State.ToString()) 'Idle'
    Assert-Equal 'interrupt leaves another session waiting' ($claude.State.ToString()) 'WaitingUser'
    $winner = $null
    Assert-Equal 'another live session retains rendered priority' ($sessions.Resolve([ref]$winner).ToString()) 'WaitingUser'
    Assert-Equal 'Claude session is still tracked' $winner.SessionId 'claude:one'
}

$countBeforeEnd = $sessions.Count
$mapper.Handle('SessionEnd', $null, 'codex:approval', $null, $null)
Assert-Equal 'ending a session removes exactly that session' $sessions.Count ($countBeforeEnd - 1)
Assert-Equal 'ending a session preserves Claude activity' ($claude.State.ToString()) 'WaitingUser'

# A fast final tool must complete even when Stop arrives inside its visible hold.
$completionSessions = New-Object GoveeLights.SessionStore
$completionMapper = New-Object GoveeLights.HookMapper -ArgumentList $completionSessions, $null
$completionMapper.Handle('PreToolUse', $null, 'codex:fast-stop', 'C:\work', 'apply_patch')
$fast = $completionSessions.GetOrAdd('codex:fast-stop', $null)
$fast.MinUntil = [datetime]::UtcNow.AddMinutes(1)
$fast.SubagentDepth = 2
$completionMapper.Handle('PostToolUse', $null, 'codex:fast-stop', $null, 'apply_patch')
$completionMapper.Handle('Stop', $null, 'codex:fast-stop', $null, $null)
Assert-Equal 'fast Stop preserves the last tool hold' ($fast.State.ToString()) 'ToolEdit'
Assert-Equal 'fast Stop replaces queued Thinking with Done' ($fast.Pending.ToString()) 'Done'
Assert-Equal 'fast Stop completes at the end of the tool hold' $fast.PendingAt $fast.MinUntil
Assert-Equal 'fast Stop resets subagent depth' $fast.SubagentDepth 0
$completionSessions.Tick()
Assert-Equal 'completion does not bypass a visible tool hold' ($fast.State.ToString()) 'ToolEdit'
$fast.MinUntil = [datetime]::MinValue
$fast.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
$completionSessions.Tick()
Assert-Equal 'fast Stop eventually displays Done' ($fast.State.ToString()) 'Done'
Assert-Equal 'fast Stop consumes the queued completion' ($null -eq $fast.Pending) $true
$fast.EnteredAt = [datetime]::UtcNow.AddSeconds(-5)
$completionSessions.Tick()
Assert-Equal 'completed fast turn eventually becomes idle' ($fast.State.ToString()) 'Idle'

$completionMapper.Handle('PostToolUseFailure', $null, 'codex:error-stop', 'C:\work', 'exec_command')
$errorStop = $completionSessions.GetOrAdd('codex:error-stop', $null)
$errorStop.StickyUntil = [datetime]::UtcNow.AddMinutes(1)
$completionMapper.Handle('Stop', $null, 'codex:error-stop', $null, $null)
Assert-Equal 'Stop preserves an error flourish' ($errorStop.State.ToString()) 'Error'
Assert-Equal 'error completion waits for the sticky deadline' $errorStop.PendingAt $errorStop.StickyUntil
$completionSessions.Tick()
Assert-Equal 'error stays visible until its sticky deadline' ($errorStop.State.ToString()) 'Error'
$errorStop.MinUntil = [datetime]::MinValue
$errorStop.StickyUntil = [datetime]::MinValue
$errorStop.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
$completionSessions.Tick()
Assert-Equal 'error completion displays Done after its flourish' ($errorStop.State.ToString()) 'Done'

$completionMapper.Handle('PermissionRequest', $null, 'codex:waiting-stop', 'C:\work', 'exec_command')
$waitingStop = $completionSessions.GetOrAdd('codex:waiting-stop', $null)
$waitingStop.MinUntil = [datetime]::UtcNow.AddMinutes(1)
$completionMapper.Handle('Stop', $null, 'codex:waiting-stop', $null, $null)
Assert-Equal 'Stop releases the fifteen-minute waiting latch' $waitingStop.StickyUntil ([datetime]::MinValue)
Assert-Equal 'waiting completion observes only the visible hold' $waitingStop.PendingAt $waitingStop.MinUntil
Assert-Equal 'waiting completion queues Done' ($waitingStop.Pending.ToString()) 'Done'
$waitingStop.MinUntil = [datetime]::MinValue
$waitingStop.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
$completionSessions.Tick()
Assert-Equal 'waiting completion displays Done' ($waitingStop.State.ToString()) 'Done'

$completionMapper.Handle('SessionStart', $null, 'codex:immediate-stop', 'C:\work', $null)
$completionMapper.Handle('Stop', $null, 'codex:immediate-stop', $null, $null)
$immediateStop = $completionSessions.GetOrAdd('codex:immediate-stop', $null)
Assert-Equal 'Stop displays Done immediately without an active hold' ($immediateStop.State.ToString()) 'Done'
Assert-Equal 'immediate completion leaves no queued transition' ($null -eq $immediateStop.Pending) $true

# A new turn or tool supersedes queued completion, including lower-priority work
# that cannot yet displace the previous tool or error. It resumes after the hold.
foreach ($startEvent in @('PreToolUse', 'PostToolUseFailure')) {
    foreach ($nextEvent in @('UserPromptSubmit', 'PreToolUse')) {
        $sid = "codex:new-work-$startEvent-$nextEvent"
        $completionMapper.Handle($startEvent, $null, $sid, 'C:\work', 'exec_command')
        $newWork = $completionSessions.GetOrAdd($sid, $null)
        $newWork.MinUntil = [datetime]::UtcNow.AddMinutes(1)
        $completionMapper.Handle('Stop', $null, $sid, $null, $null)
        $completionMapper.Handle($nextEvent, $null, $sid, $null, 'read_file')
        $expected = if ($nextEvent -eq 'UserPromptSubmit') { 'Thinking' } else { 'ToolRead' }
        Assert-Equal "$nextEvent supersedes queued completion during $startEvent hold" ($newWork.Pending.ToString()) $expected
        $newWork.MinUntil = [datetime]::MinValue
        $newWork.StickyUntil = [datetime]::MinValue
        $newWork.PendingAt = [datetime]::UtcNow.AddSeconds(-1)
        $completionSessions.Tick()
        Assert-Equal "$nextEvent resumes after $startEvent hold" ($newWork.State.ToString()) $expected
        $newWork.EnteredAt = [datetime]::UtcNow.AddSeconds(-5)
        $completionSessions.Tick()
        Assert-Equal "$nextEvent cannot become idle from the old completion" ($newWork.State.ToString()) $expected
    }
}

Write-Output "Hook mapper: $script:passed checks passed (no daemon, network or hardware)."
