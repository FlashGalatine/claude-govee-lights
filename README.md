# Claude Govee Lights

[![CI](https://github.com/FlashGalatine/claude-govee-lights/actions/workflows/ci.yml/badge.svg)](https://github.com/FlashGalatine/claude-govee-lights/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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
/govee styles     show every state's colour and effect, and its source
/govee set        change a state's style — applies live, unsaved until save
/govee preview    try a style on the lights for a few seconds, unsaved
/govee reset      clear a state (or --all) toward built-in — unsaved until save
/govee save       write pending changes to config.json
/govee revert     discard every pending change
/govee theme      list | apply <name> | save <name> | install <name>|--all
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

## Customising the lights

Each activity state has its own colour and animation. Change one from the prompt:

| Command | What it does |
|---|---|
| `/govee styles` | show everything, and where each value came from |
| `/govee set Thinking --color FF0000 --hz 2` | apply it live |
| `/govee save` | keep it |

`set` takes effect immediately but writes nothing — experiment freely. `/govee
revert` undoes it, but note the blast radius: it discards *every* pending edit and
every reset for every state, not just the one you just touched. `save` splices
only the `States` block back into `%LOCALAPPDATA%\ClaudeGovee\config.json`, so your
comments and every other setting survive untouched.

`/govee preview Thinking --effect comet --tail 2.5` shows a style for a few
seconds without changing anything at all — nothing pending, nothing to revert.

`/govee reset Thinking` is different: it clears the saved config's entry for that
state, so the state falls back toward its built-in default — but it is itself an
unsaved change, so `/govee save` is still what keeps it. And if a `set` patch is
still pending for that state, `reset` does not erase it: clearing and patching are
independent, so `reset` and `set` combine (in either order) into built-in *plus*
your patch, not a clean built-in default.

Whole palettes come as themes — `/govee theme list`, `/govee theme apply muted`,
and `/govee theme save <name>` to keep your current setup as one. Applying a theme
is total: it discards any unsaved edits, any state the theme doesn't mention falls
back to built-in, and — like `set` and `reset` — the change is itself unsaved until
`/govee save`.

Four themes are built in (`default`, `muted`, `vivid`, `mono`), and seven more ship as
example files in [themes/](themes/) — `sunset`, `ocean`, `forest`, `neon`, `candle`,
`signal` and `bubblegum`. `/govee theme list` shows them as `example` until you install one:
`/govee theme install sunset` (or `--all`) copies the file into
`%LOCALAPPDATA%\ClaudeGovee\themes\`, after which it is an ordinary saved theme —
apply it, edit the file, or delete it to uninstall. Installing never overwrites a
theme already there. Each file is exactly what `theme save` writes, so they double as
templates: copy one, rename it, change the colours.

The config file is still there and still hot-reloads, if you prefer editing it:

```json
"States": {
  "ToolShell": { "Color": "#FF7A18", "Effect": "chase", "Hz": 0.8, "Direction": "pingpong" }
}
```

Ten effects are available — `solid`, `breathe`, `pulse`, `blink`, `chase`, `comet`,
`wipe`, `progress`, `sparkle` and `rainbow` — most of them further tunable with
`Color2`, `Direction`, `Easing`, `Tail` and `Depth`, though which of those actually
do something varies by effect (`rainbow` ignores most of them; `Tail` only affects
`chase` and `comet`). Every field is optional and inherits when omitted, so you can
change one value without restating the rest. Individual devices can override any
state via a `States` block inside their `Devices` entry.

See [docs/EFFECTS.md](docs/EFFECTS.md) for the full reference. To see a state on
your lights: `/govee test <state>` forces whatever it currently resolves to for a
few seconds, while `/govee preview <state> [flags]` shows a style you haven't
applied yet — the two are not the same command.

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

## Development

```powershell
scripts\Build.ps1 -Restart      # build, stage to dist\, restart the daemon
scripts\Test-Repo.ps1           # static checks - no hardware needed
scripts\Test-Resilience.ps1     # proves a dead daemon cannot stall a session
scripts\Replay-Hooks.ps1        # drive a full session's worth of hooks
scripts\Demo-Govee.ps1          # narrated visual test across every device
```

CI runs `Test-Repo.ps1` and builds on `windows-latest`. It cannot drive lights — no
Govee Desktop on a runner — so it guards the invariants that break silently instead:
that the `App.config` binding redirect reaches the build output, that `hooks.json` stays
in sync with the scripts and port it references, and that the daemon starts, logs and
exits cleanly rather than hanging.

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

**Connection refused on every hook.** The daemon is not running. It idles out after
`IdleShutdownMinutes` (default 120) with no live sessions; submitting a prompt restarts
it via the `UserPromptSubmit` bootstrap, usually within a second. If it never comes back,
run `/govee doctor` — most likely the build is missing, or the port is taken by something
else. Set `IdleShutdownMinutes` to `0` to keep the daemon resident; it costs roughly 0.5%
CPU while idle.

Check `/govee logs` for the shutdown reason:

```
idle_shutdown    no sessions; exiting        expected, recoverable on next prompt
session_expired  no events within TTL        a session went quiet for SessionTtlMinutes
govee_init_failed                            Govee Desktop is gone or elevated
```

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
