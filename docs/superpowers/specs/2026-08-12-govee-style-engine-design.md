# Govee style engine — design

Date: 2026-08-12
Status: approved, ready for planning

## Problem

Per-state colour and animation are already configurable. `StateStyle` exposes
`Color`, `Effect`, `Hz` and `Brightness`; the `States` block in
`%LOCALAPPDATA%\ClaudeGovee\config.json` hot-reloads on save. Four things are
nonetheless wrong with it:

1. **Partial overrides silently do nothing.** `Palette.For` discards a configured
   entry outright unless it carries a `Color`, falling back to the whole built-in
   default. Setting only `Hz` on a state has no effect and reports no error.
2. **The effect vocabulary is thin.** Six effects, no second colour, no direction,
   no easing, no control over trail length or breathe depth.
3. **Every device renders identically.** A desk strip and a ceiling strip cannot
   behave differently.
4. **None of it is discoverable.** The configuration surface is documented only in
   `config/config.example.json`, which a user has no particular reason to open.

This spec covers the rendering engine only. A companion spec covers the control
plane — `/govee set`, `/govee styles`, theme presets, config write-back — and
depends on the vocabulary defined here.

## Approach

Effects become a two-stage pipeline rather than a widening switch statement.

An effect is a pure shape function that knows nothing about modifiers:

```csharp
double[] Shape(double t, double tInState, int n, ResolvedStyle s)   // weights in 0..1
```

Shared post-stages then run in a fixed order, implemented once and applying to
every effect by construction:

1. **direction** — an index transform on the weight array. `forward` leaves it
   alone; `reverse` mirrors it (`i → n-1-i`), which reverses a travelling wave and
   also flips the fill direction of `wipe` and `progress`; `pingpong` applies the
   mirror on odd cycles only, where the cycle index is `floor(t * Hz)`, so motion
   bounces rather than wrapping. For whole-device effects (`n == 1`) direction is a
   no-op.
2. **easing** — a curve applied to each weight (`linear`, `sine`, `cubic`, `expo`)
3. **depth** — rescale weights into `[Depth, 1]` so the colour never fully vanishes
4. **colour** — `Color2 == null ? Color.Scale(w) : Rgb.Lerp(Color2, Color, w)`

Effects whose character is hue rather than intensity return `Rgb[]` directly and
skip stage 4. `rainbow` is the only such effect today.

The alternative — extending the existing `switch` in `Effects.Render` with five
new cases, each re-implementing direction, easing, two-colour blending and trail
length — was rejected. Eleven cases times four modifiers is forty-four
opportunities for two effects to disagree about what `reverse` means.

## Data model

`StateStyle` becomes fully nullable. `null` means "inherit", unambiguously, which
is what makes the merge below well-defined.

```csharp
public class StateStyle
{
    public string  Color       { get; set; }  // null = inherit
    public string  Color2      { get; set; }  // null = single-colour: weight scales toward black
    public string  Effect      { get; set; }
    public double? Hz          { get; set; }
    public int?    Brightness  { get; set; }  // null = inherit; -1 = leave alone (unchanged meaning)
    public string  Direction   { get; set; }  // forward | reverse | pingpong
    public string  Easing      { get; set; }  // linear | sine | cubic | expo
    public double? Tail        { get; set; }  // chase/comet trail length, fraction of the strip
    public double? Depth       { get; set; }  // 0..1 intensity floor
    public double? FullSeconds { get; set; }  // progress: seconds to a full bar
}
```

`DeviceConfig` gains `public Dictionary<string, StateStyle> States { get; set; }`,
defaulting to empty.

`ResolvedStyle` is the fully-populated, non-nullable result the effects consume.
Unknown string values (`Effect`, `Direction`, `Easing`) fall back to the default
for that field and log a warning naming the state and the offending value — a
typo must not silently change behaviour.

## Style resolution

A new `Palette.Resolve(cfg, device, state)` layers four sources field by field,
non-null winning:

1. **engine defaults for the resolved effect** — the base layer, always complete.
   Most fields are effect-independent (`Direction: forward`, `Easing: linear`,
   `FullSeconds: 30`), but `Depth` and `Tail` are not: `breathe` defaults to
   `Depth: 0.35` and `pulse` to `Depth: 0.08`, preserving today's hardcoded floors,
   while `chase` and `comet` carry the `Tail` values matching their current
   falloff. This layer is keyed by effect, so it is resolved after `Effect` itself
   is known.
2. the built-in default for the state — `Palette.Defaults()`, which continues to
   specify only `Color`, `Effect`, `Hz` and `Brightness`
3. `cfg.States[state]`
4. `device.States[state]`

This single function fixes the partial-override bug and delivers per-device
overrides at the same time: per-device is one more layer on the same merge, not
separate machinery.

**Back-compat.** Today a `States` entry lacking `Color` is discarded wholesale, so
its other fields were never read. Afterwards, a partial entry applies. A user with
a half-filled entry sitting inert in their config will see it take effect. The
entry already expressed intent, so this is the fix rather than a regression, but
it is a visible behaviour change and belongs in the release notes.

## Effect roster

Weight-based, and therefore modifier-complete for free:

