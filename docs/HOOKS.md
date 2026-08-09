# Why `hooks/hooks.json` looks the way it does

JSON has no comments, so the reasoning lives here.

## Two `command` hooks, everything else `http`

`Ensure-Daemon.ps1` runs on **`SessionStart` and `UserPromptSubmit`**. Both are
`async: true`, and the script always exits 0 — a command hook exiting 2 is a *blocking*
error that would surface to the user. Ambient lighting is never worth interrupting a
session for.

Every other event is an `http` hook posting to `127.0.0.1:17321`. Measured round trip is
**1–2 ms**, versus a process spawn per event for the command equivalent.

### Why `UserPromptSubmit` also bootstraps

This looks redundant. It is not, and leaving it out produced a real bug.

The daemon shuts itself down after a long idle period. Originally only `SessionStart`
could restart it — but **`SessionStart` does not fire again inside an already-running
session**. So the sequence was:

```
session_start    tracking session
session_expired  no events within TTL      (a quiet stretch)
render_state     Offline
idle_shutdown    no sessions; exiting
```

…and from that moment every hook in a still-open session hit a dead port. The user saw
connection-refused errors that never stopped, because nothing could bring the daemon
back without starting a brand-new session.

`UserPromptSubmit` is the right recovery point: it fires once per turn, so the cost is
one backgrounded process per prompt, and it guarantees the daemon is alive before any
tool events follow. `Ensure-Daemon.ps1` short-circuits on `Get-Process` when the daemon
is already up, so the common case is nearly free.

**The bootstrap forwards its payload only when it actually had to start the daemon.**
When the daemon was already running, the parallel `http` hook for that same event is
already delivering it, and posting again would double up. It also forwards to `/hook`
with no `?e=` hint so the daemon reads the real `hook_event_name` — an earlier version
hardcoded `?e=session_start`, which mislabelled a recovered prompt as `Idle` instead of
`Thinking`.

Session TTL (90 min) and idle shutdown (120 min) are both deliberately longer than a
plausible coffee break. Set `IdleShutdownMinutes` to `0` to disable shutdown entirely;
the daemon costs about 0.5% CPU while idle, since the render loop drops to
`Render.IdleTickMs` when nothing is being drawn.

## Why a dead daemon is safe

`http` hooks do not support `async`, so Claude Code waits for the response. That sounds
risky until you consider the two failure modes:

- **Daemon not running** — nothing is bound to the port, the OS returns `RST`, and the
  request fails immediately as a non-blocking error.
- **Daemon hung** — the `timeout` applies. Hence 2 s everywhere, and 1 s on `SessionEnd`
  because SessionEnd hooks share a ~1.5 s budget.

### Measured, because the runtime matters more than the OS

Probing a closed loopback port, five attempts each:

```
Raw TcpClient.Connect (.NET)   2028, 2021, 2044, 2032, 2024 ms
.NET HttpClient POST           2021, 2013, 2002, 2003, 2013 ms
Node.js http.request              7.4, 1.6, 0.8, 0.7, 0.9 ms
```

**.NET stalls for a full 2 s on a refused loopback connection; Node does not.** Claude
Code runs on Node, so the number that governs hook latency is ~1 ms. Do not benchmark
this from PowerShell or C# and conclude the hooks are slow — you will be measuring a
.NET behaviour that Claude Code never experiences.

The same quirk *does* affect this repo's PowerShell scripts, which is why
`Ensure-Daemon.ps1` checks for the process with `Get-Process` before probing `/health`.

The daemon defends against the second case structurally: `MiniHttpServer`'s accept loop
hands every connection to the thread pool and never touches Govee, and `/hook` parses,
enqueues and returns `204` without doing any I/O. Govee work happens on a separate
serialized worker thread.

## The `?e=` query hint

Some events do not carry their matcher in the payload body. `Notification` is the
important one — `permission_prompt` and `idle_prompt` arrive with identical JSON but mean
opposite things (urgent attention vs. nothing happening). The URL disambiguates them, and
`HookMapper` reads the hint before falling back to `hook_event_name`.

It also future-proofs `StopFailure` subtypes (`rate_limit`, `overloaded`,
`authentication_failed`) if those ever warrant distinct colours.

## Port coupling

`17321` is hardcoded in this file because hook URLs cannot be computed at runtime. If you
change `Port` in `config.json`, you must edit `hooks/hooks.json` to match. The port sits
below the Windows ephemeral range (which starts at 49152), so it will not be claimed by an
outbound socket.

## Events deliberately not wired

`UserPromptExpansion`, `MessageDisplay`, `ConfigChange`, `CwdChanged`, `FileChanged` and
friends fire often and carry no useful activity signal. The daemon ignores unknown events
at `DEBUG` level rather than throwing, so adding one later is a one-line change here.
