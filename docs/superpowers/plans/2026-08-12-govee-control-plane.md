# Govee Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user tune per-state light styles from the prompt — `/govee set`, `/govee styles`, `/govee save`, themes — instead of hand-editing `config.json`.

**Architecture:** `/govee set` writes into a new **pending layer** slotted into the existing merge exactly where the config layer sits, so edits show on the lights immediately without touching disk. `/govee save` splices only the `States` block back into the config file, leaving comments and every other key byte-for-byte intact. Themes are complete fourteen-state palettes: built-ins live in code, user themes are files.

**Tech Stack:** C# 7.3 targeting net48, `System.Web.Script.Serialization.JavaScriptSerializer`, PowerShell 5.1 for the CLI and tests. No new NuGet dependencies.

**Spec:** [docs/superpowers/specs/2026-08-12-govee-control-plane-design.md](../specs/2026-08-12-govee-control-plane-design.md)

## Global Constraints

- **Target framework is `net48`, language version `7.3`.** No switch expressions, no `??=`, no target-typed `new`, no nullable reference types, no records. `double?` / `int?` value nullables are fine. Generic methods are fine.
- **No new NuGet packages.** `GoveeAPI.dll` binds its own `Newtonsoft.Json` and `System.Text.Json`; competing copies break the runtime. Use `JavaScriptSerializer` only.
- **New `.cs` files are picked up automatically** — the csproj is SDK-style with default globbing. Do not add `<Compile>` items.
- **`OutputType` is `WinExe`.** Headless modes write to `Console.Out` with the caller redirecting; tests must use `Start-Process -Wait -RedirectStandardOutput`, never bare `&`.
- **Every number formatted for output or parsed from an argument uses `CultureInfo.InvariantCulture`.**
- **`Palette.ResolveFor` is the only public segment-aware resolve.** There is deliberately no segment-blind overload — one shipped previously and hard-cut single-zone devices to black. Do not add one.
- **The HTTP server stays bound to `IPAddress.Loopback`.** That is the security boundary; no endpoint may weaken it.
- **`tests/golden/*.csv` must stay byte-identical.** `git diff tests/golden` must be empty at every commit. Nothing in this plan should touch rendering.
- **Build:** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1`
- **Static tests:** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1` — baseline is **87 passed, 0 failed**.

## File Structure

| File | Responsibility |
|---|---|
| `src/GoveeLights.Daemon/StyleStore.cs` | **Create.** Owns everything mutable about styles: the pending map, tombstones, the transient preview slot. One lock, one owner. |
| `src/GoveeLights.Daemon/ConfigWriter.cs` | **Create.** One job: splice a `States` block into existing config text without disturbing anything else. |
| `src/GoveeLights.Daemon/Themes.cs` | **Create.** The `Theme` type, the built-in roster, and user-theme file load/save with name validation. |
| `src/GoveeLights.Daemon/StyleRoutes.cs` | **Create.** The nine HTTP handlers. Kept out of `Program.cs`, which is already the largest file. |
| `src/GoveeLights.Daemon/Palette.cs` | **Modify.** `ResolveFor`/`BuildLayers` take a `StyleStore`; known-value lists become public. |
| `src/GoveeLights.Daemon/Renderer.cs` | **Modify.** Pass the store through the two resolve calls. |
| `src/GoveeLights.Daemon/FrameDump.cs` | **Modify.** Three new headless modes: `--resolve-states`, `--splice-states`, `--list-known`. |
| `src/GoveeLights.Daemon/Program.cs` | **Modify.** Own the `StyleStore`, route to `StyleRoutes`, suppress the watcher during a self-write. |
| `scripts/Govee-Cli.ps1` | **Modify.** A real argument parser plus seven new verbs. |
| `scripts/Test-Repo.ps1` | **Modify.** Merge-layer, splicer and theme checks. |
| `tests/fixtures/*.json` | **Create.** Splicer fixtures. |

---

### Task 1: The pending layer

**Files:**
- Create: `src/GoveeLights.Daemon/StyleStore.cs`
- Modify: `src/GoveeLights.Daemon/Palette.cs`
- Modify: `src/GoveeLights.Daemon/Renderer.cs`
- Modify: `src/GoveeLights.Daemon/FrameDump.cs`
- Modify: `src/GoveeLights.Daemon/Program.cs`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `StateStyle` (all fields nullable), `DaemonConfig`, `DeviceConfig`, `Activity`, `Palette.ResolveStyleFor`.
- Produces:
  - `class StyleStore` with `bool Dirty`, `bool TryPending(string, out StateStyle)`, `void Set(string, StateStyle)`, `void Reset(string)`, `void ResetAll()`, `void Revert()`, `Dictionary<string,StateStyle> Merged(DaemonConfig)`, `void SetPreview(string, StateStyle, int)`, `StateStyle Preview(string)`, `static StateStyle Merge(StateStyle, StateStyle)`
  - `Palette.ResolveFor(DaemonConfig cfg, StyleStore pending, DeviceConfig device, Activity state, int segments)` — **new signature**
  - `Palette.KnownEffects / KnownDirections / KnownEasings` as `public static string[] …()` returning fresh copies
  - `FrameDump` accepts `--resolve-states` and `--list-known`

- [ ] **Step 1: Create `StyleStore.cs`**

```csharp
using System;
using System.Collections.Generic;

namespace GoveeLights
{
    /// <summary>
    /// Everything mutable about styles: unsaved edits and the transient preview slot.
    ///
    /// One owner and one lock, so the control plane never reaches into Program's config
    /// field - which the render thread reads 25 times a second.
    ///
    /// A key present with a NULL value is a tombstone: "suppress the config layer for
    /// this state". An all-null StateStyle cannot express that, because every-field-null
    /// already means "inherit", which is a no-op.
    /// </summary>
    public sealed class StyleStore
    {
        readonly object _gate = new object();
        readonly Dictionary<string, StateStyle> _pending =
            new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);

        string _previewState;
        StateStyle _previewPatch;
        DateTime _previewUntil = DateTime.MinValue;

        public bool Dirty { get { lock (_gate) return _pending.Count > 0; } }

        public bool TryPending(string state, out StateStyle style)
        {
            lock (_gate) return _pending.TryGetValue(state, out style);
        }

        /// <summary>Field-wise patch. A null field in the patch leaves the current value
        /// alone, so `set Thinking --hz 2` does not blank the colour.</summary>
        public void Set(string state, StateStyle patch)
        {
            lock (_gate)
            {
                StateStyle existing;
                // A tombstone stored as null must not be merged into - patching a
                // "cleared" state starts from empty, not from the config it suppressed.
                if (!_pending.TryGetValue(state, out existing)) existing = null;
                _pending[state] = Merge(existing, patch);
            }
        }

        public void Reset(string state) { lock (_gate) _pending[state] = null; }

        public void ResetAll()
        {
            lock (_gate)
            {
                foreach (var name in Enum.GetNames(typeof(Activity))) _pending[name] = null;
            }
        }

        public void Revert() { lock (_gate) _pending.Clear(); }

        /// <summary>What `save` writes: the config's States with pending applied on top.
        /// Tombstoned states are omitted entirely, which is what makes them fall back to
        /// the built-in defaults on the next load.</summary>
        public Dictionary<string, StateStyle> Merged(DaemonConfig cfg)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            if (cfg != null && cfg.States != null)
                foreach (var kv in cfg.States) o[kv.Key] = kv.Value;

            lock (_gate)
            {
                foreach (var kv in _pending)
                {
                    if (kv.Value == null) { o.Remove(kv.Key); continue; }
                    StateStyle basis;
                    o[kv.Key] = Merge(o.TryGetValue(kv.Key, out basis) ? basis : null, kv.Value);
                }
            }
            return o;
        }

        public void SetPreview(string state, StateStyle patch, int holdMs)
        {
            lock (_gate)
            {
                _previewState = state;
                _previewPatch = patch;
                _previewUntil = DateTime.UtcNow.AddMilliseconds(holdMs);
            }
        }

        /// <summary>The preview patch for a state, or null once it has expired. Expiry is
        /// read at resolve time rather than swept by a timer - the render loop asks 25
        /// times a second, so there is nothing a timer would do sooner.</summary>
        public StateStyle Preview(string state)
        {
            lock (_gate)
            {
                if (_previewPatch == null || DateTime.UtcNow >= _previewUntil) return null;
                return string.Equals(_previewState, state, StringComparison.OrdinalIgnoreCase)
                    ? _previewPatch : null;
            }
        }

        /// <summary>Non-null fields of `patch` win over `basis`. Either may be null.</summary>
        public static StateStyle Merge(StateStyle basis, StateStyle patch)
        {
            if (patch == null) return basis;
            if (basis == null) basis = new StateStyle();
            return new StateStyle
            {
                Color       = patch.Color       ?? basis.Color,
                Color2      = patch.Color2      ?? basis.Color2,
                Effect      = patch.Effect      ?? basis.Effect,
                Hz          = patch.Hz          ?? basis.Hz,
                Brightness  = patch.Brightness  ?? basis.Brightness,
                Direction   = patch.Direction   ?? basis.Direction,
                Easing      = patch.Easing      ?? basis.Easing,
                Tail        = patch.Tail        ?? basis.Tail,
                Depth       = patch.Depth       ?? basis.Depth,
                FullSeconds = patch.FullSeconds ?? basis.FullSeconds
            };
        }
    }
}
```

- [ ] **Step 2: Slot the layer into `Palette`**

In `src/GoveeLights.Daemon/Palette.cs`, replace `ResolveFor` and `BuildLayers` with:

