# Govee Style Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Govee daemon's fixed six-effect switch statement with a composable effects pipeline that supports two-colour styles, direction, easing, depth, trail length, four new effects, and per-device style overrides.

**Architecture:** An effect becomes a pure shape function returning per-segment weights in `0..1`. Shared post-stages (direction, easing, depth, colour mapping) then run in a fixed order, so every modifier is implemented once and applies to every effect. Style values resolve through a four-layer merge (effect defaults, state defaults, config, device) where `null` means inherit. Hue-based effects return `Rgb[]` and skip the colour stage.

**Tech Stack:** C# 7.3 targeting net48, `System.Web.Script.Serialization.JavaScriptSerializer` for JSON, PowerShell 5.1 for tests. No new NuGet dependencies.

## Global Constraints

- **Target framework is `net48` and language version is `7.3`.** No switch expressions, no `??=`, no target-typed `new`, no nullable reference types, no records. `double?` / `int?` value nullables are fine.
- **No new NuGet packages.** `GoveeAPI.dll` binds its own `Newtonsoft.Json` and `System.Text.Json`; shipping competing copies breaks the runtime. Use `JavaScriptSerializer` only.
- **New `.cs` files are picked up automatically** — the csproj is SDK-style with default globbing. Do not add `<Compile>` items.
- **`OutputType` is `WinExe`.** The process has no console unless one is allocated. Headless output must go to `Console.Out` with stdout redirected by the caller; tests must use `Start-Process -Wait -RedirectStandardOutput`, not bare `&`.
- **Every number formatted for output or parsed from an argument uses `CultureInfo.InvariantCulture`.** A comma decimal separator would corrupt the CSV the tests parse.
- **Effect, direction and easing names are lowercase and compared case-insensitively**, matching the existing `(style.Effect ?? "solid").ToLowerInvariant()`.
- **Build with:** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1`
- **Static tests:** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1`

## File Structure

| File | Responsibility |
|---|---|
| `src/GoveeLights.Daemon/Rgb.cs` | **Create.** The `Rgb` struct and colour maths, moved out of `Effects.cs`. Gains `FromHsv` in Task 4. |
| `src/GoveeLights.Daemon/Palette.cs` | **Create.** `ResolvedStyle`, per-effect defaults, per-state defaults, and the four-layer merge. Moved out of `Effects.cs`. |
| `src/GoveeLights.Daemon/Effects.cs` | **Modify.** Shrinks to `Frame` plus the pipeline: shape functions and the four post-stages. |
| `src/GoveeLights.Daemon/Config.cs` | **Modify.** `StateStyle` becomes nullable; `DeviceConfig` gains `States`. |
| `src/GoveeLights.Daemon/Renderer.cs` | **Modify.** Style resolution and cross-fade move inside the device loop. |
| `src/GoveeLights.Daemon/FrameDump.cs` | **Create.** The headless `--dump-frames` harness. Kept out of `Program.cs`, which is already the largest file. |
| `src/GoveeLights.Daemon/Program.cs` | **Modify.** One early dispatch line in `Main`. |
| `scripts/Test-Repo.ps1` | **Modify.** New "Effects engine" section driving the harness. |
| `tests/golden/*.csv` | **Create.** Committed reference frames for the six existing effects. |
| `config/config.example.json`, `README.md`, `docs/EFFECTS.md` | **Modify / create.** Documentation. |

`Effects.cs` currently holds four concerns (`Rgb`, `Frame`, `Effects`, `Palette`) in 164 lines. This work would take it past 400, so the split happens in Task 1 before anything grows.

---

### Task 1: Headless frame harness and golden capture

Builds the regression net **before** any behaviour changes. The goldens captured here are what prove Tasks 2–3 refactor without altering output.

**Files:**
- Create: `src/GoveeLights.Daemon/Rgb.cs`
- Create: `src/GoveeLights.Daemon/FrameDump.cs`
- Modify: `src/GoveeLights.Daemon/Effects.cs` (remove the `Rgb` struct only)
- Modify: `src/GoveeLights.Daemon/Program.cs:31-34`
- Create: `tests/golden/*.csv`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: existing `Effects.Render(StateStyle, double t, int segments, Rgb color)`, `Palette.For(Dictionary<string,StateStyle>, Activity)`.
- Produces: `FrameDump.Run(string[] args) -> int`; CSV on stdout, one line per frame, `t,#RRGGBB,#RRGGBB,...` with `#`-prefixed comment lines. Tasks 2–7 all test through this.

- [ ] **Step 1: Move the `Rgb` struct into its own file**

Create `src/GoveeLights.Daemon/Rgb.cs` with the struct **exactly as it exists today** — no behaviour change:

```csharp
using System;
using System.Globalization;

namespace GoveeLights
{
    public struct Rgb
    {
        public int R, G, B;
        public Rgb(int r, int g, int b) { R = r; G = g; B = b; }

        public static Rgb Parse(string hex, Rgb fallback)
        {
            if (string.IsNullOrEmpty(hex)) return fallback;
            hex = hex.Trim().TrimStart('#');
            if (hex.Length != 6) return fallback;
            int v;
            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) return fallback;
            return new Rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
        }

        public Rgb Scale(double k) => new Rgb(Clamp(R * k), Clamp(G * k), Clamp(B * k));

        public static Rgb Lerp(Rgb a, Rgb b, double t)
        {
            if (t <= 0) return a;
            if (t >= 1) return b;
            return new Rgb(Clamp(a.R + (b.R - a.R) * t), Clamp(a.G + (b.G - a.G) * t), Clamp(a.B + (b.B - a.B) * t));
        }

        public string ToHex() => "#" + R.ToString("X2") + G.ToString("X2") + B.ToString("X2");

        public int MaxDelta(Rgb o) =>
            Math.Max(Math.Abs(R - o.R), Math.Max(Math.Abs(G - o.G), Math.Abs(B - o.B)));

        static int Clamp(double d) => d < 0 ? 0 : (d > 255 ? 255 : (int)Math.Round(d));
    }
}
```

Then delete lines 7–37 of `src/GoveeLights.Daemon/Effects.cs` (the `Rgb` struct) and drop the now-unused `using System.Globalization;` from that file.

- [ ] **Step 2: Write the harness**

Create `src/GoveeLights.Daemon/FrameDump.cs`:

```csharp
using System;
using System.Globalization;
using System.Linq;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>
    /// Renders frames to stdout and exits, touching no hardware and binding no port.
    ///
    /// This exists because Effects is pure and deterministic but the project has no
    /// unit-test project - net48 plus a hardware dependency makes one disproportionate.
    /// Dumping frames lets Test-Repo.ps1 assert on real render output in CI, and lets a
    /// human eyeball a new effect with the lights off.
    /// </summary>
    public static class FrameDump
    {
        public static int Run(string[] args)
        {
            var segments = ArgInt(args, "--segments", 10);
            var seconds  = ArgDouble(args, "--seconds", 2.0);
            var fps      = ArgInt(args, "--fps", 25);
            var stateName = Arg(args, "--state", null);
            var styleJson = Arg(args, "--style", null);

            if (fps < 1) fps = 1;
            if (segments < 1) segments = 1;

            StateStyle style;
            if (!string.IsNullOrEmpty(styleJson))
            {
                try { style = new JavaScriptSerializer().Deserialize<StateStyle>(styleJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --style: " + ex.Message); return 2; }
                if (style == null) { Console.Error.WriteLine("bad --style: null"); return 2; }
            }
            else
            {
                Activity a;
                if (!Enum.TryParse(stateName ?? "Thinking", true, out a))
                {
                    Console.Error.WriteLine("unknown --state: " + stateName);
                    return 2;
                }
                style = Palette.For(null, a);
            }

            var color = Rgb.Parse(style.Color, new Rgb(120, 120, 120));

            var w = Console.Out;
            w.WriteLine("# effect=" + (style.Effect ?? "solid") +
                        " hz=" + style.Hz.ToString("0.###", CultureInfo.InvariantCulture) +
                        " color=" + color.ToHex() +
                        " segments=" + segments + " fps=" + fps);

            var frames = (int)Math.Round(seconds * fps);
            for (int i = 0; i < frames; i++)
            {
                var t = (double)i / fps;
                var f = Effects.Render(style, t, segments, color);
                var cells = f.Segments ?? new[] { f.Solid };
                w.WriteLine(t.ToString("0.000", CultureInfo.InvariantCulture) + "," +
                            string.Join(",", cells.Select(c => c.ToHex()).ToArray()));
            }
            w.Flush();
            return 0;
        }

        static string Arg(string[] args, string name, string dflt)
        {
            for (int i = 0; i < args.Length - 1; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return dflt;
        }

        static int ArgInt(string[] args, string name, int dflt)
        {
            int v;
            return int.TryParse(Arg(args, name, null), NumberStyles.Integer, CultureInfo.InvariantCulture, out v) ? v : dflt;
        }

        static double ArgDouble(string[] args, string name, double dflt)
        {
            double v;
            return double.TryParse(Arg(args, name, null), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : dflt;
        }
    }
}
```

- [ ] **Step 3: Dispatch to it from `Main`**

In `src/GoveeLights.Daemon/Program.cs`, insert as the **first two lines** of `Main`, above the existing `var console = args.Any(...)` at line 33:

