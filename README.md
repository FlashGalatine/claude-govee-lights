# Claude Govee Lights

Your Govee lights react to what Claude Code is doing — dim blue when idle, purple
breathing while it thinks, a coloured chase across the segments while it runs a tool,
and an urgent amber pulse when it is waiting on you.

```
idle ──▶ thinking ──▶ tool ──▶ thinking ──▶ done ──▶ idle
                        │
                        └──▶ waiting on you  (amber pulse, outranks everything)
```

## How it works

Claude Code fires [hooks](https://code.claude.com/docs/en/hooks) on every session start,
prompt, tool call, permission prompt, error and session end. A small local daemon holds
an open connection to Govee Desktop and turns those events into light changes.

```
Claude Code session ──http POST──┐
Claude Code session ──http POST──┼──▶ 127.0.0.1:17321  GoveeLightsDaemon (net48)
Claude Code session ──http POST──┘         │
                                           │  SessionStore   per-session state
                                           │  HookMapper     event ──▶ activity
                                           │  Renderer       25fps tick, diffed
                                           ▼
                                    GoveeAPI.dll  ──named pipe──▶ Govee Desktop
                                                  ──UDP────────▶ lights
```

The daemon is a long-lived process because connecting is expensive and animation needs
persistent state. Hooks reach it over loopback HTTP in **1–2 ms**.

**A dead daemon cannot break Claude Code.** Nothing listening means an instant connection
refusal, which Claude Code treats as a non-blocking error. Only one hook is a `command`
hook, it is `async`, and it always exits 0.

## Requirements

- Windows with .NET Framework 4.8 (built into Windows 10/11)
- .NET SDK, to build the daemon
- Govee Desktop, **running normally — not as administrator** (see below)
- Settings ▸ API enabled in Govee Desktop, and its API GUID
- LAN Control enabled per device in the **Govee Home mobile app**

## Setup

```powershell
# 1. Build and start the daemon
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1 -Restart

# 2. Confirm it can see your lights
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 doctor
```

Then install the plugin in Claude Code:

```
/plugin marketplace add c:\dev\ClaudeGoveeLights
/plugin install claude-govee-lights
```

Config lives at `%LOCALAPPDATA%\ClaudeGovee\config.json` and is written with defaults on
first run, seeded with the GUID from `Govee-API-GUID.txt`. It hot-reloads on save.

## Commands

```
/govee status     daemon state, devices, live sessions
/govee devices    every Govee device and which can be driven
/govee test <s>   force a state for 8s so you can see it
/govee on|off     enable or disable rendering
/govee restart    restart the daemon
/govee logs       tail the daemon log
/govee doctor     diagnose a broken setup
```

## States

Highest priority wins when several sessions are live, so a permission prompt in one
window beats idle in another.

| Priority | State | Trigger | Colour | Effect |
|---|---|---|---|---|
| 100 | `WaitingUser` | permission prompt | amber `#FFB000` | fast pulse |
| 90 | `Error` | tool failure, turn failure | red `#FF2020` | blink |
| 75 | `ToolShell` | `Bash` | orange `#FF7A18` | chase |
| 74 | `ToolEdit` | `Edit`, `Write` | green `#22C55E` | chase |
| 65 | `ToolAgent` | subagents, `Task` | magenta `#D946EF` | comet |
| 60 | `Compacting` | `PreCompact` | teal `#00C8A0` | chase |
| 55 | `ToolMcp` | `mcp__*` | violet `#8B5CF6` | chase |
| 50 | `ToolWeb` | `WebFetch`, `WebSearch` | blue `#3B82F6` | chase |
| 45 | `ToolRead` | `Read`, `Grep`, `Glob` | cyan `#06B6D4` | chase |
| 40 | `Thinking` | prompt submitted | purple `#7B4DFF` | breathe |
| 25 | `Done` | turn complete | green `#22DD55` | solid, 4s |
| 10 | `Idle` | session start | dim blue `#1E2A3A` | slow breathe |
| 0 | `Offline` | no sessions, disabled, quiet hours | resting colour | solid |

Rapid tool bursts are coalesced: a `PostToolUse` schedules the return to `Thinking`
250 ms later, and any new `PreToolUse` cancels it. Twenty back-to-back `Read` calls
therefore render as one continuous cyan, not twenty flashes.

## Configuration

```jsonc
{
  "Enabled": true,
  "ApiGuid": "...",                 // Govee Desktop ▸ Settings ▸ API
  "Port": 17321,                    // must match hooks/hooks.json if changed
  "IsGradientOff": 1,               // gradient polarity; flip if segments look wrong
  "RestColor": "#FFD9A0",
  "OnSessionEnd": "rest",           // rest | off | hold
  "QuietHours": { "Enabled": false, "Start": "23:30", "End": "08:00" },
  "Devices": [
    { "Name": "Glide Hexa Pro", "Enabled": true, "Animate": true, "BrightnessCap": 70 }
  ],
  "Render": { "TickMs": 40, "MaxCallsPerSecGlobal": 90 }
}
```

Leave `Devices` empty to drive every LAN-enabled device automatically.

**`OnSessionEnd` cannot restore what was there before.** The Govee API exposes no way to
read a device's current colour, so `rest` means "apply `RestColor`". If you use these
lights as room lighting and care about getting a scene back, use `off`.

## Troubleshooting

Run `/govee doctor` first. The two failure modes worth knowing:

**Everything times out (~6 s) and reports a GUID error.** Your GUID is almost certainly
fine. This is a missing `System.Runtime.CompilerServices.Unsafe` binding redirect —
`GoveeLightsDaemon.exe.config` must be next to the exe. `Build.ps1` fails loudly if it
is missing. Details in [docs/API-NOTES.md](docs/API-NOTES.md).

**Fast failure (~30 ms), pipe not writable.** Govee Desktop is running as administrator.
Restart it normally. Govee's own documentation tells you to run it elevated; doing so
creates the named pipe with a DACL that locks out every non-elevated client, including
this daemon.

**Nothing happens but the API returns success.** Control commands are fire-and-forget
UDP, so success means "sent", not "acknowledged". Check LAN Control is on for the device
in the Govee Home mobile app — `/govee devices` shows which devices report it.

**Segments do not animate.** Segment colour requires Razer/DreamView mode, which the
daemon enables automatically. Close Scenic DreamView and Razer DreamView; they fight for
the same devices.

## Layout

```
.claude-plugin/    plugin manifest + local marketplace
hooks/hooks.json   the Claude Code integration contract
commands/govee.md  the /govee slash command
scripts/           build, launcher, CLI, probes, demo
src/               the daemon (C#, net48)
docs/API-NOTES.md  verified API behaviour, including the DOCX's errors
```

`docs/API-NOTES.md` is the most valuable file here. Govee's shipped documentation is
wrong in several places, and that file records what is actually true.

## License

[MIT](LICENSE).

This project does not bundle or redistribute any Govee software. `GoveeAPI.dll` is
loaded at runtime from your own Govee Desktop installation, and Govee's documentation is
referenced but not included. Govee is a trademark of its respective owner; this project
is unaffiliated with and unendorsed by Govee.
