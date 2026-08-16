# Effects

Every animation is computed by the daemon and pushed as discrete frames — the Govee
API has no effects of its own. An effect is a *shape* producing one weight per
segment; a shared pipeline of stages — direction, easing, depth, then colour — then
transforms most of them the same way, which is what keeps ten effects from inventing
ten different meanings for "reverse." That pipeline is not perfectly uniform, though:
`rainbow` bypasses it entirely and computes colour directly (see its row below), and
`Direction` reaches different effects differently (see the field table).

## Style fields

| Field | Type | Meaning |
|---|---|---|
| `Color` | `#RRGGBB` | The primary colour. Ignored by `rainbow`. Must be exactly six hex digits, with or without the leading `#`; anything else (`#FF00`, `red`) falls back to grey `#787878` and logs a `style_unknown_value` warning. |
| `Color2` | `#RRGGBB` \| `none` | Optional. When set, weights blend `Color2 → Color` instead of scaling `Color` toward black. Omit it to inherit; set it to `none` to override an inherited second colour back to single-colour. Ignored by `rainbow`. An unparseable value falls back to black `#000000` and warns, exactly as `Color` does. |
| `Effect` | name | See the table below. An unrecognised name falls back to `solid` — see "Defaults and out-of-range values" below. |
| `Hz` | number | Rate. Cycles per second for time-based effects; twinkle steps per second for `sparkle`. Defaults to `0.6`; a value `<= 0` also falls back to `0.6`. |
| `Brightness` | 0–100 | Device brightness. Only sent when it resolves `> 0` — both `-1` (the default) and `0` leave the device's brightness alone. When it is sent, it is also capped by that device's own `BrightnessCap`. |
| `Direction` | `forward` \| `reverse` \| `pingpong` | `reverse` mirrors whatever array the shape produced: a no-op for the effects that render one weight for the whole device (`solid`, `breathe`, `pulse`, `blink`), but a real mirror for every effect marked "needs segments" below, for `rainbow`, and for `sparkle`'s per-segment array once there is more than one segment. `pingpong` is narrower — it only applies to the effects marked "needs segments" (which includes `rainbow`), and only with more than one segment; it does nothing for `solid`, `breathe`, `pulse`, `blink` or `sparkle`, regardless of segment count. An unrecognised value falls back to `forward`. |
| `Easing` | `linear` \| `sine` \| `cubic` \| `expo` | Curve applied to the weights. Ignored by `rainbow`. Defaults to `linear`; an unrecognised value also falls back to `linear`. |
| `Tail` | number | `chase` and `comet` only: trail length as a multiple of the effect's natural length. `1.0` is default; `2.0` is twice as long. Silently has no effect on any other effect. A value `<= 0` falls back to `1.0`. |
| `Depth` | 0–1 | Intensity floor. Weights are rescaled into `[Depth, 1]`, so the colour never fully disappears. Ignored by `rainbow`. Defaults to `0`; only `breathe`, `pulse`, `blink` and `sparkle` raise it via their own built-in defaults (see the effects table) — every other effect keeps the base value of `0`. Values outside `0..1` are clamped to the nearer end. |
| `FullSeconds` | number | `progress` only: seconds until the bar is full. Defaults to `30`; a value `<= 0` also falls back to `30`. |

Any field may be omitted. Omitted means *inherit*, and the layers are, strongest
first:

1. a device's own `States` entry (set inside that device's block in `Devices`)
2. **unsaved edits** from `/govee set` or `/govee theme apply` — stronger than the
   global `States` entry, weaker than a device's own override, which is why
   `/govee save` can write them straight into the global block
3. the global `States` entry in `config.json`
4. the built-in default for that state
5. the effect's own default

`/govee reset` acts on layer 3, not layer 2: it removes a state's global `States`
entry rather than adding anything of its own, so the state falls through to
whatever survives beneath it — including a patch from `/govee set` still sitting in
layer 2, if one is pending for that state. That is why `reset` and `set` combine,
in either order, into built-in *plus* your patch rather than a clean built-in
default.

This is why you can set just `Hz` on one state and leave everything else alone, and
why one device can override a single field of one state without restating the rest.

`/govee styles` names the layer each value came from, and marks unsaved edits.
Preview (`/govee preview`) is stronger than all of them and expires on its own — it
is a look, not an edit.

## Defaults and out-of-range values

The table above notes each field's fallback inline; the short version is that nothing
you omit or mistype leaves a field unset. Two kinds of correction happen at resolve
time:

- **Omitted fields** inherit down the chain above, ending at the built-in defaults
  listed in the table (`Hz` 0.6, `Direction` forward, `Easing` linear, `Tail` 1.0,
  `Depth` 0, `FullSeconds` 30).
- **Present but nonsensical values** are corrected rather than left broken: `Hz`,
  `Tail` and `FullSeconds` fall back to their defaults if `<= 0`; `Depth` is clamped
  into `0..1`; an unrecognised `Effect`, `Direction` or `Easing` falls back to
  `solid`, `forward` or `linear` respectively; and an unparseable `Color` or `Color2`
  falls back to grey `#787878` or black `#000000`.