```csharp
            // Headless render dump: no config dir, no logging, no port. Must come first.
            if (args.Any(a => string.Equals(a, "--dump-frames", StringComparison.OrdinalIgnoreCase)))
                return FrameDump.Run(args);
```

- [ ] **Step 4: Build and check the harness runs**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds. Then:

```powershell
$exe = 'src\GoveeLights.Daemon\bin\Release\net48\GoveeLightsDaemon.exe'
Start-Process -FilePath $exe -ArgumentList '--dump-frames','--state','Thinking','--segments','3','--seconds','0.2' `
    -NoNewWindow -Wait -RedirectStandardOutput 'out.txt'
Get-Content out.txt
```

Expected: a `# effect=breathe ...` comment line followed by 5 CSV lines of `#RRGGBB` triples. If the file is empty, stdout redirection failed — confirm `Start-Process -RedirectStandardOutput` is used and not `&`.

- [ ] **Step 5: Capture the golden frames**

```powershell
$exe = 'src\GoveeLights.Daemon\bin\Release\net48\GoveeLightsDaemon.exe'
New-Item -ItemType Directory -Force tests\golden | Out-Null
$cases = @{
  'solid'   = '{"Color":"#3366CC","Effect":"solid","Hz":0.6}'
  'breathe' = '{"Color":"#3366CC","Effect":"breathe","Hz":0.6}'
  'pulse'   = '{"Color":"#3366CC","Effect":"pulse","Hz":0.6}'
  'blink'   = '{"Color":"#3366CC","Effect":"blink","Hz":0.6}'
  'chase'   = '{"Color":"#3366CC","Effect":"chase","Hz":0.6}'
  'comet'   = '{"Color":"#3366CC","Effect":"comet","Hz":0.6}'
}
foreach ($k in $cases.Keys) {
  Start-Process -FilePath $exe -NoNewWindow -Wait `
    -ArgumentList '--dump-frames','--style',$cases[$k],'--segments','10','--seconds','4','--fps','25' `
    -RedirectStandardOutput "tests\golden\$k.csv"
}
Get-ChildItem tests\golden
```

Expected: six files, each with 101 lines (1 comment + 100 frames).

- [ ] **Step 6: Add the Test-Repo section**

In `scripts/Test-Repo.ps1`, insert this immediately **before** the `# --------------------------------------------------------------- housekeeping` section near line 231:

```powershell
# ------------------------------------------------------- effects engine
Section 'Effects engine'
# Effects is pure and deterministic, so CI can assert on real render output with no
# hardware. The goldens are the regression net for the pipeline refactor: any change
# to the six original effects' output is a bug unless it is deliberate.
$exe = @(
    (Join-Path $root 'dist/daemon/GoveeLightsDaemon.exe'),
    (Join-Path $root 'src/GoveeLights.Daemon/bin/Release/net48/GoveeLightsDaemon.exe'),
    (Join-Path $root 'src/GoveeLights.Daemon/bin/Debug/net48/GoveeLightsDaemon.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Invoke-Dump {
    param([string[]] $DumpArgs)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # Start-Process, not '&': the daemon is a WinExe, so stdout must be explicitly
        # redirected for the parent to see anything.
        Start-Process -FilePath $exe -ArgumentList (@('--dump-frames') + $DumpArgs) `
            -NoNewWindow -Wait -RedirectStandardOutput $tmp | Out-Null
        return @(Get-Content $tmp)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

if (-not $exe) {
    Write-Host '  SKIP  no build output found (run scripts\Build.ps1)' -ForegroundColor DarkGray
} else {
    $effects = @('solid','breathe','pulse','blink','chase','comet')

    # Renders at all three segment shapes: 1 (whole-device), 3 (short strip), 10 (typical).
    foreach ($e in $effects) {
        $bad = $false
        foreach ($n in 1, 3, 10) {
            $lines = Invoke-Dump @('--style', "{`"Color`":`"#3366CC`",`"Effect`":`"$e`",`"Hz`":0.6}",
                                   '--segments', "$n", '--seconds', '0.4')
            $rows = @($lines | Where-Object { $_ -notmatch '^#' -and $_ })
            if ($rows.Count -lt 1) { $bad = $true; break }
            foreach ($r in $rows) {
                $cells = $r.Split(',')[1..($r.Split(',').Count - 1)]
                if ($cells.Count -ne $n) { $bad = $true; break }
                foreach ($c in $cells) { if ($c -notmatch '^#[0-9A-F]{6}$') { $bad = $true; break } }
            }
        }
        if ($bad) { No "$e renders at 1, 3 and 10 segments" } else { Ok "$e renders at 1, 3 and 10 segments" }
    }

    # Determinism. Without it the goldens below are meaningless and sparkle (Task 4)
    # would strobe differently on every frame.
    $a = Invoke-Dump @('--style','{"Color":"#3366CC","Effect":"chase","Hz":0.6}','--segments','10','--seconds','1')
    $b = Invoke-Dump @('--style','{"Color":"#3366CC","Effect":"chase","Hz":0.6}','--segments','10','--seconds','1')
    if (($a -join "`n") -eq ($b -join "`n")) { Ok 'identical inputs produce identical frames' }
    else { No 'render output is not deterministic' 'Goldens and sparkle both depend on this.' }

    # Goldens.
    foreach ($e in $effects) {
        $goldenPath = Join-Path $root "tests/golden/$e.csv"
        if (-not (Test-Path $goldenPath)) { No "golden exists for $e" $goldenPath; continue }
        $got = Invoke-Dump @('--style', "{`"Color`":`"#3366CC`",`"Effect`":`"$e`",`"Hz`":0.6}",
                             '--segments','10','--seconds','4','--fps','25')
        $want = @(Get-Content $goldenPath)
        if (($got -join "`n") -eq ($want -join "`n")) { Ok "$e matches its golden frames" }
        else { No "$e output changed" "Compare against tests/golden/$e.csv" }
    }
}
```

- [ ] **Step 7: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: all existing checks still pass, plus 13 new PASS lines (6 render + 1 determinism + 6 golden) and `=== N passed, 0 failed ===`.

- [ ] **Step 8: Commit**

```bash
git add src/GoveeLights.Daemon/Rgb.cs src/GoveeLights.Daemon/FrameDump.cs \
        src/GoveeLights.Daemon/Effects.cs src/GoveeLights.Daemon/Program.cs \
        scripts/Test-Repo.ps1 tests/golden
git commit -m "Add a headless frame-dump harness and golden effect frames"
```

---

### Task 2: Nullable StateStyle and the four-layer merge

Fixes the partial-override bug. `Effects.Render` starts consuming `ResolvedStyle` but its maths is unchanged, so the goldens must still match exactly.

**Files:**
- Modify: `src/GoveeLights.Daemon/Config.cs:18-24` (`StateStyle`)
- Create: `src/GoveeLights.Daemon/Palette.cs`
- Modify: `src/GoveeLights.Daemon/Effects.cs` (remove `Palette`; adapt `Render` signature)
- Modify: `src/GoveeLights.Daemon/Renderer.cs:182-204`
- Modify: `src/GoveeLights.Daemon/FrameDump.cs`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `Rgb`, `Frame`, `Activity`, `DaemonConfig`, `DeviceConfig`.
- Produces:
  - `class ResolvedStyle` with fields `Rgb Color`, `Rgb Color2`, `bool HasColor2`, `string Effect`, `double Hz`, `int Brightness`, `string Direction`, `string Easing`, `double Tail`, `double Depth`, `double FullSeconds`.
  - `Palette.Resolve(DaemonConfig cfg, DeviceConfig device, Activity state) -> ResolvedStyle`
  - `Palette.ResolveStyle(params StateStyle[] layers) -> ResolvedStyle` (layers ordered weakest first)
  - `Palette.Defaults() -> Dictionary<string, StateStyle>` (unchanged signature; `Program.BuildDefaultConfig` still uses it)
  - `Effects.Render(ResolvedStyle s, double t, double tInState, int segments) -> Frame`

- [ ] **Step 1: Make `StateStyle` nullable and give `DeviceConfig` a `States` map**

Replace `StateStyle` at `src/GoveeLights.Daemon/Config.cs:18-24` with:

```csharp
    /// <summary>A partial style. null means "inherit from the layer below" - see
    /// Palette.Resolve. Every field is nullable precisely so a config can override one
    /// value without restating the rest.</summary>
    public class StateStyle
    {
        public string  Color       { get; set; }
        public string  Color2      { get; set; }  // null = single-colour: weight scales toward black
        public string  Effect      { get; set; }  // solid|breathe|pulse|blink|chase|comet|wipe|progress|sparkle|rainbow
        public double? Hz          { get; set; }
        public int?    Brightness  { get; set; }  // null = inherit; -1 = leave brightness alone
        public string  Direction   { get; set; }  // forward|reverse|pingpong
        public string  Easing      { get; set; }  // linear|sine|cubic|expo
        public double? Tail        { get; set; }  // trail length, 1.0 = the effect's natural length
        public double? Depth       { get; set; }  // 0..1 intensity floor
        public double? FullSeconds { get; set; }  // progress: seconds to a full bar
    }
```

Add to `DeviceConfig` (`Config.cs:8-16`), after `ManageRazerSwitch`:

```csharp
        /// <summary>Per-device style overrides, layered over the global States map.
        /// Lets a desk strip chase while a ceiling strip only breathes.</summary>
        public Dictionary<string, StateStyle> States { get; set; } = new Dictionary<string, StateStyle>();
