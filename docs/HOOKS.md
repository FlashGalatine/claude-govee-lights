# Why `hooks/hooks.json` looks the way it does

JSON has no comments, so the reasoning lives here.

## One `command` hook, everything else `http`

`SessionStart` is the only `command` hook. It has to bootstrap the daemon, so it cannot
assume the daemon already exists. It is `async: true`, and `Ensure-Daemon.ps1` always
exits 0 — a command hook exiting 2 is a *blocking* error that would surface to the user.
Ambient lighting is never worth interrupting a session for.

Every other event is an `http` hook posting to `127.0.0.1:17321`. Measured round trip is
**1–2 ms**, versus a process spawn per event for the command equivalent.

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