An unrecognised `Effect`, `Direction`, `Easing`, `Color` or `Color2` logs a
`style_unknown_value` warning, once per distinct bad value. The numeric corrections
(`Hz`, `Tail` and `FullSeconds` falling back, `Depth` being clamped) are silent — it
is worth checking `/govee logs` after hand-editing a config, since
a typo does not otherwise announce itself beyond the lights not doing what you
expected. Under `--dump-frames` the same warnings go to **stderr**, leaving the frame
stream on stdout clean.

The *keys* of a `States` map are checked too. A key that is not one of the activity
names (`Idle`, `Thinking`, `ToolRead`, `ToolEdit`, `ToolShell`, `ToolWeb`, `ToolMcp`,
`ToolAgent`, `ToolOther`, `Compacting`, `WaitingUser`, `Error`, `Done`, `Offline`) is
never looked up, so it is kept but logged once as `config_unknown_state`. Key
matching itself is case-insensitive: `"thinking"` and `"Thinking"` are the same
state.

## Effects

| Effect | Needs segments | Description |
|---|---|---|
| `solid` | no | Constant colour. |
| `breathe` | no | Gentle sine. Defaults to `Depth: 0.35`. |
| `pulse` | no | Sharper — sits dark and snaps bright. Defaults to `Easing: cubic`, `Depth: 0.08`. |
| `blink` | no | Hard on/off. Defaults to `Depth: 0.06`. |
| `chase` | yes | A lit head running the strip with a short falloff. `Tail` widens it. |
| `comet` | yes | A head with an exponentially decaying trail. `Tail` lengthens it. |
| `wipe` | yes | Fills the strip, then clears it from the same end. |
| `progress` | yes | Fills according to how long the state has been active. See `FullSeconds`. |
| `sparkle` | no | Random-looking twinkle. `Hz` sets the twinkle rate. Defaults to `Depth: 0.06`. Paints per segment when there is more than one, but reads fine as a random blink on a single zone, so it needs no fallback. |
| `rainbow` | yes | Hue sweep across the strip. Ignores `Color`, `Color2`, `Easing` and `Depth` — but does honour `Direction`, including `pingpong`. |

Effects marked "needs segments" fall back to `breathe` on a single-zone device.

### scanner

`scanner` is not a separate effect — it is `chase` with `Direction: pingpong`:

```json
"ToolShell": { "Color": "#FF7A18", "Effect": "chase", "Direction": "pingpong", "Hz": 0.8 }
```

The shared pipeline gives this for free, so implementing it separately would be
duplicating `Direction`.

## Cost

`rainbow` recomputes every segment on every frame, so it emits a new segment update
as fast as it is allowed to. That allowance is `MinSegmentIntervalMs` (default 200ms,
i.e. 5 updates/sec per device), which paces every segment-path write — deliberately
far below the 25/sec that `MinDeviceIntervalMs` permits the colour path. The strip
hardware wedges under sustained ~20+/sec segment floods, ignoring every write for
tens of seconds while returning success for each one (camera-verified 2026-08-15;
`scripts/Test-Emits.ps1` guards the pacing). Everything else changes far less often,
and `sparkle` in particular only emits when its twinkle step advances.

Two more timing behaviours worth knowing, same root cause: transitions into or out of
a segment-rendering state jump-cut rather than cross-fade (a blended fade emits a
fresh segment CSV every tick — exactly the flood above), and for ~`SegmentEngageMs`
(default 5s) after a DreamView prime the daemon sends a solid average instead of
segment frames, because writes inside the engagement window render flattened anyway.
In practice: a segment state entered shortly after daemon start shows its colour
immediately and starts moving a few seconds later.

## Seeing an effect without hardware

The daemon can render frames to stdout and exit:

```powershell
Start-Process -FilePath dist\daemon\GoveeLightsDaemon.exe -NoNewWindow -Wait `
  -ArgumentList '--dump-frames','--style','{"Effect":"comet","Color":"#FF7A18","Tail":2.0}',
                '--segments','10','--seconds','2' `
  -RedirectStandardOutput frames.csv
```

`--state <name>` renders a configured state instead of a literal style, `--device
<name>` applies that device's overrides, `--config <path>` reads a specific config
file, `--from <state>` dumps a cross-fade, and `--fps <n>` sets the sample rate
(default `25`). Output must be redirected: the daemon is a windowless executable, so
`&` alone will not capture it.

A few flags interact in ways that are not obvious: `--style` makes `--state`,
`--config` and `--device` inert — a literal style resolves with no config involved at
all. `--device` only has anything to look up when `--config` is also given; with a
config present, a `--device` name that is not in it is an error (stderr, exit 2)
rather than a silent fall-back to the global style. And `--from` always resolves the
earlier state against the built-in defaults, ignoring both `--config` and `--device`,
so a dumped cross-fade never reflects your config even when the target state does.

Warnings go to stderr and frames to stdout, so redirecting only stdout still lets a
typo reach you.