```csharp
        public static ResolvedStyle ResolveFor(DaemonConfig cfg, StyleStore pending,
                                               DeviceConfig device, Activity state, int segments)
        {
            return ResolveStyleFor(segments, BuildLayers(cfg, pending, device, state));
        }

        static StateStyle[] BuildLayers(DaemonConfig cfg, StyleStore pending,
                                        DeviceConfig device, Activity state)
        {
            var key = state.ToString();
            var layers = new List<StateStyle>(5);

            StateStyle s;
            if (_stateDefaults.TryGetValue(key, out s)) layers.Add(s);
            else layers.Add(_stateDefaults["Idle"]);

            // The pending layer is a shadow of cfg.States and sits exactly where it sits:
            // stronger than the file, weaker than a device's own override. A tombstone
            // (present, null) suppresses the file layer without adding one of its own.
            StateStyle pend = null;
            var hasPending = pending != null && pending.TryPending(key, out pend);
            var tombstoned = hasPending && pend == null;

            if (!tombstoned && cfg != null && cfg.States != null &&
                cfg.States.TryGetValue(key, out s) && s != null) layers.Add(s);
            if (hasPending && pend != null) layers.Add(pend);

            if (device != null && device.States != null &&
                device.States.TryGetValue(key, out s) && s != null) layers.Add(s);

            // Preview is deliberately strongest and deliberately transient: it exists so
            // you can see a style you have not committed to, including over a device
            // override that would otherwise mask it.
            if (pending != null)
            {
                var prev = pending.Preview(key);
                if (prev != null) layers.Add(prev);
            }

            return layers.ToArray();
        }
```

- [ ] **Step 3: Export the known-value lists**

Still in `Palette.cs`, the three arrays are currently private. Keep the fields private and add copy-returning accessors beneath them, so no caller can mutate the originals:

```csharp
        // Copies, not the arrays themselves: a public static readonly string[] hands
        // every caller a writable reference to the engine's own vocabulary.
        public static string[] EffectNames() { return (string[])KnownEffects.Clone(); }
        public static string[] DirectionNames() { return (string[])KnownDirections.Clone(); }
        public static string[] EasingNames() { return (string[])KnownEasings.Clone(); }
```

- [ ] **Step 4: Update the four call sites**

`src/GoveeLights.Daemon/Renderer.cs` — the renderer needs the store. Add a field and constructor parameter:

```csharp
        readonly StyleStore _styles;

        public Renderer(GoveeClient govee, SessionStore sessions, Func<DaemonConfig> cfg, StyleStore styles)
        {
            _govee = govee;
            _sessions = sessions;
            _cfg = cfg;
            _styles = styles;
            _thread = new Thread(Loop) { Name = "renderer", IsBackground = true };
            _thread.Start();
        }
```

and in `TickOnce`'s device loop, both resolve calls become:

```csharp
                var style = Palette.ResolveFor(cfg, _styles, d.Cfg, _current, segs);
                // ...
                    var prev = Palette.ResolveFor(cfg, _styles, d.Cfg, _previous, segs);
```

`src/GoveeLights.Daemon/Program.cs` — add the static and pass it:

```csharp
        static StyleStore _styles = new StyleStore();
```

and change the renderer construction to `new Renderer(_govee, _sessions, Cfg, _styles)`.

`src/GoveeLights.Daemon/FrameDump.cs` — its two `ResolveFor` calls pass `null` for the store, since a frame dump has no pending state unless `--pending` supplied one (Step 5 threads it through).

- [ ] **Step 5: Add `--resolve-states` and `--list-known` to the harness**

In `FrameDump.cs`, add to the top of `Run`, immediately after the two `Log` flags are set:

```csharp
            if (HasFlag(args, "--list-known")) return ListKnown();
            if (HasFlag(args, "--resolve-states")) return ResolveStates(args);
```

and add the two modes plus a flag helper:

```csharp
        static bool HasFlag(string[] args, string name)
        {
            for (int i = 0; i < args.Length; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        /// <summary>The engine's vocabulary, so Test-Repo and the CLI can validate against
        /// the real lists instead of restating them.</summary>
        static int ListKnown()
        {
            Console.Out.WriteLine("effects," + string.Join(",", Palette.EffectNames()));
            Console.Out.WriteLine("directions," + string.Join(",", Palette.DirectionNames()));
            Console.Out.WriteLine("easings," + string.Join(",", Palette.EasingNames()));
            Console.Out.Flush();
            return 0;
        }

        /// <summary>Resolve every state through the full layer stack and print it, so the
        /// merge is testable without hardware. --pending takes the same shape StyleStore
        /// holds: state name to a partial StateStyle, or literal null for a tombstone.</summary>
        static int ResolveStates(string[] args)
        {
            var configPath = Arg(args, "--config", null);
            DaemonConfig cfg = null;
            if (!string.IsNullOrEmpty(configPath))
            {
                string e;
                cfg = DaemonConfig.Load(configPath, out e);
                if (cfg == null) { Console.Error.WriteLine("bad --config: " + e); return 2; }
            }

            var store = new StyleStore();
            var pendingJson = Arg(args, "--pending", null);
            if (!string.IsNullOrEmpty(pendingJson))
            {
                Dictionary<string, StateStyle> parsed;
                try { parsed = new JavaScriptSerializer().Deserialize<Dictionary<string, StateStyle>>(pendingJson); }
                catch (Exception ex) { Console.Error.WriteLine("bad --pending: " + ex.Message); return 2; }
                if (parsed != null)
                    foreach (var kv in parsed)
                    {
                        if (kv.Value == null) store.Reset(kv.Key);
                        else store.Set(kv.Key, kv.Value);
                    }
            }

            DeviceConfig dev = null;
            var deviceName = Arg(args, "--device", null);
            if (cfg != null && !string.IsNullOrEmpty(deviceName))
            {
                dev = cfg.Devices.FirstOrDefault(x => x != null &&
                          string.Equals(x.Name, deviceName, StringComparison.OrdinalIgnoreCase));
                if (dev == null)
                {
                    Console.Error.WriteLine("unknown --device: " + deviceName);
                    return 2;
                }
            }

            var segments = ArgInt(args, "--segments", 10);
            if (segments < 1) segments = 1;

            var w = Console.Out;
            w.WriteLine("state,effect,color,color2,hz,brightness,direction,easing,tail,depth,fullseconds");
            foreach (var name in Enum.GetNames(typeof(Activity)))
            {
                Activity a;
                Enum.TryParse(name, true, out a);
                var r = Palette.ResolveFor(cfg, store, dev, a, segments);
                w.WriteLine(string.Join(",", new[]
                {
                    name, r.Effect, r.Color.ToHex(), r.HasColor2 ? r.Color2.ToHex() : "none",
                    r.Hz.ToString("0.###", CultureInfo.InvariantCulture),
                    r.Brightness.ToString(CultureInfo.InvariantCulture),
                    r.Direction, r.Easing,
                    r.Tail.ToString("0.###", CultureInfo.InvariantCulture),
                    r.Depth.ToString("0.###", CultureInfo.InvariantCulture),
                    r.FullSeconds.ToString("0.###", CultureInfo.InvariantCulture)
                }));
            }
            w.Flush();
            return 0;
        }
```

Add `using System.Collections.Generic;` to `FrameDump.cs` if it is not already present.

- [ ] **Step 6: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds, 0 warnings.

- [ ] **Step 7: Add a fixture and the merge-layer tests**

Create `tests/fixtures/pending-layers.json`:

```json
{
  "Enabled": true,
  "ApiGuid": "00000000-0000-0000-0000-000000000000",
  "Port": 17321,
  "States": {
    "Thinking": { "Color": "#111111", "Hz": 0.4 }
  },
  "Devices": [
    { "Name": "DeskStrip" },
    { "Name": "CeilingStrip", "States": { "Thinking": { "Color": "#333333" } } }
  ]
}
```

Append to the `Effects engine` section of `scripts/Test-Repo.ps1`, inside its `else` branch:

```powershell
    # ---- pending layer -----------------------------------------------------
    # The layer /govee set writes into. It must beat the config file, lose to a
    # device's own override, and its tombstone must drop the config layer entirely.
    function Get-ResolvedRow {
        param([string[]] $ExtraArgs, [string] $State)
        $lines = Invoke-Dump (@('--resolve-states') + $ExtraArgs)
        $row = @($lines | Where-Object { $_ -like "$State,*" })
        if ($row.Count -ne 1) { return $null }
        $f = $row[0].Split(',')
        return @{ effect = $f[1]; color = $f[2]; hz = $f[4] }
    }

    $pl = Join-Path $root 'tests/fixtures/pending-layers.json'

    $base = Get-ResolvedRow @('--config', $pl) 'Thinking'
    if ($base -and $base.color -eq '#111111' -and $base.hz -eq '0.4') {
        Ok 'config States resolves when nothing is pending' "$($base.color) @ $($base.hz)Hz"
    } else { No 'config States did not resolve' ($base | Out-String) }

    # Pending beats the file. Colour changes, and Hz is NOT restated in the patch -
    # so if pending replaced the layer wholesale instead of merging, Hz would revert.
    $ov = Get-ResolvedRow @('--config', $pl, '--pending', '{"Thinking":{"Color":"#222222"}}') 'Thinking'
    if ($ov -and $ov.color -eq '#222222' -and $ov.hz -eq '0.4') {
        Ok 'pending beats config and merges field-wise' "$($ov.color) @ $($ov.hz)Hz"
    } else { No 'pending layer wrong' ($ov | Out-String) }

    # A device override still wins over pending.
    $dv = Get-ResolvedRow @('--config', $pl, '--device', 'CeilingStrip',
                            '--pending', '{"Thinking":{"Color":"#222222"}}') 'Thinking'
    if ($dv -and $dv.color -eq '#333333') { Ok 'device override still beats pending' $dv.color }
    else { No 'pending wrongly beat the device layer' ($dv | Out-String) }

    # Tombstone drops the config layer back to the built-in default (#7B4DFF).
    $tb = Get-ResolvedRow @('--config', $pl, '--pending', '{"Thinking":null}') 'Thinking'
    if ($tb -and $tb.color -eq '#7B4DFF' -and $tb.hz -eq '0.6') {
        Ok 'tombstone falls back to the built-in default' "$($tb.color) @ $($tb.hz)Hz"
    } else { No 'tombstone did not clear the config layer' ($tb | Out-String) }

    # ---- known-value export ------------------------------------------------
    $known = @(Invoke-Dump @('--list-known'))
    $effectsLine = @($known | Where-Object { $_ -like 'effects,*' })
    if ($effectsLine.Count -eq 1 -and ($effectsLine[0].Split(',').Count - 1) -eq 10) {
        Ok '--list-known reports all ten effects'
    } else { No '--list-known effect list wrong' ($effectsLine -join ' ') }
```