| effect     | shape                            | notes                                |
|------------|----------------------------------|--------------------------------------|
| `solid`    | all 1                            |                                      |
| `breathe`  | sine                             | `Depth` replaces the hardcoded 0.35   |
| `pulse`    | cubed sine                       | `Depth` replaces the hardcoded 0.08   |
| `blink`    | square                           |                                      |
| `chase`    | head with falloff                | width from `Tail`                    |
| `comet`    | exponential trail                | length from `Tail`                   |
| `wipe`     | fills 0→n, then clears           |                                      |
| `progress` | fills by `tInState / FullSeconds`| clamps at full and holds              |
| `sparkle`  | per-segment twinkle              | hashed, see below                    |

Hue-based, skipping the colour stage:

| effect    | shape                          | notes                          |
|-----------|--------------------------------|--------------------------------|
| `rainbow` | hue = `(i / n + t * Hz) mod 1` | needs a new `Rgb.FromHsv`      |

`scanner` is **not** implemented as an effect. It is `chase` with
`Direction: pingpong`, which the pipeline provides for free; implementing it
separately would duplicate a modifier. It ships as a documented alias in
`config.example.json` and in `docs/EFFECTS.md`.

Spatial effects (`chase`, `comet`, `wipe`, `progress`, `rainbow`) fall back to
`breathe` when `segments <= 1`, matching the existing `goto case "breathe"`
behaviour.

**Sparkle is hashed, not random**: `hash(segmentIndex, floor(t * Hz))` rather than
`Random.Next()`. `Hz` then means twinkle rate instead of producing chaotic 25fps
strobing; the segment CSV only changes when the twinkle step advances, so the rate
limiter is not fighting the effect; and identical inputs produce identical frames,
which is what makes the engine testable without hardware.

## Renderer changes

`Effects.Render` gains time-in-state, which `progress` needs and the renderer
already tracks via `_transitionStart`:

```csharp
Frame Render(ResolvedStyle s, double t, double tInState, int segments)
```

Style resolution and the cross-fade currently sit above the device loop in
`TickOnce`. Per-device styles force both inside it: resolve per device, render per
device, emit per device. The loop remains the only place that touches the Govee
client, so rate limiting, quantisation and keepalive logic in `Emit` are unchanged.

`Frame.Brightness` is unused — `Emit` reads `style.Brightness` directly. Remove the
dead field while the file is open.

## Transitions

The existing cross-fade lerps a single colour. Two changes:

1. **Lerp `Color2` as well.** Not optional: otherwise a two-colour style fades its
   first colour while snapping its second.
2. **Blend whole frames.** During the `TransitionMs` window, render both the
   outgoing and incoming state's effects and lerp the resulting segment arrays via
   a new `Frame.Lerp`. Today chase→blink cross-fades hue but jump-cuts motion. The
   second render happens only inside the transition window, on arrays of at most a
   few dozen entries.

## Send budget

`rainbow` changes every segment every frame and will sit at the send ceiling.
`MinDeviceIntervalMs: 40` caps it at 25 sends/sec/device and the global token
bucket caps the total, so it is bounded and safe, merely expensive. This is
documented in `docs/EFFECTS.md` rather than mitigated: a per-style throttle would
be speculative, and the existing limiter already does the job.

Hashed sparkle deliberately avoids this problem by construction — its output only
changes when the twinkle step advances.

## Testing

The pipeline's dividend is that `Effects` becomes pure and deterministic. The repo
has no unit-test project — it has static PowerShell checks and hardware demo
scripts — and adding a test framework to a net48 project is disproportionate.
Instead, follow the existing philosophy of guarding the invariants that actually
break.

Add a headless mode to the daemon executable:

```
GoveeLightsDaemon.exe --dump-frames --state <name>  --segments <n> --seconds <s>
GoveeLightsDaemon.exe --dump-frames --style '<json>' --segments <n> --seconds <s>
```

`--state` resolves through the normal merge; `--style` takes a `StateStyle` object
literal so a test can exercise an effect or modifier no configured state uses.
Either way it renders frames, prints them as CSV to stdout and exits, touching no
hardware and starting no listener. `Test-Repo.ps1` then asserts:

- every effect name renders at 1, 3 and 10 segments without throwing
- every channel value lands in 0..255
- identical inputs produce identical output — guards the sparkle hashing
- the `Depth` floor is respected
- `Direction: reverse` output is the exact mirror of `forward`
- every `Effect` value in `config.example.json` is a name the engine knows

`/govee test <state>` remains the hardware check. `--dump-frames` doubles as a way
to inspect a new effect with the lights off.

## Documentation

- `config/config.example.json` — new fields, refreshed `_comment_states`
- `README.md` — a states and effects section; this is the discoverability gap
- `docs/EFFECTS.md` — new: each effect, which modifiers apply to it, the `scanner`
  alias, and the send-budget note

## Out of scope

Deferred to the control-plane spec: `/govee set`, `/govee styles`,
`/govee preview`, `/govee reset`, named theme presets, and daemon-side config
write-back. Also out of scope: data-driven effect definitions in config, and any
change to hook mapping or state resolution.
