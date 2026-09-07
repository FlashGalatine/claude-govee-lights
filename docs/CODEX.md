# Codex integration

The repository supports both Claude Code and Codex on Windows. They share the
daemon, port 17321, `%LOCALAPPDATA%\ClaudeGovee\config.json`, and installed themes.
The Claude plugin still uses `.claude-plugin`, `commands/govee.md`, and its HTTP
hooks. Codex has a separate template in `codex/govee-lights` with command hooks
and a `govee` skill.

## Build

Install the .NET SDK, then run from the repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-CodexPlugin.ps1
```

The installable plugin is **`dist/codex/govee-lights`**. It includes the compiled
daemon, binding redirects, operational scripts, skill, and example themes. The
source template alone is not installable: its shared runtime files are added by
the build. This build does not stop the running daemon or change Codex settings.
`-SkipBuild` packages an existing Release build; use it only after building the
current source.

Windows, .NET Framework 4.8, and Govee Desktop are still required. This integration
does not run in a cloud environment, WSL, macOS, or Linux. Use a current Windows
Codex client with plugin and lifecycle-hook support. The local CLI inspected for
this port was 0.153.0; older clients may have fewer events or require an upgrade.

## Install into a personal marketplace

Copy the **built** `govee-lights` folder to `%USERPROFILE%\plugins\govee-lights`.
Register it in `%USERPROFILE%\.agents\plugins\marketplace.json`. For a new personal
marketplace, the file is:

```json
{
  "name": "personal",
  "interface": { "displayName": "Personal" },
  "plugins": [
    {
      "name": "govee-lights",
      "source": { "source": "local", "path": "./plugins/govee-lights" },
      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
      "category": "Productivity"
    }
  ]
}
```

If that marketplace already exists, add the plugin entry to its `plugins` array,
preserving the existing entries and marketplace name. The source path resolves
relative to the user profile, not relative to the JSON file's containing folder.
Then run:

```powershell
codex plugin add govee-lights@personal
```

Use the existing marketplace's name in place of `personal` if it is different.
The default personal marketplace is discovered automatically. In the Codex CLI,
open `/hooks`, review and trust the Govee hook definitions, then start a new
session. Installing a plugin alone does not enable its untrusted hooks. Refer to
the [official plugin packaging guide](https://developers.openai.com/plugins/build/plugins)
and [hook reference](https://learn.chatgpt.com/docs/hooks) for the host's current
installation and trust behavior.

After changing this integration, rebuild, copy the updated package to the same
personal plugin directory, reinstall with `codex plugin add`, and use a new
session. Review changed hook definitions again when Codex requests it.

## Use

In Codex, invoke the skill with `$govee status`, `$govee doctor`, or a request such
as "show my Govee light styles." Claude's `/govee` command remains available in
Claude Code. Both use the same CLI and settings.

An existing configured Govee setup needs no second API GUID. For a first setup,
run the packaged `scripts/Govee-Cli.ps1 guid <value>` with the GUID from Govee
Desktop's Settings > API, then `doctor`. Keep Govee Desktop running normally.

If an older daemon is already running, restart it once with `$govee restart` to
load the new Codex tool mappings. That restarts the shared daemon for both hosts.

## Activity coverage

| Codex event | Light behavior |
| --- | --- |
| `SessionStart` | Register an idle session; start the daemon if needed |
| `UserPromptSubmit` | Thinking; restart the daemon if it has idled out |
| `PreToolUse` | Shell, edit, MCP, or other tool activity |
| `PermissionRequest` | Waiting for the user |
| `PostToolUse` | Return to thinking; structured tool failures show error |
| `PreCompact` / `PostCompact` | Compacting / thinking |
| `SubagentStart` / `SubagentStop` | Subagent activity |
| `Stop` | Completion flourish, then idle |
| `Interrupt` | Cancel pending activity and return that session to idle |
| `SessionEnd` | Remove that session |

Codex canonical shell hooks report `Bash`; `apply_patch` is classified as an edit.
User-input tools show waiting while their invocation is active. An asynchronous
question may finish its tool call before the user replies, so its amber indication
can be brief. Hosted tools such as hosted web search do not emit local tool hooks.
Codex does not expose all Claude hooks, including `Notification`,
`PostToolUseFailure`, and `StopFailure`. The bridge recognizes a nonzero structured
`tool_response.exit_code` or boolean `tool_response.isError`; other failure output
formats remain ordinary tool completions. It does not guess errors from prose.

Hook commands run synchronously to preserve delivery order across a session.
PowerShell startup adds overhead to each event; these are slower than Claude's
direct HTTP hooks. Each HTTP attempt has a 250 ms timeout. Bootstrap can retry
for six seconds on session start or prompt submission; hook limits are ten
seconds for bootstrap and two seconds otherwise. Failed lighting delivery exits
successfully and emits no approval, blocking, or continuation decisions.

Only event name, a `codex:`-prefixed session ID, working directory, and tool name
reach the daemon. Prompts, arguments, tool output, and transcripts are not forwarded.
If changing port 17321, update the Codex hook command to pass `-Port` as well as
the shared daemon configuration and Claude HTTP hooks.

## Verify without lights

```powershell
scripts\Test-HookMapper.ps1
scripts\Test-CodexHooks.ps1
scripts\Test-Repo.ps1
```

The mapper tests cover both hosts and cancellation. The bridge tests use mocks
and a disposable loopback server, never the real daemon. Physical behavior still
needs a live Codex session with trusted hooks and Govee Desktop running.
