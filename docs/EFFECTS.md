# Effects

Every animation is computed by the daemon and pushed as discrete frames — the Govee
API has no effects of its own. An effect is a *shape* producing one weight per
segment; four shared modifiers then transform it. Because the modifiers are applied
outside the effect, they work on all of them the same way.

## Style fields

| Field | Type | Meaning |
|---|---|---|
| `Color` | `#RRGGBB` | The primary colour. |
| `Color2` | `#RRGGBB` \| `none` | Optional. When set, weights blend `Color2 → Color` instead of scaling `Color` toward black. Omit it to inherit; set it to `none` to override an inherited second colour back to single-colour. |
| `Effect` | name | See the table below. |
| `Hz` | number | Rate. Cycles per second for time-based effects; twinkle steps per second for `sparkle`. |
| `Brightness` | 0–100 | Device brightness. `-1` leaves it alone. |
| `Direction` | `forward` \| `reverse` \| `pingpong` | `reverse` mirrors the strip; `pingpong` alternates each cycle so motion bounces. No effect on a single-zone device. |
| `Easing` | `linear` \| `sine` \| `cubic` \| `expo` | Curve applied to the weights. |
| `Tail` | number | Trail length as a multiple of the effect's natural length. `1.0` is default; `2.0` is twice as long. |
| `Depth` | 0–1 | Intensity floor. Weights are rescaled into `[Depth, 1]`, so the colour never fully disappears. |
| `FullSeconds` | number | `progress` only: seconds until the bar is full. |

Any field may be omitted. Omitted means *inherit* — from the global `States` entry,
then the built-in state default, then the effect's own default. This is why you can
set just `Hz` on one state and leave everything else alone.

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

The modifier pipeline gives this for free, so implementing it separately would be
duplicating `Direction`.

## Cost

`rainbow` recomputes every segment on every frame, so it emits a new segment update
at the maximum permitted rate. This is bounded — `MinDeviceIntervalMs` caps each
device at 25 updates/sec and `MaxCallsPerSecGlobal` caps the total — but it will sit
at that ceiling for as long as the state is active. Everything else changes far less
often, and `sparkle` in particular only emits when its twinkle step advances.

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
file, and `--from <state>` dumps a cross-fade. Output must be redirected: the daemon
is a windowless executable, so `&` alone will not capture it.