Then replace the hardcoded `$known` array in the existing example-config check with the exported list, so the engine's vocabulary is stated once:

```powershell
    $known = @($effectsLine[0].Split(',') | Select-Object -Skip 1)
```

- [ ] **Step 8: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 92 passed, 0 failed ===` (87 baseline + 5 new). `git diff tests/golden` must be empty.

- [ ] **Step 9: Commit**

```bash
git add src/GoveeLights.Daemon/StyleStore.cs src/GoveeLights.Daemon/Palette.cs \
        src/GoveeLights.Daemon/Renderer.cs src/GoveeLights.Daemon/FrameDump.cs \
        src/GoveeLights.Daemon/Program.cs scripts/Test-Repo.ps1 tests/fixtures/pending-layers.json
git commit -m "Add the pending style layer between config and device"
```

**Amended during review.** The three-valued `_pending` model above (absent | null |
patch) cannot represent "cleared *and* patched": a `Set` after a `Reset` lifted the
tombstone, so both the resolve and `Merged()` restored config values the user had just
cleared — and Tasks 4-6 drive exactly that sequence. `StyleStore` now holds a separate
`HashSet<string> _cleared` beside `_pending`, both under the same lock, with
`bool IsCleared(string)` exposed; `Reset`/`ResetAll` add to `_cleared` without touching
patches, `Set` leaves `_cleared` alone, `Revert` clears both, `Merged` uses a null basis
for cleared states, and `BuildLayers` skips `cfg.States` when `IsCleared(key)`. The
repository is the authority; the code in this task's steps is the pre-fix version.

A consequence for Task 5, **corrected after review**: an earlier version of this note
claimed `ThemeApply` could call `ResetAll()` then `Set` per state and get totality for
free. That is wrong, and the error is worth recording. `ResetAll` adds to `_cleared`
only — it deliberately does not touch `_pending`, because `/styles/reset --all` means
"suppress the config layer, keep patches". So a reset before the `Set` loop does nothing
to the *previous* theme, which is still sitting in `_pending`, and `Set` merges field-wise
over it: a field the incoming theme leaves null inherits the outgoing theme's value.
Worse, a state the theme never mentions keeps any earlier `/styles/set` patch, and
`Merged()` writes it into a saved theme file.

`ThemeApply` must therefore call `Revert()` **and** `ResetAll(cfg)` before applying, inside
the same lock. Revert clears both structures; ResetAll then re-suppresses the config layer.
Discarding prior unsaved edits is exactly what "applying a theme is total" means.

---

### Task 2: The config splicer

The piece that writes the user's file. Everything here is defensive on purpose.

**Files:**
- Create: `src/GoveeLights.Daemon/ConfigWriter.cs`
- Modify: `src/GoveeLights.Daemon/FrameDump.cs`
- Create: `tests/fixtures/splice-*.json`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `DaemonConfig.Load`, `StateStyle`.
- Produces:
  - `ConfigWriter.TrySpliceStates(string json, string statesBlock, out string result, out string error) -> bool`
  - `ConfigWriter.RenderStates(Dictionary<string,StateStyle> states, int indentSpaces) -> string`
  - `ConfigWriter.TrySave(string path, Dictionary<string,StateStyle> states, out string error) -> bool`
  - `FrameDump` accepts `--splice-states --config <path> --states <json>`

- [ ] **Step 1: Create `ConfigWriter.cs`**

```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>
    /// Replaces the top-level "States" block in a config file, leaving every other byte
    /// alone.
    ///
    /// A full round-trip through JavaScriptSerializer would be far simpler, and would
    /// silently delete every _comment key in the file - including the ones the shipped
    /// example config and the README rely on to explain themselves. So this edits the
    /// text instead.
    ///
    /// Depth matters: Devices[].States exists, and _examples_states sits alongside, so
    /// only a "States" key at depth 1 is the right one.
    /// </summary>
    public static class ConfigWriter
    {
        public static bool TrySpliceStates(string json, string statesBlock,
                                           out string result, out string error)
        {
            result = null; error = null;
            if (json == null) { error = "no config text"; return false; }

            int keyStart, valueStart, valueEnd, indent;
            if (FindTopLevelStates(json, out keyStart, out valueStart, out valueEnd, out indent))
            {
                result = json.Substring(0, valueStart) + statesBlock + json.Substring(valueEnd);
                return true;
            }

            // No States key: insert one before the final closing brace.
            var close = json.LastIndexOf('}');
            if (close < 0) { error = "config has no closing brace"; return false; }

            var head = json.Substring(0, close).TrimEnd();
            var sep = head.EndsWith("{") ? "" : ",";
            result = head + sep + "\n  \"States\": " + statesBlock + "\n" + json.Substring(close);
            return true;
        }

        /// <summary>Locate the depth-1 "States" member. valueStart/valueEnd bracket its
        /// object value; indent is the column its key started at.</summary>
        static bool FindTopLevelStates(string json, out int keyStart, out int valueStart,
                                       out int valueEnd, out int indent)
        {
            keyStart = valueStart = valueEnd = -1; indent = 2;

            int depth = 0, i = 0, lineStart = 0;
            bool inStr = false, esc = false;

            while (i < json.Length)
            {
                var c = json[i];

                if (esc) { esc = false; i++; continue; }
                if (c == '\\' && inStr) { esc = true; i++; continue; }
                if (c == '"' && !inStr)
                {
                    // A key only counts at depth 1 and only if it is followed by a colon.
                    if (depth == 1 && MatchesKey(json, i, "States"))
                    {
                        var afterKey = i + 8; // "States" plus both quotes
                        var j = SkipWhitespace(json, afterKey);
                        if (j < json.Length && json[j] == ':')
                        {
                            j = SkipWhitespace(json, j + 1);
                            if (j < json.Length && json[j] == '{')
                            {
                                keyStart = i;
                                valueStart = j;
                                valueEnd = MatchBrace(json, j);
                                indent = i - lineStart;
                                return valueEnd > 0;
                            }
                        }
                    }
                    inStr = true; i++; continue;
                }
                if (c == '"') { inStr = false; i++; continue; }
                if (inStr) { i++; continue; }

                if (c == '\n') lineStart = i + 1;
                else if (c == '{' || c == '[') depth++;
                else if (c == '}' || c == ']') depth--;
                i++;
            }
            return false;
        }

        static bool MatchesKey(string json, int quoteIndex, string key)
        {
            if (quoteIndex + key.Length + 1 >= json.Length) return false;
            if (json[quoteIndex + key.Length + 1] != '"') return false;
            return string.CompareOrdinal(json, quoteIndex + 1, key, 0, key.Length) == 0;
        }

        static int SkipWhitespace(string json, int i)
        {
            while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
            return i;
        }

        /// <summary>Index just past the '}' matching the '{' at open, or -1.</summary>
        static int MatchBrace(string json, int open)
        {
            int depth = 0;
            bool inStr = false, esc = false;
            for (int i = open; i < json.Length; i++)
            {
                var c = json[i];
                if (esc) { esc = false; continue; }
                if (c == '\\' && inStr) { esc = true; continue; }
                if (c == '"') { inStr = !inStr; continue; }
                if (inStr) continue;
                if (c == '{') depth++;
                else if (c == '}') { depth--; if (depth == 0) return i + 1; }
            }
            return -1;
        }

        /// <summary>Render a States block at the file's own 2-space convention.</summary>
        public static string RenderStates(Dictionary<string, StateStyle> states, int indentSpaces)
        {
            if (states == null) states = new Dictionary<string, StateStyle>();
            var pad = new string(' ', indentSpaces);
            var inner = pad + "  ";

            var ser = new JavaScriptSerializer();
            var sb = new StringBuilder();
            sb.Append("{");

            var first = true;
            foreach (var kv in states)
            {
                if (kv.Value == null) continue;
                var body = StripNullMembers(ser.Serialize(kv.Value));
                if (body == "{}") continue;          // an all-null style says nothing
                if (!first) sb.Append(",");
                first = false;
                sb.Append("\n").Append(inner).Append(ser.Serialize(kv.Key)).Append(": ").Append(body);
            }

            if (!first) sb.Append("\n").Append(pad);
            sb.Append("}");
            return sb.ToString();
        }

        /// <summary>Same intent as DaemonConfig's null stripper, scoped to one object and
        /// kept here so the writer does not depend on that private helper.</summary>
        static string StripNullMembers(string json)
        {
            var ser = new JavaScriptSerializer();
            var map = ser.Deserialize<Dictionary<string, object>>(json);
            var keep = new Dictionary<string, object>();
            foreach (var kv in map) if (kv.Value != null) keep[kv.Key] = kv.Value;
            return ser.Serialize(keep);
        }

        /// <summary>Splice, validate by round-trip, then replace atomically. Returns false
        /// and writes nothing if anything looks wrong - a splicer that silently corrupts a
        /// config is worse than one that refuses.</summary>
        public static bool TrySave(string path, Dictionary<string, StateStyle> states, out string error)
        {
            error = null;
            try
            {
                var original = File.ReadAllText(path);

                // Reuse the existing key's column so a save does not reformat the file.
                // FindTopLevelStates leaves indent at its default of 2 when there is no
                // States key yet, which is the right column for an inserted one.
                int ks, vs, ve, indent;
                FindTopLevelStates(original, out ks, out vs, out ve, out indent);

                string spliced;
                if (!TrySpliceStates(original, RenderStates(states, indent), out spliced, out error))
                    return false;

                // Round-trip: the result must parse, and must carry exactly the states we
                // meant to write.
                var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
                DaemonConfig check;
                try { check = ser.Deserialize<DaemonConfig>(spliced); }
                catch (Exception ex) { error = "spliced config does not parse: " + ex.Message; return false; }
                if (check == null) { error = "spliced config deserialized to null"; return false; }

                var wrote = check.States ?? new Dictionary<string, StateStyle>();
                var wanted = 0;
                foreach (var kv in states) if (kv.Value != null) wanted++;
                if (wrote.Count != wanted)
                {
                    error = "round-trip mismatch: wrote " + wrote.Count + ", expected " + wanted;
                    return false;
                }

                var tmp = path + ".tmp";
                File.WriteAllText(tmp, spliced);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
```

- [ ] **Step 2: Add `--splice-states` to the harness**

In `FrameDump.Run`, beside the other early dispatches:

```csharp
            if (HasFlag(args, "--splice-states")) return SpliceStates(args);
```

and:

```csharp
        /// <summary>Print the spliced config to stdout without writing anything, so the
        /// riskiest code in the daemon is testable against hostile fixtures.</summary>
        static int SpliceStates(string[] args)
        {
            var configPath = Arg(args, "--config", null);
            if (string.IsNullOrEmpty(configPath)) { Console.Error.WriteLine("--splice-states needs --config"); return 2; }
            if (!File.Exists(configPath)) { Console.Error.WriteLine("no such config: " + configPath); return 2; }

            var statesJson = Arg(args, "--states", null);
            if (string.IsNullOrEmpty(statesJson)) { Console.Error.WriteLine("--splice-states needs --states"); return 2; }

            Dictionary<string, StateStyle> states;
            try { states = new JavaScriptSerializer().Deserialize<Dictionary<string, StateStyle>>(statesJson); }
            catch (Exception ex) { Console.Error.WriteLine("bad --states: " + ex.Message); return 2; }
            if (states == null) states = new Dictionary<string, StateStyle>();

            var original = File.ReadAllText(configPath);
            string result, error;
            if (!ConfigWriter.TrySpliceStates(original, ConfigWriter.RenderStates(states, 2), out result, out error))
            {
                Console.Error.WriteLine("splice failed: " + error);
                return 2;
            }
            Console.Out.Write(result);
            Console.Out.Flush();
            return 0;
        }
```

Add `using System.IO;` to `FrameDump.cs` if absent.

- [ ] **Step 3: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 4: Create the five hostile fixtures**

`tests/fixtures/splice-comments.json`:

```json
{
  "_comment": "KEEP ME",
  "ApiGuid": "00000000-0000-0000-0000-000000000000",
  "Port": 17321,
  "States": {
    "Thinking": { "Color": "#111111" }
  },
  "_comment_tail": "KEEP ME TOO"
}
```

`tests/fixtures/splice-examples.json`:

```json
{
  "Port": 17321,
  "States": {
    "Thinking": { "Color": "#111111" }
  },
  "_examples_states": {
    "recipe_scanner": { "Effect": "chase", "Direction": "pingpong" }
  }
}
```

`tests/fixtures/splice-devicestates.json`:

```json
{
  "Port": 17321,
  "Devices": [
    { "Name": "CeilingStrip", "States": { "Thinking": { "Effect": "solid" } } }
  ],
  "States": {
    "Thinking": { "Color": "#111111" }
  }
}
```

`tests/fixtures/splice-nostates.json`:

```json
{
  "Port": 17321,
  "RestColor": "#FFD9A0"
}
```

`tests/fixtures/splice-stringtrap.json`:

```json
{
  "Port": 17321,
  "_comment": "this string literally contains \"States\": { \"Thinking\": { } } and must not be spliced",
  "States": {
    "Thinking": { "Color": "#111111" }
  }
}
```

- [ ] **Step 5: Add the splicer tests**

Append inside the same `else` branch of `scripts/Test-Repo.ps1`:

```powershell
    # ---- config splicer ----------------------------------------------------
    # This is the code that rewrites the user's config file. Each fixture is a way
    # a naive substring replace would corrupt it.
    function Invoke-Splice {
        param([string] $Fixture, [string] $StatesJson)
        $p = Join-Path $root "tests/fixtures/$Fixture"
        return (Invoke-Dump @('--splice-states', '--config', $p, '--states', $StatesJson)) -join "`n"
    }

    $newStates = '{"Thinking":{"Color":"#ABCDEF"}}'

    $r = Invoke-Splice 'splice-comments.json' $newStates
    if ($r -match 'KEEP ME' -and $r -match 'KEEP ME TOO' -and $r -match '#ABCDEF' -and $r -notmatch '#111111') {
        Ok 'splice preserves comments either side of States'
    } else { No 'splice lost a comment or missed the block' $r }

    $r = Invoke-Splice 'splice-examples.json' $newStates
    if ($r -match 'recipe_scanner' -and $r -match '#ABCDEF' -and $r -notmatch '#111111') {
        Ok 'splice leaves _examples_states alone'
    } else { No 'splice damaged _examples_states' $r }

    # The device's own States block must survive untouched - it is a different key
    # at a deeper level, and matching it would silently move a per-device override.
    $r = Invoke-Splice 'splice-devicestates.json' $newStates
    if ($r -match '"Effect":\s*"solid"' -and $r -match '#ABCDEF' -and $r -notmatch '#111111') {
        Ok 'splice does not touch Devices[].States'
    } else { No 'splice hit a device States block' $r }

    # No States key at all: one must be inserted, and the file must stay valid JSON.
    $r = Invoke-Splice 'splice-nostates.json' $newStates
    $parsed2 = $null
    try { $parsed2 = $r | ConvertFrom-Json } catch { }
    if ($parsed2 -and $parsed2.States.Thinking.Color -eq '#ABCDEF' -and $parsed2.RestColor -eq '#FFD9A0') {
        Ok 'splice inserts a States block when none exists'
    } else { No 'splice failed to insert States' $r }

    # A string VALUE containing the text "States": must not be mistaken for the key.
    $r = Invoke-Splice 'splice-stringtrap.json' $newStates
    $parsed3 = $null
    try { $parsed3 = $r | ConvertFrom-Json } catch { }
    if ($parsed3 -and $parsed3.States.Thinking.Color -eq '#ABCDEF' -and
        $parsed3._comment -match 'must not be spliced') {
        Ok 'splice ignores a "States": inside a string value'
    } else { No 'splice was fooled by a string literal' $r }

    # Every spliced result must still be valid JSON - the round-trip guard in TrySave
    # depends on this being true of TrySpliceStates output.
    $allValid = $true
    foreach ($f in 'splice-comments.json','splice-examples.json','splice-devicestates.json',
                   'splice-nostates.json','splice-stringtrap.json') {
        try { (Invoke-Splice $f $newStates) | ConvertFrom-Json | Out-Null } catch { $allValid = $false }
    }
    if ($allValid) { Ok 'every spliced fixture is valid JSON' } else { No 'a spliced fixture is not valid JSON' }
```

- [ ] **Step 6: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 98 passed, 0 failed ===` (92 + 6 new). `git diff tests/golden` empty.

- [ ] **Step 7: Commit**

```bash
git add src/GoveeLights.Daemon/ConfigWriter.cs src/GoveeLights.Daemon/FrameDump.cs \
        scripts/Test-Repo.ps1 tests/fixtures
git commit -m "Splice the States block instead of rewriting the whole config"
```

---

### Task 3: Themes

**Files:**
- Create: `src/GoveeLights.Daemon/Themes.cs`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: `StateStyle`, `Palette.Defaults()`, `Activity`.
- Produces:
  - `class Theme { string Name; string Description; Dictionary<string,StateStyle> States; }`
  - `Themes.BuiltIn() -> Dictionary<string, Theme>`
  - `Themes.UserDir -> string`
  - `Themes.IsValidName(string) -> bool`
  - `Themes.List() -> List<ThemeInfo>` where `ThemeInfo { string Name; string Description; bool Builtin; bool Shadowed; }`
  - `Themes.TryLoad(string name, out Theme, out string error) -> bool`
  - `Themes.TrySave(string name, Dictionary<string,StateStyle> states, out string error) -> bool`
  - `FrameDump` accepts `--list-themes`

- [ ] **Step 1: Create `Themes.cs`**

```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    public sealed class Theme
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public Dictionary<string, StateStyle> States { get; set; }
    }

    public sealed class ThemeInfo
    {
        public string Name;
        public string Description;
        public bool Builtin;
        public bool Shadowed;   // a user theme of the same name is in force
    }

    /// <summary>
    /// Built-in themes live in code, not in files: Ensure-Daemon launches the executable
    /// with no arguments and dist/daemon holds only the exe, so there is no reliable way
    /// to find plugin-relative data. Palette.Defaults() already sets this precedent.
    ///
    /// User themes are one file per theme, and shadow a built-in of the same name. Since
    /// built-ins are never written to, shadowing is always undone by deleting the file.
    /// </summary>
    public static class Themes
    {
        public static string UserDir
        {
            get { return Path.Combine(DaemonConfig.DefaultDir, "themes"); }
        }

        static readonly Regex NamePattern = new Regex(@"^[A-Za-z0-9_-]{1,32}$", RegexOptions.Compiled);

        /// <summary>A theme name becomes a filename, so it is validated rather than
        /// sanitised - a name that needs cleaning up is a name the user should retype.</summary>
        public static bool IsValidName(string name)
        {
            return !string.IsNullOrEmpty(name) && NamePattern.IsMatch(name);
        }

        public static Dictionary<string, Theme> BuiltIn()
        {
            var o = new Dictionary<string, Theme>(StringComparer.OrdinalIgnoreCase);

            o["default"] = new Theme
            {
                Name = "default",
                Description = "The built-in palette",
                States = Palette.Defaults()
            };

            o["muted"] = new Theme
            {
                Name = "muted",
                Description = "Dim and slow, for a shared room",
                States = Scale(Palette.Defaults(), 0.45, 0.5)
            };

            o["vivid"] = new Theme
            {
                Name = "vivid",
                Description = "Brighter and faster",
                States = Scale(Palette.Defaults(), 1.0, 1.6)
            };

            o["mono"] = new Theme
            {
                Name = "mono",
                Description = "One hue; effect carries the distinction",
                States = Monochrome(Palette.Defaults(), "#5B8CFF")
            };

            return o;
        }

        /// <summary>Brightness and rate scaling, clamped to the ranges the engine accepts.
        /// Colours are untouched: a muted theme should read as the same palette turned
        /// down, not as a different one.</summary>
        static Dictionary<string, StateStyle> Scale(Dictionary<string, StateStyle> src,
                                                    double brightness, double hz)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in src)
            {
                var s = kv.Value;
                var b = s.Brightness.HasValue && s.Brightness.Value > 0
                    ? (int?)Math.Max(1, Math.Min(100, (int)Math.Round(s.Brightness.Value * brightness)))
                    : s.Brightness;
                var h = s.Hz.HasValue && s.Hz.Value > 0 ? (double?)(s.Hz.Value * hz) : s.Hz;
                o[kv.Key] = new StateStyle
                {
                    Color = s.Color, Color2 = s.Color2, Effect = s.Effect,
                    Hz = h, Brightness = b,
                    Direction = s.Direction, Easing = s.Easing,
                    Tail = s.Tail, Depth = s.Depth, FullSeconds = s.FullSeconds
                };
            }
            return o;
        }

        static Dictionary<string, StateStyle> Monochrome(Dictionary<string, StateStyle> src, string hex)
        {
            var o = new Dictionary<string, StateStyle>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in src)
            {
                var s = kv.Value;
                o[kv.Key] = new StateStyle
                {
                    Color = hex, Color2 = s.Color2, Effect = s.Effect,
                    Hz = s.Hz, Brightness = s.Brightness,
                    Direction = s.Direction, Easing = s.Easing,
                    Tail = s.Tail, Depth = s.Depth, FullSeconds = s.FullSeconds
                };
            }
            return o;
        }

        public static List<ThemeInfo> List()
        {
            var user = UserNames();
            var o = new List<ThemeInfo>();

            foreach (var kv in BuiltIn())
                o.Add(new ThemeInfo
                {
                    Name = kv.Key,
                    Description = kv.Value.Description,
                    Builtin = true,
                    Shadowed = user.Contains(kv.Key)
                });

            foreach (var n in user)
                o.Add(new ThemeInfo { Name = n, Description = DescribeUser(n), Builtin = false, Shadowed = false });

            return o.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }

        static HashSet<string> UserNames()
        {
            var o = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (!Directory.Exists(UserDir)) return o;
                foreach (var f in Directory.GetFiles(UserDir, "*.json"))
                {
                    var n = Path.GetFileNameWithoutExtension(f);
                    if (IsValidName(n)) o.Add(n);
                }
            }
            catch (Exception ex) { Log.Debug("theme_scan_failed", ex.Message); }
            return o;
        }

        static string DescribeUser(string name)
        {
            Theme t; string err;
            return TryLoad(name, out t, out err) && !string.IsNullOrEmpty(t.Description)
                ? t.Description : "(saved theme)";
        }

        /// <summary>A user theme of the same name wins, which is what makes shadowing
        /// work - and reversible, since the built-in is never overwritten.</summary>
        public static bool TryLoad(string name, out Theme theme, out string error)
        {
            theme = null; error = null;
            if (!IsValidName(name)) { error = "invalid theme name"; return false; }

            var path = Path.Combine(UserDir, name + ".json");
            if (File.Exists(path))
            {
                try
                {
                    var ser = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
                    theme = ser.Deserialize<Theme>(File.ReadAllText(path));
                    if (theme == null) { error = "theme file is empty"; return false; }
                    if (theme.States == null) { error = "theme has no States"; return false; }
                    theme.Name = name;
                    return true;
                }
                catch (Exception ex) { error = ex.Message; return false; }
            }

            Theme builtin;
            if (BuiltIn().TryGetValue(name, out builtin)) { theme = builtin; return true; }

            error = "no such theme";
            return false;
        }

        public static bool TrySave(string name, Dictionary<string, StateStyle> states, out string error)
        {
            error = null;
            if (!IsValidName(name)) { error = "invalid theme name; use letters, digits, dash or underscore"; return false; }
            if (states == null || states.Count == 0) { error = "nothing to save"; return false; }

            try
            {
                Directory.CreateDirectory(UserDir);
                var t = new Theme { Name = name, Description = "Saved theme", States = states };
                var json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.Serialize(t);
                var path = Path.Combine(UserDir, name + ".json");
                var tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
```

- [ ] **Step 2: Add `--list-themes` to the harness**

In `FrameDump.Run`, beside the other dispatches:

```csharp
            if (HasFlag(args, "--list-themes")) return ListThemes();
```

and:

```csharp
        static int ListThemes()
        {
            var w = Console.Out;
            w.WriteLine("name,builtin,states,description");
            foreach (var info in Themes.List())
            {
                Theme t; string err;
                var count = Themes.TryLoad(info.Name, out t, out err) && t.States != null ? t.States.Count : 0;
                w.WriteLine(string.Join(",", new[]
                {
                    info.Name, info.Builtin ? "yes" : "no",
                    count.ToString(CultureInfo.InvariantCulture),
                    (info.Description ?? "").Replace(",", " ")
                }));
            }
            w.Flush();
            return 0;
        }
```

- [ ] **Step 3: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 4: Add the theme tests**

Append inside the same `else` branch of `scripts/Test-Repo.ps1`:

```powershell
    # ---- themes ------------------------------------------------------------
    # A theme is a complete palette: applying one must not leave residue from the
    # last, so every built-in has to name every state.
    $themeRows = @(Invoke-Dump @('--list-themes') | Where-Object { $_ -and $_ -notlike 'name,*' })
    $stateCount = (@(Invoke-Dump @('--resolve-states')) | Where-Object { $_ -and $_ -notlike 'state,*' }).Count

    $builtins = @($themeRows | Where-Object { $_.Split(',')[1] -eq 'yes' })
    if ($builtins.Count -ge 4) { Ok "built-in themes present ($($builtins.Count))" }
    else { No 'expected at least four built-in themes' ($builtins -join '; ') }

    $incomplete = @($builtins | Where-Object { [int]$_.Split(',')[2] -ne $stateCount })
    if ($incomplete.Count -eq 0) { Ok "every built-in theme covers all $stateCount states" }
    else { No 'a built-in theme is missing states' ($incomplete -join '; ') }

    # The engine falls back silently on an unknown effect, so a typo in a shipped
    # theme would render as solid with only a log line to show for it.
    $themeEffectsBad = @()
    foreach ($t in @('default','muted','vivid','mono')) {
        $rows = @(Invoke-Dump @('--resolve-states', '--theme', $t) | Where-Object { $_ -and $_ -notlike 'state,*' })
        foreach ($r in $rows) {
            $e = $r.Split(',')[1]
            if ($known -notcontains $e) { $themeEffectsBad += "$t/$($r.Split(',')[0])=$e" }
        }
    }
    if ($themeEffectsBad.Count -eq 0) { Ok 'every built-in theme names only known effects' }
    else { No 'a built-in theme names an unknown effect' ($themeEffectsBad -join ', ') }

    # Name validation is a path guard, not cosmetics.
    $badNames = @(Invoke-Dump @('--check-theme-name', '../evil'))
    if ($badNames -join '' -match 'invalid') { Ok 'theme names reject path traversal' }
    else { No 'theme name validation accepted ../evil' ($badNames -join ' ') }
```

This needs two more harness flags. Add them alongside the others in `FrameDump.Run`:

```csharp
            if (HasFlag(args, "--check-theme-name"))
            {
                var n = Arg(args, "--check-theme-name", null);
                Console.Out.WriteLine(Themes.IsValidName(n) ? "valid" : "invalid");
                Console.Out.Flush();
                return 0;
            }
```

and in `ResolveStates`, accept a `--theme` that pre-fills the store, so a theme's
resolved output is testable:

```csharp
            var themeName = Arg(args, "--theme", null);
            if (!string.IsNullOrEmpty(themeName))
            {
                Theme t; string terr;
                if (!Themes.TryLoad(themeName, out t, out terr))
                {
                    Console.Error.WriteLine("bad --theme: " + terr);
                    return 2;
                }
                foreach (var kv in t.States) store.Set(kv.Key, kv.Value);
            }
```

Place that block immediately after the `--pending` handling, so an explicit
`--pending` can still override a theme.

- [ ] **Step 5: Run the tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 102 passed, 0 failed ===` (98 + 4 new).

- [ ] **Step 6: Commit**

```bash
git add src/GoveeLights.Daemon/Themes.cs src/GoveeLights.Daemon/FrameDump.cs scripts/Test-Repo.ps1
git commit -m "Add built-in and user themes"
```

---

### Task 4: Style endpoints

**Files:**
- Create: `src/GoveeLights.Daemon/StyleRoutes.cs`
- Modify: `src/GoveeLights.Daemon/Program.cs`

**Interfaces:**
- Consumes: `StyleStore`, `ConfigWriter.TrySave`, `Palette.ResolveFor`, `Palette.EffectNames/DirectionNames/EasingNames`, `DaemonConfig`.
- Produces:
  - `StyleRoutes.Init(Func<DaemonConfig> cfg, StyleStore styles, string configPath, Action onSaved)`
  - `StyleRoutes.Get(HttpRequest) / Set(HttpRequest) / Reset(HttpRequest) / Save(HttpRequest) / Revert(HttpRequest) -> HttpResponse`
  - `Program.SuppressWatch(int ms)` — mutes the config watcher during a self-write

- [ ] **Step 1: Create `StyleRoutes.cs`**

```csharp
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>The control plane's HTTP surface. Kept out of Program.cs, which is already
    /// the largest file in the daemon.</summary>
    public static class StyleRoutes
    {
        static Func<DaemonConfig> _cfg;
        static StyleStore _styles;
        static string _configPath;
        static Action _onSaved;
        static readonly JavaScriptSerializer _json = new JavaScriptSerializer();

        public static void Init(Func<DaemonConfig> cfg, StyleStore styles, string configPath, Action onSaved)
        {
            _cfg = cfg; _styles = styles; _configPath = configPath; _onSaved = onSaved;
        }

        public static HttpResponse Get(HttpRequest req)
        {
            var cfg = _cfg();
            var only = req.Query.ContainsKey("state") ? req.Query["state"] : null;

            var rows = new List<object>();
            foreach (var name in Enum.GetNames(typeof(Activity)))
            {
                if (only != null && !string.Equals(only, name, StringComparison.OrdinalIgnoreCase)) continue;

                Activity a;
                if (!Enum.TryParse(name, true, out a)) continue;
                var r = Palette.ResolveFor(cfg, _styles, null, a, 10);

                rows.Add(new Dictionary<string, object>
                {
                    { "state", name },
                    { "effect", r.Effect },
                    { "color", r.Color.ToHex() },
                    { "color2", r.HasColor2 ? r.Color2.ToHex() : null },
                    { "hz", r.Hz }, { "brightness", r.Brightness },
                    { "direction", r.Direction }, { "easing", r.Easing },
                    { "tail", r.Tail }, { "depth", r.Depth }, { "fullSeconds", r.FullSeconds },
                    { "source", SourceOf(cfg, name) }
                });
            }

            if (only != null && rows.Count == 0) return HttpResponse.Text(400, "unknown state: " + only);

            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "dirty", _styles.Dirty }, { "states", rows }
            }));
        }

        /// <summary>The strongest layer that contributed anything, which is what a user
        /// means by "where did this come from".
        ///
        /// A per-device override is called out separately rather than folded in: this row
        /// resolves with device null, so the values shown are the global ones, and a
        /// device overriding this state means what you see is not what that strip shows.
        /// Saying so is the whole point of the column.</summary>
        static string SourceOf(DaemonConfig cfg, string state)
        {
            var overridden = cfg != null && cfg.Devices != null && cfg.Devices.Any(d =>
                d != null && d.States != null && d.States.ContainsKey(state));
            var note = overridden ? " + device" : "";

            StateStyle pend;
            if (_styles.TryPending(state, out pend))
                return (pend == null ? "reset (unsaved)" : "override (unsaved)") + note;
            if (cfg != null && cfg.States != null && cfg.States.ContainsKey(state)) return "config" + note;
            return "built-in" + note;
        }

        public static HttpResponse Set(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            string state;
            if (!TryState(body, out state)) return HttpResponse.Text(400, "unknown or missing state");

            object rawPatch;
            if (!body.TryGetValue("patch", out rawPatch) || rawPatch == null)
                return HttpResponse.Text(400, "no patch");

            StateStyle patch;
            try { patch = _json.ConvertToType<StateStyle>(rawPatch); }
            catch (Exception ex) { return HttpResponse.Text(400, "bad patch: " + ex.Message); }

            string err;
            if (!Validate(patch, out err)) return HttpResponse.Text(400, err);

            _styles.Set(state, patch);
            Log.Info("style_set", state);
            return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
        }

        /// <summary>Interactive input fails loudly. The resolver deliberately falls back on
        /// an unknown value and logs - correct for a file read 25 times a second, wrong for
        /// a command someone just typed.</summary>
        static bool Validate(StateStyle p, out string error)
        {
            error = null;
            if (!OneOf(p.Effect, Palette.EffectNames(), "effect", out error)) return false;
            if (!OneOf(p.Direction, Palette.DirectionNames(), "direction", out error)) return false;
            if (!OneOf(p.Easing, Palette.EasingNames(), "easing", out error)) return false;

            if (!HexOk(p.Color, out error)) return false;
            if (p.Color2 != null && !string.Equals(p.Color2, "none", StringComparison.OrdinalIgnoreCase)
                && !HexOk(p.Color2, out error)) return false;

            if (p.Hz.HasValue && p.Hz.Value <= 0) { error = "hz must be greater than 0"; return false; }
            if (p.Tail.HasValue && p.Tail.Value <= 0) { error = "tail must be greater than 0"; return false; }
            if (p.FullSeconds.HasValue && p.FullSeconds.Value <= 0) { error = "fullSeconds must be greater than 0"; return false; }
            if (p.Depth.HasValue && (p.Depth.Value < 0 || p.Depth.Value > 1)) { error = "depth must be between 0 and 1"; return false; }
            if (p.Brightness.HasValue && (p.Brightness.Value < -1 || p.Brightness.Value > 100))
            { error = "brightness must be -1, or between 0 and 100"; return false; }

            return true;
        }

        static bool OneOf(string value, string[] known, string label, out string error)
        {
            error = null;
            if (value == null) return true;
            if (known.Any(k => string.Equals(k, value, StringComparison.OrdinalIgnoreCase))) return true;
            error = "unknown " + label + " '" + value + "'; valid: " + string.Join(", ", known);
            return false;
        }

        static bool HexOk(string value, out string error)
        {
            error = null;
            if (value == null) return true;
            var t = value.Trim().TrimStart('#');
            int _;
            if (t.Length == 6 && int.TryParse(t, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _)) return true;
            error = "colour must be six hex digits, e.g. #FF7A18 (got '" + value + "')";
            return false;
        }

        public static HttpResponse Reset(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object all;
            if (body.TryGetValue("all", out all) && all is bool && (bool)all)
            {
                _styles.ResetAll();
                Log.Info("style_reset", "all");
                return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
            }

            string state;
            if (!TryState(body, out state)) return HttpResponse.Text(400, "unknown or missing state");
            _styles.Reset(state);
            Log.Info("style_reset", state);
            return HttpResponse.Json("{\"ok\":true,\"dirty\":true}");
        }

        public static HttpResponse Revert(HttpRequest req)
        {
            _styles.Revert();
            Log.Info("style_revert", "pending cleared");
            return HttpResponse.Json("{\"ok\":true,\"dirty\":false}");
        }

        public static HttpResponse Save(HttpRequest req)
        {
            if (!_styles.Dirty) return HttpResponse.Json("{\"ok\":true,\"saved\":false,\"reason\":\"nothing to save\"}");

            var merged = _styles.Merged(_cfg());

            // Mute the watcher first: the write we are about to do would otherwise be read
            // back as a foreign edit, rebuilding the config while pending is still live.
            if (_onSaved != null) _onSaved();

            string err;
            if (!ConfigWriter.TrySave(_configPath, merged, out err))
            {
                Log.Warn("style_save_failed", err);
                return HttpResponse.Text(500, "save failed: " + err);
            }

            _styles.Revert();
            Log.Info("style_saved", _configPath);
            return HttpResponse.Json("{\"ok\":true,\"saved\":true}");
        }

        static bool TryBody(HttpRequest req, out Dictionary<string, object> body)
        {
            body = null;
            if (string.IsNullOrEmpty(req.Body)) { body = new Dictionary<string, object>(); return true; }
            try { body = _json.Deserialize<Dictionary<string, object>>(req.Body); }
            catch { return false; }
            return body != null;
        }

        static bool TryState(Dictionary<string, object> body, out string state)
        {
            state = null;
            object raw;
            if (!body.TryGetValue("state", out raw) || raw == null) return false;
            Activity a;
            if (!Enum.TryParse(raw.ToString(), true, out a)) return false;
            state = a.ToString();     // canonical casing, so the pending map keys match
            return true;
        }
    }
}
```

- [ ] **Step 2: Wire the routes and the watcher suppression**

In `src/GoveeLights.Daemon/Program.cs`, add the suppression field and helper beside the other statics:

```csharp
        static DateTime _suppressWatchUntil = DateTime.MinValue;

        /// <summary>Mute the config watcher briefly. A save writes the file the watcher is
        /// watching; without this the daemon reloads its own write, and a reload while
        /// pending edits are live would rebuild the config underneath them.</summary>
        public static void SuppressWatch(int ms)
        {
            _suppressWatchUntil = DateTime.UtcNow.AddMilliseconds(ms);
        }
