---
description: Control and inspect the Govee activity-light daemon
argument-hint: "status | guid <value> | styles [state] | set <state> --color RRGGBB ... | preview <state> | reset <state>|--all | save | revert | theme list|apply|save|install | devices | test <state> | on | off | refresh | restart | logs | doctor"
allowed-tools: ["Bash"]
---

Run the Govee CLI with the user's arguments and report the result.

!`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Govee-Cli.ps1" $ARGUMENTS`

Present the output above to the user directly. It is already formatted for reading —
do not reformat it into a table or add commentary unless something is clearly wrong.

If the output says the daemon is not running, offer to start it with
`${CLAUDE_PLUGIN_ROOT}/scripts/Ensure-Daemon.ps1`, or to build it first with
`${CLAUDE_PLUGIN_ROOT}/scripts/Build.ps1 -Restart`.

If the output says there is no API GUID (from `doctor`, or a daemon that exits with
`no_guid`), tell the user to copy it from Govee Desktop ▸ Settings ▸ API and run
`/govee guid <value>` — that writes it to config.json and starts the daemon.

If `doctor` reports that the pipe is not writable, the cause is almost always that
Govee Desktop is running as administrator — tell the user to restart it normally.
Despite what Govee's own documentation says, running it elevated breaks the API for
every non-elevated client.
