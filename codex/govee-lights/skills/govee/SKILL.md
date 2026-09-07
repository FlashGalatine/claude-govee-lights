---
name: govee
description: Control and inspect local Govee activity lights on Windows, diagnose the Govee daemon, and adjust its colors, effects, or themes. Use for Govee light requests or explicit $govee commands.
---

Run the shared PowerShell CLI with the user's requested command. Resolve the plugin
root as two directories above this SKILL.md's directory; use its absolute path,
because the current workspace may be elsewhere. The plugin hook environment is
not necessarily present in an interactive tool call.

```powershell
& '<plugin-root>/scripts/Govee-Cli.ps1' status
```

With no arguments, use `status`. Pass each argument separately using PowerShell
quoting or a string array; never evaluate user text as PowerShell source.

Available commands:

- `status`, `devices`, `doctor`, `logs`, `refresh`, `on`, `off`, `restart`
- `guid <value>` saves the Govee Desktop API GUID and starts the daemon.
- `test <state>` shows a state briefly on the actual lights.
- `styles [state]`, `set <state> [flags]`, `preview <state> [flags]`
- `reset <state>|--all`, `save`, `revert`
- `theme list|apply <name>|save <name>|install <name>|install --all`

Style flags include `--color RRGGBB`, `--effect`, `--hz`, `--brightness`, `--color2`,
`--direction`, `--easing`, `--tail`, `--depth`, and `--fullseconds`. Read
[the effect reference](../../docs/EFFECTS.md) when the user needs effect details.
That reference uses Claude's `/govee` spelling; in Codex use `$govee` or run the CLI.

`set`, `reset`, and `theme apply` change the live lights but need `save` to persist.
`revert` discards all pending style changes. Applying a theme also discards pending
edits. `preview` does not alter saved or pending styles. Preserve the scope of the
user's requested change; explain these broader effects when relevant.

Both Claude Code and Codex share port 17321 and
`%LOCALAPPDATA%\ClaudeGovee\config.json`. Existing GUIDs and themes work in both.
If the daemon is stopped, run `<plugin-root>/scripts/Ensure-Daemon.ps1` when starting
it is needed for the request. A missing executable requires rebuilding the Codex
package from the source repository with `scripts/Build-CodexPlugin.ps1`.

For setup problems, use `doctor`. A missing GUID comes from Govee Desktop's Settings
> API; do not invent one. If the pipe is not writable, Govee Desktop may be running
as administrator and needs to be restarted normally. Keep GUID values out of
summaries. Report CLI results concisely and distinguish daemon status from confirmed
physical light behavior.