```

Inside `WatchConfig`'s `Changed` handler, as the first line of the lambda:

```csharp
                    if (DateTime.UtcNow < _suppressWatchUntil) return;
```

and after the successful reload, warn when a hand edit arrives over live pending edits:

```csharp
                    if (_styles.Dirty)
                        Log.Warn("config_reloaded_with_pending",
                            "config changed on disk while unsaved style edits are live; keeping the edits");
```

Register the routes after the config path is known, before `_http.Start`:

```csharp
            StyleRoutes.Init(Cfg, _styles, configPath, () => SuppressWatch(3000));
```

and add the cases to `Handle`:

```csharp
                case "/styles": return StyleRoutes.Get(req);
                case "/styles/set": return StyleRoutes.Set(req);
                case "/styles/reset": return StyleRoutes.Reset(req);
                case "/styles/save": return StyleRoutes.Save(req);
                case "/styles/revert": return StyleRoutes.Revert(req);
```

- [ ] **Step 3: Build**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
```

Expected: build succeeds.

- [ ] **Step 4: Run the suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 102 passed, 0 failed ===` — unchanged. These routes are not covered by the static suite; the spec says so explicitly, and Task 6 adds the manual verification steps.

- [ ] **Step 5: Commit**

```bash
git add src/GoveeLights.Daemon/StyleRoutes.cs src/GoveeLights.Daemon/Program.cs
git commit -m "Add the style endpoints and mute the watcher during a save"
```

---

### Task 5: Theme and preview endpoints

**Files:**
- Modify: `src/GoveeLights.Daemon/StyleRoutes.cs`
- Modify: `src/GoveeLights.Daemon/Program.cs`

**Interfaces:**
- Consumes: `Themes.List/TryLoad/TrySave`, `StyleStore.SetPreview`, `Renderer.Force`.
- Produces: `StyleRoutes.ThemeList/ThemeApply/ThemeSave/Preview(HttpRequest) -> HttpResponse`; `StyleRoutes.Init` gains a `Action<Activity,int> forceState` parameter.

- [ ] **Step 1: Extend `Init` and add the four handlers**

In `StyleRoutes.cs`, add the field and widen `Init`:

```csharp
        static Action<Activity, int> _force;

        public static void Init(Func<DaemonConfig> cfg, StyleStore styles, string configPath,
                                Action onSaved, Action<Activity, int> forceState)
        {
            _cfg = cfg; _styles = styles; _configPath = configPath;
            _onSaved = onSaved; _force = forceState;
        }