```

In `DaemonConfig.Normalize()` (`Config.cs:110-119`), after the existing `States` guard, add:

```csharp
            foreach (var d in Devices)
                if (d.States == null) d.States = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
```

- [ ] **Step 2: Create `Palette.cs` with the merge**

Create `src/GoveeLights.Daemon/Palette.cs`:

```csharp
using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>A fully-populated style. No nullables: every field has been resolved,
    /// so effects never have to ask "was this set?".</summary>
    public class ResolvedStyle
    {
        public Rgb    Color;
        public Rgb    Color2;
        public bool   HasColor2;
        public string Effect      = "solid";
        public double Hz          = 0.6;
        public int    Brightness  = -1;
        public string Direction   = "forward";
        public string Easing      = "linear";
        public double Tail        = 1.0;
        public double Depth       = 0.0;
        public double FullSeconds = 30.0;
    }

    public static class Palette
    {
        public static readonly string[] KnownEffects =
            { "solid", "breathe", "pulse", "blink", "chase", "comet", "wipe", "progress", "sparkle", "rainbow" };
        static readonly string[] KnownDirections = { "forward", "reverse", "pingpong" };
        static readonly string[] KnownEasings    = { "linear", "sine", "cubic", "expo" };

        /// <summary>Built-in per-state defaults. Config entries layer over these.</summary>
        public static Dictionary<string, StateStyle> Defaults()
        {
            return new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase)
            {
                { "Idle",        new StateStyle { Color = "#1E2A3A", Effect = "breathe", Hz = 0.12, Brightness = 25 } },
                { "Thinking",    new StateStyle { Color = "#7B4DFF", Effect = "breathe", Hz = 0.6,  Brightness = 55 } },
                { "ToolRead",    new StateStyle { Color = "#06B6D4", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolEdit",    new StateStyle { Color = "#22C55E", Effect = "chase",   Hz = 0.6,  Brightness = 60 } },
                { "ToolShell",   new StateStyle { Color = "#FF7A18", Effect = "chase",   Hz = 0.8,  Brightness = 60 } },
                { "ToolWeb",     new StateStyle { Color = "#3B82F6", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolMcp",     new StateStyle { Color = "#8B5CF6", Effect = "chase",   Hz = 0.5,  Brightness = 50 } },
                { "ToolAgent",   new StateStyle { Color = "#D946EF", Effect = "comet",   Hz = 0.7,  Brightness = 60 } },
                { "ToolOther",   new StateStyle { Color = "#94A3B8", Effect = "solid",   Hz = 0.5,  Brightness = 45 } },
                { "Compacting",  new StateStyle { Color = "#00C8A0", Effect = "chase",   Hz = 0.35, Brightness = 45 } },
                { "WaitingUser", new StateStyle { Color = "#FFB000", Effect = "pulse",   Hz = 1.3,  Brightness = 95 } },
                { "Error",       new StateStyle { Color = "#FF2020", Effect = "blink",   Hz = 2.5,  Brightness = 80 } },
                { "Done",        new StateStyle { Color = "#22DD55", Effect = "solid",   Hz = 1.0,  Brightness = 70 } },
                { "Offline",     new StateStyle { Color = "#FFD9A0", Effect = "solid",   Hz = 0.0,  Brightness = 60 } }
            };
        }

        // Resolve runs once per device per tick, so it must not rebuild the default map
        // every time. Nothing mutates these, so a shared instance is safe.
        static readonly Dictionary<string, StateStyle> _stateDefaults = Defaults();

        /// <summary>The weakest layer, keyed by effect. These reproduce the constants
        /// that used to be hardcoded inside each effect - breathe's 0.35 floor, pulse's
        /// cubic shaping and 0.08 floor - so that expressing them as modifiers changes
        /// no output.</summary>
        static StateStyle EffectDefaults(string effect)
        {
            switch (effect)
            {
                case "breathe": return new StateStyle { Depth = 0.35 };
                case "pulse":   return new StateStyle { Depth = 0.08, Easing = "cubic" };
                case "blink":   return new StateStyle { Depth = 0.06 };
                case "sparkle": return new StateStyle { Depth = 0.06 };
                default:        return new StateStyle();
            }
        }

        /// <summary>Layers, weakest first: effect defaults, state defaults, config, device.
        /// A non-null field in a later layer wins; null means inherit.</summary>
        public static ResolvedStyle Resolve(DaemonConfig cfg, DeviceConfig device, Activity state)
        {
            var key = state.ToString();
            var layers = new List<StateStyle>(3);

            StateStyle s;
            if (_stateDefaults.TryGetValue(key, out s)) layers.Add(s);
            else layers.Add(_stateDefaults["Idle"]);

            if (cfg != null && cfg.States != null && cfg.States.TryGetValue(key, out s) && s != null)
                layers.Add(s);
            if (device != null && device.States != null && device.States.TryGetValue(key, out s) && s != null)
                layers.Add(s);

            return ResolveStyle(layers.ToArray());
        }

        public static ResolvedStyle ResolveStyle(params StateStyle[] layers)
        {
            if (layers == null) layers = new StateStyle[0];

            // Effect first: the weakest layer is keyed by it.
            var effect = Norm(Pick(layers, x => x.Effect), KnownEffects, "solid", "Effect");

            var all = new StateStyle[layers.Length + 1];
            all[0] = EffectDefaults(effect);
            Array.Copy(layers, 0, all, 1, layers.Length);

            var r = new ResolvedStyle();
            r.Effect = effect;
            r.Color  = Rgb.Parse(Pick(all, x => x.Color), new Rgb(120, 120, 120));

            var c2 = Pick(all, x => x.Color2);
            r.HasColor2 = !string.IsNullOrEmpty(c2);
            r.Color2 = r.HasColor2 ? Rgb.Parse(c2, new Rgb(0, 0, 0)) : new Rgb(0, 0, 0);

            r.Hz = PickN(all, x => x.Hz, 0.6);
            if (r.Hz <= 0) r.Hz = 0.6;               // Offline stores Hz 0; solid ignores it anyway

            r.Brightness = PickN(all, x => x.Brightness, -1);
            r.Direction  = Norm(Pick(all, x => x.Direction), KnownDirections, "forward", "Direction");
            r.Easing     = Norm(Pick(all, x => x.Easing), KnownEasings, "linear", "Easing");

            r.Tail = PickN(all, x => x.Tail, 1.0);
            if (r.Tail <= 0) r.Tail = 1.0;

            r.Depth = PickN(all, x => x.Depth, 0.0);
            if (r.Depth < 0) r.Depth = 0;
            if (r.Depth > 1) r.Depth = 1;

            r.FullSeconds = PickN(all, x => x.FullSeconds, 30.0);
            if (r.FullSeconds <= 0) r.FullSeconds = 30.0;

            return r;
        }

        static string Pick(StateStyle[] layers, Func<StateStyle, string> f)
        {
            for (int i = layers.Length - 1; i >= 0; i--)
            {
                if (layers[i] == null) continue;
                var v = f(layers[i]);
                if (!string.IsNullOrEmpty(v)) return v;
            }
            return null;
        }

        static T PickN<T>(StateStyle[] layers, Func<StateStyle, T?> f, T dflt) where T : struct
        {
            for (int i = layers.Length - 1; i >= 0; i--)
            {
                if (layers[i] == null) continue;
                var v = f(layers[i]);
                if (v.HasValue) return v.Value;
            }
            return dflt;
        }

        // A typo must not silently change how the lights behave, but Resolve runs 25x a
        // second - warning every tick would drown the log. Warn once per distinct value.
        static readonly HashSet<string> _warned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        static string Norm(string value, string[] known, string dflt, string field)
        {
            if (string.IsNullOrEmpty(value)) return dflt;
            var v = value.Trim().ToLowerInvariant();
            for (int i = 0; i < known.Length; i++) if (known[i] == v) return v;

            var tag = field + ":" + v;
            lock (_warned)
            {
                if (_warned.Add(tag))
                    Log.Warn("style_unknown_value", "falling back to default",
                        new Dictionary<string, object> { { "field", field }, { "value", value }, { "using", dflt } });
            }
            return dflt;
        }
    }
}
```

Delete the entire `Palette` class from `src/GoveeLights.Daemon/Effects.cs` (currently lines 131–163 of the original file).

- [ ] **Step 3: Adapt `Effects.Render` to `ResolvedStyle`**

This step changes the signature only — the maths stays byte-for-byte identical, which the goldens will prove in Step 5. In `src/GoveeLights.Daemon/Effects.cs`, make exactly these four edits to `Render`:

1. Replace the signature line

```csharp
        public static Frame Render(StateStyle style, double t, int segments, Rgb color)
```

with

```csharp
        public static Frame Render(ResolvedStyle style, double t, double tInState, int segments)
```

2. Replace the first two lines of the body

```csharp
            var effect = (style.Effect ?? "solid").ToLowerInvariant();
            var hz = style.Hz <= 0 ? 0.6 : style.Hz;
```

with

```csharp
            var effect = style.Effect;      // already normalised and lowercased by Palette
            var hz = style.Hz;              // already clamped above zero by Palette
            var color = style.Color;
```

3. In the `chase` and `comet` cases, replace

```csharp
                    return new Frame { Solid = color, Segments = cells, Brightness = style.Brightness };
```

with

```csharp
                    return new Frame { Solid = color, Segments = cells };
```

(`Frame.Brightness` was never read — `Emit` uses `style.Brightness` directly — and it is removed from the class in Task 3.)

4. Leave `Whole`, `CircularDistance` and every case body otherwise untouched.

`tInState` is unused until Task 4. That is deliberate: threading it now means the signature does not churn a second time.

- [ ] **Step 4: Update the two call sites**

In `src/GoveeLights.Daemon/Renderer.cs`, replace lines 182–204 with:

```csharp
            var style = Palette.Resolve(cfg, null, _current);

            // Cross-fade so state changes read as smooth rather than as a jump cut.
            var sinceTransition = (DateTime.UtcNow - _transitionStart).TotalMilliseconds;
            if (cfg.Render.TransitionMs > 0 && sinceTransition < cfg.Render.TransitionMs)
            {
                var prev = Palette.Resolve(cfg, null, _previous);
                var mix = sinceTransition / cfg.Render.TransitionMs;
                style.Color = Rgb.Lerp(prev.Color, style.Color, mix);
                if (style.HasColor2 && prev.HasColor2)
                    style.Color2 = Rgb.Lerp(prev.Color2, style.Color2, mix);
            }

            var t = _clock.Elapsed.TotalSeconds;
            var tInState = (DateTime.UtcNow - _transitionStart).TotalSeconds;

            List<DeviceRuntime> snapshot;
            lock (_devGate) snapshot = _devices.ToList();

            foreach (var d in snapshot)
            {
                var segs = d.Cfg.Animate ? d.Segments : 1;
                var frame = Effects.Render(style, t, tInState, segs);
                Emit(cfg, d, style, frame);
            }
```

Change `Emit`'s signature from `StateStyle style` to `ResolvedStyle style` (`Renderer.cs:207`). Its body already reads only `style.Brightness`, which is now a plain `int`, so no further change.

In `src/GoveeLights.Daemon/FrameDump.cs`, replace the style-building block from Step 2 of Task 1 with:

```csharp
            ResolvedStyle style;
            if (!string.IsNullOrEmpty(styleJson))
            {
                StateStyle raw;
                try { raw = new JavaScriptSerializer().Deserialize<StateStyle>(styleJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --style: " + ex.Message); return 2; }
                if (raw == null) { Console.Error.WriteLine("bad --style: null"); return 2; }
                style = Palette.ResolveStyle(raw);
            }
            else
            {
                Activity a;
                if (!Enum.TryParse(stateName ?? "Thinking", true, out a))
                {
                    Console.Error.WriteLine("unknown --state: " + stateName);
                    return 2;
                }
                DaemonConfig cfg = null;
                var configPath = Arg(args, "--config", null);
                if (!string.IsNullOrEmpty(configPath))
                {
                    string e;
                    cfg = DaemonConfig.Load(configPath, out e);
                    if (cfg == null) { Console.Error.WriteLine("bad --config: " + e); return 2; }
                }
                DeviceConfig dev = null;
                var deviceName = Arg(args, "--device", null);
                if (cfg != null && !string.IsNullOrEmpty(deviceName))
                    dev = cfg.Devices.FirstOrDefault(x => string.Equals(x.Name, deviceName, StringComparison.OrdinalIgnoreCase));
                style = Palette.Resolve(cfg, dev, a);
            }
```

and the header/render lines with:

```csharp
            var w = Console.Out;
            w.WriteLine("# effect=" + style.Effect +
                        " hz=" + style.Hz.ToString("0.###", CultureInfo.InvariantCulture) +
                        " color=" + style.Color.ToHex() +
                        " color2=" + (style.HasColor2 ? style.Color2.ToHex() : "none") +
                        " dir=" + style.Direction + " ease=" + style.Easing +
                        " tail=" + style.Tail.ToString("0.###", CultureInfo.InvariantCulture) +
                        " depth=" + style.Depth.ToString("0.###", CultureInfo.InvariantCulture) +
                        " segments=" + segments + " fps=" + fps);

            var frames = (int)Math.Round(seconds * fps);
            for (int i = 0; i < frames; i++)
            {
                var t = (double)i / fps;
                var f = Effects.Render(style, t, t, segments);
                var cells = f.Segments ?? new[] { f.Solid };
                w.WriteLine(t.ToString("0.000", CultureInfo.InvariantCulture) + "," +
                            string.Join(",", cells.Select(c => c.ToHex()).ToArray()));
            }
```

- [ ] **Step 5: Re-capture the goldens' comment line only**

The header line now carries more fields, so the goldens' first line no longer matches while every frame line does. Re-run the Task 1 Step 5 capture block verbatim to refresh them, then confirm only line 1 changed:

```powershell
git diff --stat tests/golden
git diff tests/golden/breathe.csv | Select-Object -First 12
```

Expected: exactly one changed line per file, and it is the `#` comment. **If any frame line differs, the refactor changed behaviour — stop and fix it before continuing.**

- [ ] **Step 6: Add the partial-override test**

Append inside the `else` branch of the `Effects engine` section in `scripts/Test-Repo.ps1`, after the golden loop:

```powershell
    # The bug this whole refactor exists to fix: an entry that sets only Hz used to be
    # discarded wholesale because it carried no Color, silently reverting to defaults.
    $partial = Invoke-Dump @('--style','{"Effect":"breathe","Hz":2.0,"Color":"#3366CC"}','--segments','1','--seconds','1')
    $full    = Invoke-Dump @('--style','{"Effect":"breathe","Hz":0.6,"Color":"#3366CC"}','--segments','1','--seconds','1')
    if (($partial -join "`n") -ne ($full -join "`n")) { Ok 'Hz is honoured independently of other fields' }
    else { No 'Hz had no effect' 'Partial overrides are being discarded.' }

    # Depth is an inherited effect default, not a per-state one: breathe must still floor
    # at 0.35 of the colour even though no state specifies Depth.
    $b = Invoke-Dump @('--style','{"Effect":"breathe","Hz":0.6,"Color":"#FFFFFF"}','--segments','1','--seconds','2')
    $vals = @($b | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        [Convert]::ToInt32($_.Split(',')[1].Substring(1,2), 16) })
    $min = ($vals | Measure-Object -Minimum).Minimum
    if ($min -ge 88 -and $min -le 91) { Ok 'breathe inherits its 0.35 depth floor' "min channel $min" }
    else { No 'breathe depth floor is wrong' "min channel $min, expected 89" }
```

- [ ] **Step 7: Build and test**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===`, including all six golden checks and the two new ones.

- [ ] **Step 8: Commit**

```bash
git add src/GoveeLights.Daemon/Config.cs src/GoveeLights.Daemon/Palette.cs \
        src/GoveeLights.Daemon/Effects.cs src/GoveeLights.Daemon/Renderer.cs \
        src/GoveeLights.Daemon/FrameDump.cs scripts/Test-Repo.ps1 tests/golden
git commit -m "Resolve styles through a four-layer merge so partial overrides apply"
```

---

### Task 3: The effects pipeline

Replaces the switch with shape functions plus shared post-stages. The goldens must stay byte-identical.

**Files:**
- Modify: `src/GoveeLights.Daemon/Effects.cs` (full rewrite of the file)
- Test: `scripts/Test-Repo.ps1`

`Renderer.cs` needs no change here: it never read `Frame.Brightness`, and `Effects.Render`'s signature is already what Task 2 left it.

**Interfaces:**
- Consumes: `ResolvedStyle`, `Rgb`, `Palette.KnownEffects`.
- Produces: `Effects.Render(ResolvedStyle, double t, double tInState, int segments) -> Frame` (signature unchanged from Task 2); `Frame` loses its `Brightness` field.

- [ ] **Step 1: Rewrite `Effects.cs`**

Replace the whole file with:

```csharp
using System;

namespace GoveeLights
{
    /// <summary>One rendered frame for one device.</summary>
    public class Frame
    {
        public Rgb Solid;
        public Rgb[] Segments;      // null = use Solid via DeviceColorControl
    }

    /// <summary>
    /// The Govee API has no effects of its own, so every animation is computed here and
    /// pushed as discrete frames.
    ///
    /// An effect is a pure shape: weights in 0..1, one per segment, knowing nothing about
    /// modifiers. Shared stages then apply direction, easing, depth and colour in that
    /// fixed order. Writing modifiers once is what keeps eleven effects from disagreeing
    /// about what "reverse" means.
    /// </summary>
    public static class Effects
    {
        public static Frame Render(ResolvedStyle s, double t, double tInState, int segments)
        {
            var n = segments < 1 ? 1 : segments;

            // Spatial effects have nothing to say on a single-zone device.
            var effect = s.Effect;
            if (n <= 1 && IsSpatial(effect)) effect = "breathe";

            var w = Shape(effect, t, tInState, n, s);
            w = ApplyDirection(w, s, t);
            // AMENDED IN REVIEW: see the note at the end of this task.
            ApplyEasing(w, s.Easing);
            ApplyDepth(w, s.Depth);
            return ToFrame(w, s, n);
        }

        static bool IsSpatial(string effect)
        {
            switch (effect)
            {
                case "chase": case "comet": case "wipe": case "progress": return true;
                default: return false;
            }
        }

        // ---- shapes -----------------------------------------------------------------

        /// <summary>Returns one weight per segment - or a single weight when the effect is
        /// uniform across the device. That length-1 case is load-bearing: it is what makes
        /// ToFrame emit a whole-device colour instead of a segment array, and what makes
        /// direction a no-op for effects that have no direction.</summary>
        static double[] Shape(string effect, double t, double tInState, int n, ResolvedStyle s)
        {
            switch (effect)
            {
                case "breathe":
                {
                    var k = (Math.Sin(t * 2 * Math.PI * s.Hz) + 1) / 2;
                    return new[] { k };
                }

                case "pulse":
                {
                    // Raw sine; the cubic that makes it snap is the default easing.
                    var k = (Math.Sin(t * 2 * Math.PI * s.Hz) + 1) / 2;
                    return new[] { k };
                }

                case "blink":
                {
                    var on = ((int)Math.Floor(t * s.Hz * 2)) % 2 == 0 ? 1.0 : 0.0;
                    return new[] { on };
                }

                case "chase":
                {
                    var w = new double[n];
                    var head = (t * s.Hz * n) % n;
                    for (int i = 0; i < n; i++)
                    {
                        var d = CircularDistance(i, head, n);
                        w[i] = d <= 0.5 * s.Tail ? 1.0
                             : (d <= 1.5 * s.Tail ? 0.45
                             : (d <= 2.5 * s.Tail ? 0.12 : 0.02));
                    }
                    return w;
                }

                case "comet":
                {
                    var w = new double[n];
                    var head = (t * s.Hz * n) % n;
                    for (int i = 0; i < n; i++)
                    {
                        // Trailing decay only - the tail lags behind the head.
                        var back = head - i;
                        if (back < 0) back += n;
                        w[i] = Math.Max(0.02, Math.Exp(-back / (n * 0.22 * s.Tail)));
                    }
                    return w;
                }

                default: // "solid"
                    return new[] { 1.0 };
            }
        }

        static double CircularDistance(int i, double head, int n)
        {
            var d = Math.Abs(i - head);
            return Math.Min(d, n - d);
        }

        // ---- stages -----------------------------------------------------------------

        /// <summary>Reverse mirrors the array, which turns a travelling wave around and
        /// flips a fill. Pingpong mirrors on odd cycles only, so motion bounces instead
        /// of wrapping. Both are no-ops on a single zone.</summary>
        static double[] ApplyDirection(double[] w, ResolvedStyle s, double t)
        {
            if (w.Length <= 1) return w;

            bool mirror;
            switch (s.Direction)
            {
                case "reverse":  mirror = true; break;
                case "pingpong": mirror = ((int)Math.Floor(t * s.Hz)) % 2 != 0; break;
                default:         mirror = false; break;
            }
            if (!mirror) return w;

            var o = new double[w.Length];
            for (int i = 0; i < w.Length; i++) o[i] = w[w.Length - 1 - i];
            return o;
        }

        static void ApplyEasing(double[] w, string easing)
        {
            if (easing == "linear") return;
            for (int i = 0; i < w.Length; i++)
            {
                var x = w[i] < 0 ? 0 : (w[i] > 1 ? 1 : w[i]);
                switch (easing)
                {
                    case "sine":  x = (1 - Math.Cos(x * Math.PI)) / 2; break;
                    case "cubic": x = x * x * x; break;
                    case "expo":  x = x <= 0 ? 0 : Math.Pow(2, 10 * (x - 1)); break;
                }
                w[i] = x;
            }
        }

        /// <summary>Rescale into [depth, 1] so the colour never fully disappears.</summary>
        static void ApplyDepth(double[] w, double depth)
        {
            if (depth <= 0) return;
            for (int i = 0; i < w.Length; i++) w[i] = depth + (1 - depth) * w[i];
        }

        static Frame ToFrame(double[] w, ResolvedStyle s, int n)
        {
            // Uniform colour is cheaper and more reliable through DeviceColorControl than
            // through a segment array, so do not fill segments unnecessarily. A length-1
            // weight array is exactly the old Whole() path: keep it byte-identical or the
            // goldens - and the wire traffic - both change.
            if (w.Length <= 1) return new Frame { Solid = Mix(s, w[0]), Segments = null };

            var cells = new Rgb[n];
            for (int i = 0; i < n; i++) cells[i] = Mix(s, w[i]);
            return new Frame { Solid = s.Color, Segments = cells };
        }

        static Rgb Mix(ResolvedStyle s, double w)
        {
            return s.HasColor2 ? Rgb.Lerp(s.Color2, s.Color, w) : s.Color.Scale(w);
        }
    }
}
```

Note the deliberate behaviour preservation: `breathe`'s old `0.35 + 0.65 * k` is now raw `k` plus `Depth = 0.35`; `pulse`'s old `0.08 + 0.92 * pow(raw,3)` is raw sine plus `Easing = cubic` plus `Depth = 0.08`; `blink`'s old `0.06` floor is `Depth = 0.06`. `chase` and `comet` keep their own internal floors and take `Depth = 0`, because rescaling would not reproduce `comet`'s `Math.Max` clamp.

- [ ] **Step 2: Drop the dead `Brightness` field**

`Frame.Brightness` was never read — `Emit` uses `style.Brightness` directly. It is already gone from the `Frame` class above. Confirm nothing else references it:

```powershell
Select-String -Path src\GoveeLights.Daemon\*.cs -Pattern 'frame\.Brightness|Frame \{ .*Brightness'
```

Expected: no matches.

- [ ] **Step 3: Build and verify the goldens are untouched**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: all six `matches its golden frames` checks PASS. **A golden mismatch here means the pipeline changed behaviour — that is the failure this task is designed to catch, so fix the maths rather than re-capturing the golden.**

- [ ] **Step 4: Add the modifier tests**

Append inside the `else` branch of the `Effects engine` section in `scripts/Test-Repo.ps1`:

```powershell
    # Direction is an array transform, so reverse must be an exact mirror of forward.
    $fwd = Invoke-Dump @('--style','{"Effect":"chase","Hz":0.6,"Color":"#3366CC","Direction":"forward"}','--segments','10','--seconds','1')
    $rev = Invoke-Dump @('--style','{"Effect":"chase","Hz":0.6,"Color":"#3366CC","Direction":"reverse"}','--segments','10','--seconds','1')
    $mirrorOk = $true
    $fwdRows = @($fwd | Where-Object { $_ -notmatch '^#' -and $_ })
    $revRows = @($rev | Where-Object { $_ -notmatch '^#' -and $_ })
    if ($fwdRows.Count -ne $revRows.Count -or $fwdRows.Count -eq 0) { $mirrorOk = $false }
    else {
        for ($i = 0; $i -lt $fwdRows.Count; $i++) {
            $f = $fwdRows[$i].Split(','); $r = $revRows[$i].Split(',')
            $fc = $f[1..($f.Count-1)]; $rc = $r[1..($r.Count-1)]
            [array]::Reverse($rc)
            if (($fc -join '') -ne ($rc -join '')) { $mirrorOk = $false; break }
        }
    }
    if ($mirrorOk) { Ok 'Direction reverse is the exact mirror of forward' }
    else { No 'reverse is not a mirror of forward' }

    # Depth must floor the output: nothing may fall below depth * colour.
    $d = Invoke-Dump @('--style','{"Effect":"blink","Hz":2.0,"Color":"#FFFFFF","Depth":0.5}','--segments','1','--seconds','2')
    $dv = @($d | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        [Convert]::ToInt32($_.Split(',')[1].Substring(1,2), 16) })
    $dmin = ($dv | Measure-Object -Minimum).Minimum
    if ($dmin -ge 126 -and $dmin -le 129) { Ok 'Depth floors the output' "min channel $dmin" }
    else { No 'Depth floor not applied' "min channel $dmin, expected 128" }

    # Color2 replaces "scale toward black" with a blend between two colours, so the
    # dimmest frame should be Color2 rather than near-black. Depth is pinned to 0: blink
    # defaults to Depth 0.06, which would lift the low end off Color2 exactly.
    $c2 = Invoke-Dump @('--style','{"Effect":"blink","Hz":2.0,"Color":"#FFFFFF","Color2":"#FF0000","Depth":0}','--segments','1','--seconds','2')
    $c2rows = @($c2 | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object { $_.Split(',')[1] })
    if (($c2rows | Sort-Object -Unique) -contains '#FF0000') { Ok 'Color2 is used as the low end of the blend' }
    else { No 'Color2 was not blended' ($c2rows | Sort-Object -Unique) -join ' ' }
```

- [ ] **Step 5: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===` with the three new checks passing.

- [ ] **Step 6: Commit**

```bash
git add src/GoveeLights.Daemon/Effects.cs scripts/Test-Repo.ps1
git commit -m "Replace the effects switch with a shape-plus-stages pipeline"
```

**Amended during review.** Two defects in the design above were found by the task review
and fixed in a follow-up commit; the code in this section is the pre-fix version and the
repository is the authority:

1. The `n <= 1 && IsSpatial(effect)` fallback rewrote the effect name to `breathe` while
   keeping the *original* effect's resolved style, so chase and comet lost breathe's 0.35
   depth floor and went fully black on one-zone devices. The fallback moved into
   `Palette.ResolveFor(cfg, device, state, segments)`, which re-resolves with `Effect`
   forced to `breathe` so breathe's own effect-defaults apply. `IsSpatial` moved to
   `Palette` as the single source of truth, and `Effects.Render` no longer rewrites the
   effect name.
2. `pingpong` as an array mirror teleported the head across the strip at each turnaround,
   because the circular `head` kept advancing underneath the mirror. It became a phase
   fold (`FoldTime`) applied before the shape, gated to spatial effects with more than one
   segment; `ApplyDirection` now handles `reverse` only.

---

### Task 4: Four new effects

**Files:**
- Modify: `src/GoveeLights.Daemon/Rgb.cs` (add `FromHsv`)
- Modify: `src/GoveeLights.Daemon/Effects.cs`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `Rgb.Clamp` (private to the struct, and `FromHsv` lives in it), `ResolvedStyle.Tail`, `.Depth`, `.FullSeconds`, `.Hz`.
- Produces: `Rgb.FromHsv(double h, double s, double v) -> Rgb`; effect names `wipe`, `progress`, `sparkle`, `rainbow` accepted by `Effects.Render`.

- [ ] **Step 1: Add `Rgb.FromHsv`**

Append to the `Rgb` struct in `src/GoveeLights.Daemon/Rgb.cs`, before the closing brace:

```csharp
        /// <summary>h wraps, s and v are 0..1. Needed by rainbow, which varies hue rather
        /// than intensity and so cannot be expressed as a weight.</summary>
        public static Rgb FromHsv(double h, double s, double v)
        {
            h = h - Math.Floor(h);
            var i = (int)Math.Floor(h * 6) % 6;
            var f = h * 6 - Math.Floor(h * 6);
            var p = v * (1 - s);
            var q = v * (1 - f * s);
            var u = v * (1 - (1 - f) * s);

            double r, g, b;
            switch (i)
            {
                case 0:  r = v; g = u; b = p; break;
                case 1:  r = q; g = v; b = p; break;
                case 2:  r = p; g = v; b = u; break;
                case 3:  r = p; g = q; b = v; break;
                case 4:  r = u; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return new Rgb(Clamp(r * 255), Clamp(g * 255), Clamp(b * 255));
        }
```

- [ ] **Step 2: Add the four shapes**

In `src/GoveeLights.Daemon/Effects.cs`, add these cases to the `Shape` switch, before `default`:

```csharp
                case "wipe":
                {
                    // One cycle fills the strip, the next clears it from the same end.
                    var w = new double[n];
                    var cycle = (t * s.Hz) - Math.Floor(t * s.Hz);
                    var pos = cycle * 2 * n;
                    for (int i = 0; i < n; i++)
                    {
                        if (pos <= n) w[i] = i < pos ? 1.0 : 0.0;
                        else          w[i] = i < (pos - n) ? 0.0 : 1.0;
                    }
                    return w;
                }

                case "progress":
                {
                    // Fills by elapsed time in the state, then holds full. The partial
                    // leading cell keeps it from stepping a whole segment at a time.
                    var w = new double[n];
                    var frac = tInState / s.FullSeconds;
                    if (frac < 0) frac = 0;
                    if (frac > 1) frac = 1;
                    var edge = frac * n;
                    for (int i = 0; i < n; i++)
                    {
                        var c = edge - i;
                        w[i] = c < 0 ? 0.0 : (c > 1 ? 1.0 : c);
                    }
                    return w;
                }

                case "sparkle":
                {
                    // Hashed, not random: Hz becomes a twinkle rate instead of a 25fps
                    // strobe, the segment CSV only changes when the step advances so the
                    // rate limiter is not fighting it, and the output stays reproducible.
                    var w = new double[n];
                    var step = (long)Math.Floor(t * s.Hz);
                    for (int i = 0; i < n; i++) w[i] = Hash01(i, step) < 0.28 ? 1.0 : 0.0;
                    return w;
                }
```

Add the hash helper alongside `CircularDistance`:

```csharp
        /// <summary>SplitMix64 finalizer over (segment, step). Deterministic and evenly
        /// distributed, which is all sparkle needs.</summary>
        static double Hash01(int i, long step)
        {
            unchecked
            {
                ulong x = (ulong)step * 0x9E3779B97F4A7C15UL;
                x ^= (ulong)(uint)i * 0xBF58476D1CE4E5B9UL;
                x ^= x >> 30; x *= 0xBF58476D1CE4E5B9UL;
                x ^= x >> 27; x *= 0x94D049BB133111EBUL;
                x ^= x >> 31;
                return (x >> 11) * (1.0 / 9007199254740992.0);
            }
        }
```

- [ ] **Step 3: Wire rainbow into `Render` and the spatial list**

Rainbow varies hue, not intensity, so it bypasses the shape-and-stages path entirely.

First add `"rainbow"` to `Palette.IsSpatial` alongside `chase`, `comet`, `wipe` and
`progress`. That is what makes a one-zone device fall back to `breathe` **with breathe's
own `Depth 0.35`** — the fallback happens during resolution, in `Palette.ResolveFor`, so by
the time `Effects.Render` sees the style the effect name is already `breathe` and the
rainbow branch below is correctly skipped.

Then, in `Effects.Render`, insert the hue branch immediately before the shape-and-stages
call (it keys off the already-resolved `s.Effect`, and `Render` no longer rewrites it):

```csharp
            if (s.Effect == "rainbow")
            {
                var hues = new Rgb[n];
                for (int i = 0; i < n; i++)
                    hues[i] = Rgb.FromHsv((double)i / n + t * s.Hz, 1.0, 1.0);
                return n <= 1
                    ? new Frame { Solid = hues[0], Segments = null }
                    : new Frame { Solid = hues[0], Segments = hues };
            }
```

Note that `sparkle` is deliberately **not** in `Palette.IsSpatial`: on a single zone it reads as a random blink, which needs no `breathe` fallback. It still paints per segment when there is more than one.

- [ ] **Step 4: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 5: Extend the render sweep and add per-effect tests**

In `scripts/Test-Repo.ps1`, change the effect list in the `Effects engine` section from

```powershell
    $effects = @('solid','breathe','pulse','blink','chase','comet')
```

to

```powershell
    $effects = @('solid','breathe','pulse','blink','chase','comet','wipe','progress','sparkle','rainbow')
    $golden  = @('solid','breathe','pulse','blink','chase','comet')
```

and change the golden loop's `foreach ($e in $effects)` to `foreach ($e in $golden)` — only the six original effects have goldens.

Also extend the per-segment list used by the render sweep's cell-count assertion, so the
four new effects are checked for the right shape rather than waved through:

```powershell
    $spatial = @('chase','comet','wipe','progress','sparkle','rainbow')
```

Note this list is "paints per segment", which is deliberately **not** the same as
`Palette.IsSpatial`: `sparkle` paints per segment but is not in `IsSpatial`, because at one
segment it reads fine as a random blink and needs no `breathe` fallback.

Then append these checks:

```powershell
    # progress is driven by time-in-state, so it must be monotonically non-decreasing.
    $p = Invoke-Dump @('--style','{"Effect":"progress","Color":"#FFFFFF","FullSeconds":2}','--segments','10','--seconds','3')
    $lit = @($p | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        @($_.Split(',')[1..10] | Where-Object { $_ -ne '#000000' }).Count })
    $mono = $true
    for ($i = 1; $i -lt $lit.Count; $i++) { if ($lit[$i] -lt $lit[$i-1]) { $mono = $false; break } }
    if ($mono -and $lit[-1] -eq 10) { Ok 'progress fills monotonically and reaches full' }
    else { No 'progress does not fill monotonically to full' "last=$($lit[-1])" }

    # rainbow must actually span hues rather than painting one colour.
    $rb = Invoke-Dump @('--style','{"Effect":"rainbow","Hz":0.2,"Color":"#FFFFFF"}','--segments','10','--seconds','0.2')
    $first = @($rb | Where-Object { $_ -notmatch '^#' -and $_ })[0].Split(',')[1..10]
    if (@($first | Sort-Object -Unique).Count -ge 8) { Ok 'rainbow spans distinct hues across segments' }
    else { No 'rainbow is not spanning hues' (@($first | Sort-Object -Unique).Count) }

    # sparkle is hashed rather than random: same input, same frames. Already covered by
    # the global determinism check, but assert it directly since it is the one effect
    # where non-determinism would be easy to reintroduce.
    $s1 = Invoke-Dump @('--style','{"Effect":"sparkle","Hz":8,"Color":"#FFFFFF"}','--segments','10','--seconds','1')
    $s2 = Invoke-Dump @('--style','{"Effect":"sparkle","Hz":8,"Color":"#FFFFFF"}','--segments','10','--seconds','1')
    if (($s1 -join "`n") -eq ($s2 -join "`n")) { Ok 'sparkle is deterministic' }
    else { No 'sparkle is not deterministic' 'Use the hash, not Random.' }

    # ...and that it actually twinkles. Compare only the cell columns: every row carries a
    # distinct timestamp in column 0, so uniquing whole rows would pass no matter what.
    $spatterns = @($s1 | Where-Object { $_ -notmatch '^#' -and $_ } | ForEach-Object {
        ($_.Split(',')[1..10]) -join '' })
    if (@($spatterns | Sort-Object -Unique).Count -gt 3) { Ok 'sparkle varies over time' }
    else { No 'sparkle output is static' (@($spatterns | Sort-Object -Unique).Count) }
```

- [ ] **Step 6: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===`. The render sweep now covers ten effects.

- [ ] **Step 7: Commit**

```bash
git add src/GoveeLights.Daemon/Rgb.cs src/GoveeLights.Daemon/Effects.cs scripts/Test-Repo.ps1
git commit -m "Add wipe, progress, sparkle and rainbow effects"
```

---

### Task 5: Per-device style overrides

**Files:**
- Modify: `src/GoveeLights.Daemon/Renderer.cs:182-205`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `Palette.ResolveFor(cfg, device, state, segments)` (Task 3 fix round), `DeviceConfig.States` (Task 2), `FrameDump`'s `--config` / `--device` flags (Task 2).
- Produces: no new API. Behaviour only.

- [ ] **Step 1: Move resolution inside the device loop**

Replace the current block in `Renderer.cs` — from the `Palette.ResolveFor(...)` call above the device loop through the end of the `foreach` — with:

```csharp
            var t = _clock.Elapsed.TotalSeconds;
            var sinceTransition = (DateTime.UtcNow - _transitionStart).TotalMilliseconds;
            var tInState = sinceTransition / 1000.0;
            var fading = cfg.Render.TransitionMs > 0 && sinceTransition < cfg.Render.TransitionMs;
            var mix = fading ? sinceTransition / cfg.Render.TransitionMs : 1.0;

            List<DeviceRuntime> snapshot;
            lock (_devGate) snapshot = _devices.ToList();

            foreach (var d in snapshot)
            {
                // Styles are resolved per device, not once per tick: a device may override
                // any field of any state, so two devices can be showing different effects.
                // ResolveFor takes the segment count because a spatial effect on a one-zone
                // device resolves to breathe, and must pick up breathe's own depth floor.
                var segs = d.Cfg.Animate ? d.Segments : 1;
                var style = Palette.ResolveFor(cfg, d.Cfg, _current, segs);

                if (fading)
                {
                    var prev = Palette.ResolveFor(cfg, d.Cfg, _previous, segs);
                    style.Color = Rgb.Lerp(prev.Color, style.Color, mix);
                    if (style.HasColor2 && prev.HasColor2)
                        style.Color2 = Rgb.Lerp(prev.Color2, style.Color2, mix);
                }

                var frame = Effects.Render(style, t, tInState, segs);
                Emit(cfg, d, style, frame);
            }
```

`Palette.ResolveFor` returns a fresh `ResolvedStyle` each call, so mutating `style.Color` for the cross-fade cannot leak between devices.

- [ ] **Step 2: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 3: Add a fixture config and the override test**

Create `tests/fixtures/device-override.json`:

```json
{
  "Enabled": true,
  "ApiGuid": "00000000-0000-0000-0000-000000000000",
  "Port": 17321,
  "States": {
    "Thinking": { "Color": "#3366CC", "Effect": "breathe", "Hz": 0.6 }
  },
  "Devices": [
    {
      "Name": "CeilingStrip",
      "States": { "Thinking": { "Effect": "solid" } }
    },
    { "Name": "DeskStrip" }
  ]
}
```

Append to the `Effects engine` section in `scripts/Test-Repo.ps1`:

```powershell
    # Per-device overrides layer on top of the global States map. CeilingStrip pins
    # Thinking to solid while inheriting the colour; DeskStrip inherits everything.
    $fixture = Join-Path $root 'tests/fixtures/device-override.json'
    $ceiling = Invoke-Dump @('--config',$fixture,'--state','Thinking','--device','CeilingStrip','--segments','1','--seconds','1')
    $desk    = Invoke-Dump @('--config',$fixture,'--state','Thinking','--device','DeskStrip','--segments','1','--seconds','1')

    if (($ceiling | Where-Object { $_ -match '^#' }) -match 'effect=solid') { Ok 'device override changes the effect' }
    else { No 'device override was ignored' ($ceiling | Where-Object { $_ -match '^#' }) }

    if (($ceiling | Where-Object { $_ -match '^#' }) -match 'color=#3366CC') { Ok 'device override inherits unset fields' }
    else { No 'device override did not inherit Color' ($ceiling | Where-Object { $_ -match '^#' }) }

    if (($desk | Where-Object { $_ -match '^#' }) -match 'effect=breathe') { Ok 'a device with no override uses the global style' }
    else { No 'unoverridden device did not use the global style' ($desk | Where-Object { $_ -match '^#' }) }
```

- [ ] **Step 4: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===` with the three override checks passing.

- [ ] **Step 5: Commit**

```bash
git add src/GoveeLights.Daemon/Renderer.cs scripts/Test-Repo.ps1 tests/fixtures
git commit -m "Resolve styles per device so each strip can behave differently"
```

---

### Task 6: Frame-level cross-fade

Today a state change cross-fades hue but jump-cuts motion. This blends whole frames during the transition window.

**Files:**
- Modify: `src/GoveeLights.Daemon/Effects.cs` (add `Blend`)
- Modify: `src/GoveeLights.Daemon/Renderer.cs`
- Modify: `src/GoveeLights.Daemon/FrameDump.cs` (add `--from`)
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `Frame`, `Rgb.Lerp`.
- Produces: `Effects.Blend(Frame a, Frame b, double mix) -> Frame`; `FrameDump` accepts `--from <state>` to dump a transition.

- [ ] **Step 1: Add `Effects.Blend`**

Append to the `Effects` class in `src/GoveeLights.Daemon/Effects.cs`:

```csharp
        /// <summary>Blend two frames. Cross-fading whole frames rather than just the base
        /// colour is what stops chase-to-blink from jump-cutting the motion. Shapes may
        /// disagree about segment count, so the wider frame wins and the narrower one is
        /// sampled proportionally.</summary>
        public static Frame Blend(Frame a, Frame b, double mix)
        {
            if (mix <= 0) return a;
            if (mix >= 1) return b;

            if (a.Segments == null && b.Segments == null)
                return new Frame { Solid = Rgb.Lerp(a.Solid, b.Solid, mix), Segments = null };

            var n = Math.Max(a.Segments == null ? 1 : a.Segments.Length,
                             b.Segments == null ? 1 : b.Segments.Length);
            var cells = new Rgb[n];
            for (int i = 0; i < n; i++)
                cells[i] = Rgb.Lerp(Sample(a, i, n), Sample(b, i, n), mix);

            return new Frame { Solid = Rgb.Lerp(a.Solid, b.Solid, mix), Segments = cells };
        }

        static Rgb Sample(Frame f, int i, int n)
        {
            if (f.Segments == null || f.Segments.Length == 0) return f.Solid;
            if (f.Segments.Length == n) return f.Segments[i];
            var j = (int)((long)i * f.Segments.Length / n);
            if (j >= f.Segments.Length) j = f.Segments.Length - 1;
            return f.Segments[j];
        }
```

- [ ] **Step 2: Use it in the renderer**

In `Renderer.cs`, replace the `foreach` body written in Task 5 Step 1 with:

```csharp
            foreach (var d in snapshot)
            {
                var segs = d.Cfg.Animate ? d.Segments : 1;
                var style = Palette.ResolveFor(cfg, d.Cfg, _current, segs);
                var frame = Effects.Render(style, t, tInState, segs);

                if (fading)
                {
                    // Render the outgoing state too and blend, so motion cross-fades
                    // rather than snapping. Only inside the TransitionMs window.
                    var prev = Palette.ResolveFor(cfg, d.Cfg, _previous, segs);
                    var prevFrame = Effects.Render(prev, t, tInState, segs);
                    frame = Effects.Blend(prevFrame, frame, mix);
                }

                Emit(cfg, d, style, frame);
            }
```

The per-field `Rgb.Lerp` of `style.Color` / `style.Color2` from Task 5 is now redundant — `Blend` covers it — so it is gone. `style` is still passed to `Emit` for its `Brightness`.

- [ ] **Step 3: Add `--from` to the harness**

In `src/GoveeLights.Daemon/FrameDump.cs`, after the style is resolved and before the header is written, add:

```csharp
            ResolvedStyle fromStyle = null;
            var fromName = Arg(args, "--from", null);
            if (!string.IsNullOrEmpty(fromName))
            {
                Activity fa;
                if (!Enum.TryParse(fromName, true, out fa))
                {
                    Console.Error.WriteLine("unknown --from: " + fromName);
                    return 2;
                }
                fromStyle = Palette.ResolveFor(null, null, fa, segments);
            }
```

and change the render line inside the frame loop to:

```csharp
                var f = Effects.Render(style, t, t, segments);
                if (fromStyle != null)
                {
                    // Sweep mix 0 -> 1 across the requested duration.
                    var mix = frames <= 1 ? 1.0 : (double)i / (frames - 1);
                    f = Effects.Blend(Effects.Render(fromStyle, t, t, segments), f, mix);
                }
```

- [ ] **Step 4: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 5: Add the blend tests**

Append to the `Effects engine` section in `scripts/Test-Repo.ps1`:

```powershell
    # A blend must start at the outgoing frame and end at the incoming one.
    $plain = @(Invoke-Dump @('--state','Error','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })
    $blend = @(Invoke-Dump @('--from','Done','--state','Error','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })
    $pureFrom = @(Invoke-Dump @('--state','Done','--segments','10','--seconds','1') | Where-Object { $_ -notmatch '^#' -and $_ })

    if ($blend.Count -eq $plain.Count -and $blend.Count -gt 1) { Ok 'blended dump has the expected frame count' }
    else { No 'blended dump frame count is wrong' "$($blend.Count) vs $($plain.Count)" }

    if ($blend[0] -eq $pureFrom[0]) { Ok 'blend at mix 0 equals the outgoing frame' }
    else { No 'blend at mix 0 is not the outgoing frame' }

    if ($blend[-1] -eq $plain[-1]) { Ok 'blend at mix 1 equals the incoming frame' }
    else { No 'blend at mix 1 is not the incoming frame' }

    # The middle must be neither endpoint, or nothing is actually being blended.
    $mid = $blend[[int]($blend.Count / 2)]
    if ($mid -ne $plain[[int]($blend.Count / 2)] -and $mid -ne $pureFrom[[int]($blend.Count / 2)]) {
        Ok 'blend midpoint differs from both endpoints'
    } else { No 'blend midpoint matches an endpoint' 'Frames are not being mixed.' }
```

- [ ] **Step 6: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===` with the four blend checks passing.

- [ ] **Step 7: Verify on hardware**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1 -Restart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 test ToolShell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 test Error
```

Expected: the second command's transition cross-fades the motion instead of snapping. This is the one property the automated tests cannot judge.

- [ ] **Step 8: Commit**

```bash
git add src/GoveeLights.Daemon/Effects.cs src/GoveeLights.Daemon/Renderer.cs \
        src/GoveeLights.Daemon/FrameDump.cs scripts/Test-Repo.ps1
git commit -m "Cross-fade whole frames so motion blends across state changes"
```

---

### Task 7: Documentation and version bump

**Files:**
- Create: `docs/EFFECTS.md`
- Modify: `config/config.example.json`
- Modify: `README.md`
- Modify: `src/GoveeLights.Daemon/GoveeLights.Daemon.csproj:15`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `Palette.KnownEffects` (Task 2) for the config validation check.
- Produces: nothing consumed by code.

- [ ] **Step 1: Write `docs/EFFECTS.md`**

Create the file with this content:

````markdown
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
| `sparkle` | no | Random-looking twinkle. `Hz` sets the twinkle rate. |
| `rainbow` | yes | Hue sweep across the strip. Ignores `Color`, `Color2`, `Easing` and `Depth`. |

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
````

- [ ] **Step 2: Update `config/config.example.json`**

**Leave the `States` values themselves exactly as they are.** The file documents itself as
the defaults written on first run, so it must keep mirroring `Palette.Defaults()`, which
this work does not change. Only the comment changes, plus a new non-functional showcase
block beneath it.

Replace the `_comment_states` line with:

```json
  "_comment_states": "Effects: solid, breathe, pulse, blink, chase, comet, wipe, progress, sparkle, rainbow. Chase, comet, wipe, progress and rainbow need SegmentNums > 1 and fall back to breathe otherwise. Every field is optional and inherits when omitted, so an entry may set Hz alone. Modifiers: Color2, Direction (forward|reverse|pingpong), Easing (linear|sine|cubic|expo), Tail, Depth, FullSeconds. Brightness -1 leaves it alone. See docs/EFFECTS.md.",
```

and insert this immediately after the closing brace of the `States` block. Keys starting
with `_` are ignored by the deserializer, so this is documentation that cannot drift out
of the file it documents:

```json
  "_examples_states": {
    "_comment": "Not read by the daemon - copy any of these into States above.",
    "scanner":     { "Effect": "chase", "Direction": "pingpong", "Hz": 0.8 },
    "two_colour":  { "Color": "#FF2020", "Color2": "#3A0000", "Effect": "blink", "Hz": 2.5 },
    "long_comet":  { "Effect": "comet", "Tail": 2.5, "Hz": 0.5 },
    "long_job":    { "Effect": "progress", "FullSeconds": 45 },
    "just_slower": { "Hz": 0.2 }
  },
```

Document per-device overrides without activating one — a live override in the reference
config would silently change behaviour for anyone who copied the file. Append this
sentence to the existing `_comment_devices` string:

```
 Each device may also carry its own "States" map, layered over the global one: {"Name":"Desk","States":{"Thinking":{"Effect":"solid"}}} makes only that device sit still while Thinking.
```

- [ ] **Step 3: Add a README section**

`README.md` already has a `## States` section (line 81) holding the priority/colour/effect
table, and a `## Configuration` section (line 106). Insert the new section **between
them** — immediately after the "Rapid tool bursts are coalesced…" paragraph that ends the
States section, and immediately before `## Configuration`.

The existing States table stays as it is: it documents `Palette.Defaults()`, which this
work does not change.

```markdown
## Customising the lights

Each activity state has its own colour and animation, set in the `States` block of
`%LOCALAPPDATA%\ClaudeGovee\config.json`. The file is hot-reloaded — save it and the
lights change immediately, no restart needed.

```json
"States": {
  "ToolShell": { "Color": "#FF7A18", "Effect": "chase", "Hz": 0.8, "Direction": "pingpong" }
}
```

Ten effects are available — `solid`, `breathe`, `pulse`, `blink`, `chase`, `comet`,
`wipe`, `progress`, `sparkle` and `rainbow` — each tunable with `Color2`,
`Direction`, `Easing`, `Tail` and `Depth`. Every field is optional and inherits when
omitted, so you can change one value without restating the rest. Individual devices
can override any state via a `States` block inside their `Devices` entry.

See [docs/EFFECTS.md](docs/EFFECTS.md) for the full reference, and run
`/govee test <state>` to preview a state on your lights.
```

- [ ] **Step 4: Bump the version**

In `src/GoveeLights.Daemon/GoveeLights.Daemon.csproj:15`, change:

```xml
    <Version>0.1.1</Version>
```

to:

```xml
    <Version>0.2.0</Version>
```

- [ ] **Step 5: Add the config-validation test**

Append to the `Effects engine` section in `scripts/Test-Repo.ps1`:

```powershell
    # Shipping an example config that names an effect the engine does not implement
    # would silently render everything as solid.
    $known = @('solid','breathe','pulse','blink','chase','comet','wipe','progress','sparkle','rainbow')
    if ($parsed['config/config.example.json']) {
        $badEffects = @()
        # Both the live States block and the _examples_states showcase, since a broken
        # example is exactly what a user would copy.
        foreach ($blockName in 'States', '_examples_states') {
            $block = $parsed['config/config.example.json'].$blockName
            if (-not $block) { continue }
            foreach ($p in $block.PSObject.Properties) {
                if ($p.Name -eq '_comment') { continue }
                $e = $p.Value.Effect
                if ($e -and ($known -notcontains $e)) { $badEffects += "$blockName.$($p.Name)=$e" }
            }
        }
        if ($badEffects.Count -eq 0) { Ok 'config.example.json names only known effects' }
        else { No 'config.example.json names an unknown effect' ($badEffects -join ', ') }
    }
```

Also add a docs presence check in the `Housekeeping` section, beside the existing `docs/API-NOTES.md` line:

```powershell
if (Test-Path (Join-Path $root 'docs/EFFECTS.md')) { Ok 'docs/EFFECTS.md present' } else { No 'docs/EFFECTS.md present' }
```

- [ ] **Step 6: Run the full test suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== N passed, 0 failed ===`.

- [ ] **Step 7: Verify the new effects on hardware**

The built-in state defaults are unchanged by this work, so `/govee test <state>` still
shows the original styles. To see the new effects on hardware, temporarily paste one of
the `_examples_states` entries into the live `States` block of
`%LOCALAPPDATA%\ClaudeGovee\config.json` — it hot-reloads on save — then test it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1 -Restart
# Paste {"Color":"#FF7A18","Effect":"chase","Direction":"pingpong","Hz":0.8} as ToolShell, save, then:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 test ToolShell
# Paste {"Color":"#00C8A0","Effect":"progress","FullSeconds":8} as Compacting, save, then:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 test Compacting
```

Expected: `ToolShell` bounces rather than wrapping, and `Compacting` fills as a bar.
Revert the config edits afterwards. If you have no Govee hardware to hand, say so and
skip this step — every other check in this task is automated.

- [ ] **Step 8: Commit**

```bash
git add docs/EFFECTS.md config/config.example.json README.md \
        src/GoveeLights.Daemon/GoveeLights.Daemon.csproj scripts/Test-Repo.ps1
git commit -m "Document the effects engine and bump to 0.2.0"
```

---

## Notes for the implementer

**The default config gets noisier.** `DaemonConfig.Save` uses `JavaScriptSerializer`,
which has no way to omit nulls, so the config written on first run will contain
`"Color2": null, "Direction": null, ...` for every state. This is accepted rather
than worked around: the file is hand-editable and the null fields double as a list
of the available knobs. Do not add a JSON library to avoid it — see Global
Constraints.

**One user-visible behaviour change.** Before this work, a `States` entry without a
`Color` was discarded entirely, so any other fields in it were ignored. Afterwards
it applies. Anyone with a half-filled entry sitting inert in their config will see
it start working. This is the bug fix, not a regression, but it belongs in the
release notes.

**Not in this plan.** `/govee set`, `/govee styles`, theme presets and daemon-side
config write-back are the separate control-plane spec, which depends on the
vocabulary built here.