```

then append:

```csharp
        public static HttpResponse ThemeList(HttpRequest req)
        {
            var rows = Themes.List().Select(t => (object)new Dictionary<string, object>
            {
                { "name", t.Name }, { "description", t.Description },
                { "builtin", t.Builtin }, { "shadowed", t.Shadowed }
            }).ToList();
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object> { { "themes", rows } }));
        }

        public static HttpResponse ThemeApply(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object raw;
            if (!body.TryGetValue("name", out raw) || raw == null) return HttpResponse.Text(400, "no theme name");

            Theme t; string err;
            if (!Themes.TryLoad(raw.ToString(), out t, out err)) return HttpResponse.Text(400, err);

            // A theme is a complete palette, so applying one is total - reset first, or
            // states the theme does not mention would keep the previous theme's values.
            _styles.ResetAll();
            foreach (var kv in t.States)
            {
                Activity a;
                if (!Enum.TryParse(kv.Key, true, out a)) continue;
                _styles.Set(a.ToString(), kv.Value);
            }

            Log.Info("theme_applied", t.Name);
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true }, { "theme", t.Name }, { "dirty", true }
            }));
        }

        public static HttpResponse ThemeSave(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            object raw;
            if (!body.TryGetValue("name", out raw) || raw == null) return HttpResponse.Text(400, "no theme name");

            var name = raw.ToString();
            if (!Themes.IsValidName(name))
                return HttpResponse.Text(400, "invalid theme name; use letters, digits, dash or underscore (max 32)");

            // Save what is on the lights now: config plus anything unsaved, so a theme is
            // self-contained rather than a diff against whatever config it was cut from.
            var states = _styles.Merged(_cfg());
            string err;
            if (!Themes.TrySave(name, states, out err)) return HttpResponse.Text(500, "theme save failed: " + err);

            Log.Info("theme_saved", name);
            return HttpResponse.Json("{\"ok\":true}");
        }

        public static HttpResponse Preview(HttpRequest req)
        {
            Dictionary<string, object> body;
            if (!TryBody(req, out body)) return HttpResponse.Text(400, "bad json body");

            var holdMs = 8000;
            object rawHold;
            if (body.TryGetValue("holdMs", out rawHold) && rawHold != null)
            {
                int parsed;
                if (int.TryParse(rawHold.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                    holdMs = Math.Max(500, Math.Min(60000, parsed));
            }

            string state;
            if (!TryState(body, out state)) return HttpResponse.Text(400, "unknown or missing state");

            StateStyle patch = null;
            object rawPatch;
            if (body.TryGetValue("patch", out rawPatch) && rawPatch != null)
            {
                try { patch = _json.ConvertToType<StateStyle>(rawPatch); }
                catch (Exception ex) { return HttpResponse.Text(400, "bad patch: " + ex.Message); }

                string err;
                if (!Validate(patch, out err)) return HttpResponse.Text(400, err);
            }

            Activity a;
            Enum.TryParse(state, true, out a);

            // Preview never touches pending: it is a look, not an edit.
            if (patch != null) _styles.SetPreview(state, patch, holdMs);
            if (_force != null) _force(a, holdMs);

            Log.Info("style_preview", state);
            return HttpResponse.Json(_json.Serialize(new Dictionary<string, object>
            {
                { "ok", true }, { "state", state }, { "holdMs", holdMs }
            }));
        }
```

- [ ] **Step 2: Wire them in `Program.cs`**

Update the `Init` call and add the cases:

```csharp
            StyleRoutes.Init(Cfg, _styles, configPath, () => SuppressWatch(3000),
                             (a, ms) => _renderer.Force(a, ms));
```

```csharp
                case "/themes": return StyleRoutes.ThemeList(req);
                case "/themes/apply": return StyleRoutes.ThemeApply(req);
                case "/themes/save": return StyleRoutes.ThemeSave(req);
                case "/preview": return StyleRoutes.Preview(req);
```

- [ ] **Step 3: Build and run the suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: build succeeds; `=== 102 passed, 0 failed ===`.

- [ ] **Step 4: Commit**

```bash
git add src/GoveeLights.Daemon/StyleRoutes.cs src/GoveeLights.Daemon/Program.cs
git commit -m "Add theme and preview endpoints"
```

---

### Task 6: The CLI

**Files:**
- Modify: `scripts/Govee-Cli.ps1`
- Modify: `commands/govee.md`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: every endpoint from Tasks 4 and 5.
- Produces: the verbs `styles`, `set`, `reset`, `save`, `revert`, `preview`, `theme`.

- [ ] **Step 1: Give the script an argument parser**

Replace the `param` block at the top of `scripts/Govee-Cli.ps1` with:

```powershell
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'status',
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest,
    [int] $Port = 17321
)

$ErrorActionPreference = 'Continue'
$base = "http://127.0.0.1:$Port"

# Style fields, and how each is coerced before it goes on the wire. The daemon
# validates too - this exists so a typo fails here with a readable message instead
# of as a 400 from a route.
$StyleFields = @{
    'color'       = 'string'; 'color2'      = 'string'; 'effect'    = 'string'
    'direction'   = 'string'; 'easing'      = 'string'
    'hz'          = 'double'; 'tail'        = 'double'; 'depth'     = 'double'
    'fullseconds' = 'double'; 'brightness'  = 'int'
}
$StyleFieldJson = @{
    'color' = 'Color'; 'color2' = 'Color2'; 'effect' = 'Effect'
    'direction' = 'Direction'; 'easing' = 'Easing'; 'hz' = 'Hz'
    'tail' = 'Tail'; 'depth' = 'Depth'; 'fullseconds' = 'FullSeconds'
    'brightness' = 'Brightness'
}

function Parse-StyleArgs {
    param([string[]] $Tokens)
    $positional = @()
    $patch = @{}
    $flags = @{}
    $i = 0
    while ($i -lt $Tokens.Count) {
        $t = $Tokens[$i]
        if ($t -like '--*') {
            $name = $t.Substring(2).ToLowerInvariant()
            if ($name -eq 'all') { $flags['all'] = $true; $i++; continue }
            if ($i + 1 -ge $Tokens.Count) { throw "missing value for --$name" }
            $value = $Tokens[$i + 1]
            if ($StyleFields.ContainsKey($name)) {
                switch ($StyleFields[$name]) {
                    'double' {
                        $d = 0.0
                        if (-not [double]::TryParse($value, [ref] $d)) { throw "--$name expects a number, got '$value'" }
                        $patch[$StyleFieldJson[$name]] = $d
                    }
                    'int' {
                        $n = 0
                        if (-not [int]::TryParse($value, [ref] $n)) { throw "--$name expects a whole number, got '$value'" }
                        $patch[$StyleFieldJson[$name]] = $n
                    }
                    default { $patch[$StyleFieldJson[$name]] = $value }
                }
            } else {
                $flags[$name] = $value
            }
            $i += 2
        } else {
            $positional += $t
            $i++
        }
    }
    return @{ Positional = $positional; Patch = $patch; Flags = $flags }
}
```

- [ ] **Step 2: Add the seven verbs**

Insert these cases into the existing `switch ($Command.ToLowerInvariant())` block, before its `default`:

```powershell
    'styles' {
        $parsed = Parse-StyleArgs $Rest
        $state = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0] } else { $null }
        $path = if ($state) { "/styles?state=$state" } else { '/styles' }
        $s = Call $path
        if (-not $s) { Show-Offline; break }

        if ($state) {
            $r = $s.states[0]
            Write-Output "$($r.state)"
            Write-Output "  colour     : $($r.color)$(if ($r.color2) { " -> $($r.color2)" })"
            Write-Output "  effect     : $($r.effect)"
            Write-Output "  rate       : $($r.hz) Hz"
            Write-Output "  brightness : $($r.brightness)"
            Write-Output "  direction  : $($r.direction)   easing: $($r.easing)"
            Write-Output "  tail       : $($r.tail)   depth: $($r.depth)   fullSeconds: $($r.fullSeconds)"
            Write-Output "  source     : $($r.source)"
        } else {
            Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f 'STATE','COLOUR','EFFECT','HZ','BRIGHT','SOURCE')
            foreach ($r in $s.states) {
                Write-Output ("  {0,-13}{1,-10}{2,-10}{3,6}{4,8}   {5}" -f `
                    $r.state, $r.color, $r.effect, $r.hz, $r.brightness, $r.source)
            }
            Write-Output ""
            if ($s.dirty) { Write-Output "Unsaved changes. '/govee save' to keep them, '/govee revert' to discard." }
            else { Write-Output "No unsaved changes." }
        }
    }

    'set' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Positional.Count -lt 1 -or $parsed.Patch.Count -eq 0) {
            Write-Output "Usage: /govee set <state> --color #RRGGBB [--effect chase] [--hz 0.8] ..."
            Write-Output ""
            Write-Output "Fields: color color2 effect hz brightness direction easing tail depth fullseconds"
            break
        }
        $r = Call '/styles/set' 'Post' @{ state = $parsed.Positional[0]; patch = $parsed.Patch }
        if (-not $r) { Show-Offline; break }
        Write-Output "Applied to $($parsed.Positional[0]). Unsaved - '/govee save' to keep it."
    }

    'reset' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Flags.ContainsKey('all')) {
            $r = Call '/styles/reset' 'Post' @{ all = $true }
            if (-not $r) { Show-Offline; break }
            Write-Output "All states reset to built-in defaults. Unsaved - '/govee save' to keep it."
        } elseif ($parsed.Positional.Count -ge 1) {
            $r = Call '/styles/reset' 'Post' @{ state = $parsed.Positional[0] }
            if (-not $r) { Show-Offline; break }
            Write-Output "$($parsed.Positional[0]) reset to its built-in default. Unsaved - '/govee save' to keep it."
        } else {
            Write-Output "Usage: /govee reset <state>   |   /govee reset --all"
        }
    }

    'save' {
        $r = Call '/styles/save' 'Post'
        if (-not $r) { Show-Offline; break }
        if ($r.saved) { Write-Output "Saved to config.json. Comments and other settings were left alone." }
        else { Write-Output "Nothing to save." }
    }

    'revert' {
        $r = Call '/styles/revert' 'Post'
        if (-not $r) { Show-Offline; break }
        Write-Output "Unsaved changes discarded."
    }

    'preview' {
        $parsed = Parse-StyleArgs $Rest
        if ($parsed.Positional.Count -lt 1) {
            Write-Output "Usage: /govee preview <state> [--effect comet] [--tail 2.5] [--seconds 8]"
            break
        }
        $hold = 8000
        if ($parsed.Flags.ContainsKey('seconds')) { $hold = [int]([double]$parsed.Flags['seconds'] * 1000) }
        $r = Call '/preview' 'Post' @{ state = $parsed.Positional[0]; patch = $parsed.Patch; holdMs = $hold }
        if (-not $r) { Show-Offline; break }
        Write-Output "Previewing $($r.state) for $([math]::Round($r.holdMs / 1000))s - watch your lights. Nothing was changed."
    }

    'theme' {
        $parsed = Parse-StyleArgs $Rest
        $sub = if ($parsed.Positional.Count -gt 0) { $parsed.Positional[0].ToLowerInvariant() } else { 'list' }
        $name = if ($parsed.Positional.Count -gt 1) { $parsed.Positional[1] } else { $null }

        switch ($sub) {
            'list' {
                $t = Call '/themes'
                if (-not $t) { Show-Offline; break }
                Write-Output ("  {0,-14}{1,-10}{2}" -f 'NAME','KIND','DESCRIPTION')
                foreach ($x in $t.themes) {
                    $kind = if ($x.builtin) { if ($x.shadowed) { 'built-in*' } else { 'built-in' } } else { 'saved' }
                    Write-Output ("  {0,-14}{1,-10}{2}" -f $x.name, $kind, $x.description)
                }
                if ($t.themes | Where-Object { $_.shadowed }) {
                    Write-Output ""
                    Write-Output "* shadowed by a saved theme of the same name."
                }
            }
            'apply' {
                if (-not $name) { Write-Output "Usage: /govee theme apply <name>"; break }
                $r = Call '/themes/apply' 'Post' @{ name = $name }
                if (-not $r) { Show-Offline; break }
                Write-Output "Applied theme '$($r.theme)'. Unsaved - '/govee save' to keep it."
            }
            'save' {
                if (-not $name) { Write-Output "Usage: /govee theme save <name>"; break }
                $r = Call '/themes/save' 'Post' @{ name = $name }
                if (-not $r) { Show-Offline; break }
                Write-Output "Saved current styles as theme '$name'."
            }
            default { Write-Output "Usage: /govee theme list | apply <name> | save <name>" }
        }
    }
```

- [ ] **Step 3: Extend the usage text**

In the existing `default` case, add the new verbs beneath the current list:

```powershell
        Write-Output "  styles    show every state's colour and effect"
        Write-Output "  set       change a state, e.g. set Thinking --color #FF0000 --hz 2"
        Write-Output "  preview   try a style for a few seconds without changing anything"
        Write-Output "  reset     put a state (or --all) back to its built-in default"
        Write-Output "  save      write pending changes to config.json"
        Write-Output "  revert    discard pending changes"
        Write-Output "  theme     list | apply <name> | save <name>"
```

- [ ] **Step 4: Update the slash command's argument hint**

In `commands/govee.md`, replace the `argument-hint` frontmatter line with:

```yaml
argument-hint: "status | styles [state] | set <state> --color ... | preview <state> | reset <state>|--all | save | revert | theme list|apply|save | devices | test <state> | on | off | refresh | restart | logs | doctor"
```

- [ ] **Step 5: Verify the script still parses**

`Test-Repo.ps1` already parses every script in `scripts/`, so this is covered — but check it directly first, since a parse error here breaks the whole suite:

```powershell
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path scripts\Govee-Cli.ps1), [ref]$null, [ref]$e)
if ($e) { $e[0].Message } else { 'parses' }
```

Expected: `parses`.

- [ ] **Step 6: Run the suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 102 passed, 0 failed ===`, including `Govee-Cli.ps1 parses` and the existing check that `commands/govee.md` references an existing script.

- [ ] **Step 7: Manual verification against a running daemon**

The static suite cannot exercise the routes — the daemon needs an `ApiGuid` and Govee Desktop. Run these by hand and record the output in your report. **If no Govee hardware is available, say so and skip; do not fabricate results.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1 -Restart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 styles
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 set Thinking --color #FF0000 --hz 2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 styles Thinking
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 revert
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 theme list
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 theme apply muted
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Govee-Cli.ps1 save
```

Expected: `set` reports unsaved; `styles Thinking` shows `#FF0000` with source `override (unsaved)`; `revert` clears it; `save` reports success. **Then confirm the file was spliced, not rewritten** — this is the whole point of Task 2:

```powershell
Get-Content "$env:LOCALAPPDATA\ClaudeGovee\config.json" | Select-String '_comment'
```

Expected: any `_comment` keys that were in the file before are still there.

- [ ] **Step 8: Commit**

```bash
git add scripts/Govee-Cli.ps1 commands/govee.md
git commit -m "Add the control-plane verbs to the CLI"
```

---

### Task 7: Documentation and version bump

**Files:**
- Modify: `README.md`
- Modify: `docs/EFFECTS.md`
- Modify: `src/GoveeLights.Daemon/GoveeLights.Daemon.csproj`
- Test: `scripts/Test-Repo.ps1`

**Interfaces:**
- Consumes: nothing. Produces: nothing consumed by code.

- [ ] **Step 1: Lead the README section with the command loop**

`README.md` has a `## Customising the lights` section that currently opens by telling the reader to edit JSON. Replace its opening — down to but not including the "Ten effects are available" paragraph — with:

```markdown
## Customising the lights

Each activity state has its own colour and animation. Change one from the prompt:

```
/govee styles                                    show everything, and where each value came from
/govee set Thinking --color #FF0000 --hz 2       apply it live
/govee save                                      keep it
```

`set` takes effect immediately but writes nothing — experiment freely and
`/govee revert` if you don't like it. `save` splices only the `States` block back
into `%LOCALAPPDATA%\ClaudeGovee\config.json`, so your comments and every other
setting survive untouched.

`/govee preview Thinking --effect comet --tail 2.5` shows a style for a few
seconds without changing anything at all, and `/govee reset Thinking` puts a
state back to its built-in default.

Whole palettes come as themes — `/govee theme list`, `/govee theme apply muted`,
and `/govee theme save <name>` to keep your current setup as one.

The config file is still there and still hot-reloads, if you prefer editing it:
```

Leave the existing JSON example and the "Ten effects are available" paragraph in
place beneath that line, so the file-editing route stays documented.

- [ ] **Step 2: Document the pending layer in the inheritance chain**

`docs/EFFECTS.md` lists the inheritance chain, strongest first. It is now wrong — there are five layers, not four. Replace the chain with:

```markdown
Any field may be omitted. Omitted means *inherit*, and the layers are, strongest
first:

1. a device's own `States` entry
2. **unsaved edits** from `/govee set` or `/govee theme apply` — these sit exactly
   where the global `States` block sits, which is why `/govee save` can write them
   straight into it
3. the global `States` entry in `config.json`
4. the built-in default for that state
5. the effect's own default

`/govee styles` names the layer each value came from, and marks unsaved edits.
Preview (`/govee preview`) is stronger than all of them and expires on its own —
it is a look, not an edit.
```

- [ ] **Step 3: Bump the version**

In `src/GoveeLights.Daemon/GoveeLights.Daemon.csproj`, change:

```xml
    <Version>0.2.0</Version>
```

to:

```xml
    <Version>0.3.0</Version>
```

- [ ] **Step 4: Add a docs-accuracy check**

The docs now name specific verbs. Append inside the `Effects engine` section's `else` branch in `scripts/Test-Repo.ps1`:

```powershell
    # Documented verbs must exist in the CLI, or the README teaches commands that fail.
    $cliText = Get-Content (Join-Path $root 'scripts/Govee-Cli.ps1') -Raw
    $missingVerbs = @()
    foreach ($v in 'styles','set','reset','save','revert','preview','theme') {
        if ($cliText -notmatch "(?m)^\s*'$v'\s*\{") { $missingVerbs += $v }
    }
    if ($missingVerbs.Count -eq 0) { Ok 'every documented verb exists in the CLI' }
    else { No 'a documented verb is missing from the CLI' ($missingVerbs -join ', ') }
```

- [ ] **Step 5: Run the suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Repo.ps1
```

Expected: `=== 103 passed, 0 failed ===`.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/EFFECTS.md src/GoveeLights.Daemon/GoveeLights.Daemon.csproj scripts/Test-Repo.ps1
git commit -m "Document the control plane and bump to 0.3.0"
```

---

## Notes for the implementer

**The splicer is the risky code here.** It edits the user's config file in place.
`TrySave` validates by round-trip and writes atomically, and Task 2's five
fixtures are each a way a naive implementation corrupts something. If a fixture
fails, fix the splicer — do not relax the fixture.

**Preview must never dirty pending.** `/govee preview` is explicitly a look. If
`_styles.Dirty` becomes true after a preview, that is a bug: the expiring preview
slot is separate from the pending map for exactly this reason.

**The watcher and the writer share a file.** `save` mutes the watcher before
writing. If you find yourself adding a second suppression path, stop — one
window, opened by the save handler, is the design.

**Endpoint and CLI coverage is manual, by design.** The daemon exits without an
`ApiGuid`, so CI cannot stand one up, and inventing a no-hardware mode to test
thin route handlers is not worth it. Task 6 Step 7 is the verification; report
honestly if you cannot run it.
