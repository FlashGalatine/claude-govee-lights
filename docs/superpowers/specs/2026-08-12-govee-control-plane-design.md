# Govee control plane — design

Date: 2026-08-12
Status: approved, ready for planning

## Problem

The style engine landed in `0.2.0`: ten effects, five modifiers, a four-layer
merge where null means inherit, per-device overrides, and frame-level
cross-fades. All of it is configured exactly one way — by hand-editing
`%LOCALAPPDATA%\ClaudeGovee\config.json`.

That leaves three of the four original complaints open:

1. **Editing is a chore.** Every experiment means finding the file, editing
   JSON, and saving. There is no way to try a colour from the prompt.
2. **There are no themes.** Changing the overall look means tuning fourteen
   states one at a time.
3. **It is still not discoverable.** `docs/EFFECTS.md` explains the vocabulary,
   but nothing answers "what am I running right now, and where did it come
   from" without opening a file.

This spec covers the control plane over the existing engine. It adds no
effects and no modifiers.

## Approach

`/govee set` does not write to disk. It applies a **live override** that the
lights show immediately, and `/govee save` commits it. Experimenting is free
and undoable; the config file is rewritten only when asked.

Those overrides live in a new **pending layer**, slotted into the merge exactly
where the config layer sits:

```
effect defaults          (weakest)
built-in state defaults
cfg.States               on disk        <- skipped when the state is cleared
pending                  NEW - unsaved edits
device.States
preview                  NEW - transient, expires on its own (strongest)
```

The position is the whole point: the pending layer is a shadow of `cfg.States`,
so "set edits the States block, save writes it" is not an analogy — it is
literally what the writer does. Keeping the layers as separate objects is also
what lets `/govee styles` attribute each value to its source.

Two alternatives were rejected. **Mutating `_cfg` in place** needs locking
against a render thread that reads it 25 times a second, and destroys the
provenance `/govee styles` exists to show. **Making everything a theme**
conflates a one-field tweak with a fourteen-state palette.

## The pending layer

A new `StyleStore` owns everything mutable about styles, so the control plane
locks in one place instead of reaching into `Program._cfg`:

```csharp
public sealed class StyleStore
{
    Dictionary<string, StateStyle> _pending;   // keyed by Activity name
    public bool Dirty { get; }
    public StateStyle Pending(string state);            // null if untouched
    public void Set(string state, StateStyle patch);    // field-wise; null means "leave"
    public void ApplyTheme(Theme t);                    // fills _pending for every state
    public void Reset(string state);                    // clear one state
    public void ResetAll();                             // clear every state
    public void Revert();                               // discard all unsaved edits
    public bool IsCleared(string state);
    public Dictionary<string, StateStyle> Merged(DaemonConfig cfg);  // what save writes
}
```

`Palette.ResolveFor` gains one array element between `cfg.States` and
`device.States`. `Pick`/`PickN` already walk the layers weakest-first, so this
is not new machinery.

**`reset` needs its own structure.** "Clear this state back to built-in" cannot
be expressed as an all-null `StateStyle` — that means inherit, which is a no-op.
Nor can it live in the same slot as a patch: a state can be **both cleared and
patched**, which is what `/govee reset X` followed by `/govee set X --hz 2`
means, and a single three-valued slot silently resurrects the cleared config
values. So the store holds two structures under one lock — `_pending` for
patches and `_cleared` for cleared states — and they are independent. `Reset`
adds to `_cleared` and leaves any patch alone; `Set` leaves `_cleared` alone.
`BuildLayers` skips the `cfg.States` layer for a cleared state; `Merged()`
starts a cleared state from a null basis rather than its config entry, and omits
it entirely when it has no patch.

## Interaction with the hot-reload watcher

`save` opens a suppression window before writing so the `FileSystemWatcher`
reload it triggers is ignored. Without it the daemon reloads a file it just
wrote, and — worse — a reload rebuilds `_cfg` while `_pending` still holds
unsaved edits for other states.

A *genuine* hand edit arriving while `_pending` is dirty is a real conflict.
The daemon keeps `_pending` (it is the newer intent) and logs
`config_reloaded_with_pending` naming the states that now differ from disk.
It does not silently pick a winner.

## The write path

A new `ConfigWriter` with one entry point:

```csharp
static bool TrySpliceStates(string json, string statesBlock, out string result, out string error);
```

It scans the file text tracking string state and brace depth, finds the
`"States"` key **at depth 1**, and replaces its object span. Depth matters:
`Devices[].States` exists, and `_examples_states` sits alongside — a substring
search would hit the wrong one. With no top-level `States` key it inserts one
before the closing brace. Everything outside the span survives byte-for-byte:
comments, key order, whitespace, `_examples_states`.

This is a hand-rolled splicer writing the user's file, so it carries three
safeguards:

- **Round-trip validation before the write lands.** Deserialize the spliced
  result and confirm the `States` block matches what was intended. If it does
  not parse, or does not match, abort and write nothing; `/govee save` reports
  the failure and `_pending` stays intact. A splicer that silently corrupts a
  config is worse than one that refuses.
- **Atomic replace.** Write a temp file in the same directory, then
  `File.Replace`, so a crash or a full disk cannot truncate `config.json`.
- **The file's own indentation.** Render at the 2-space convention `Prettify`
  already uses, indented to the depth the key was found at, so saving does not
  reformat the surrounding file.

## Command surface

HTTP routes follow the existing flat-path convention (`/enable`, `/refresh`):

| Route | Body | Purpose |
|---|---|---|
| `GET /styles` | — | every state's resolved style, source, and the dirty flag |
| `POST /styles/set` | `{state, patch}` | field-wise patch into `_pending` |
| `POST /styles/reset` | `{state}` or `{all:true}` | clear back to built-in |
| `POST /styles/save` | — | splice and write |
| `POST /styles/revert` | — | discard all unsaved edits |
| `GET /themes` | — | built-in and user themes |
| `POST /themes/apply` | `{name}` | fill `_pending` from a theme |
| `POST /themes/save` | `{name}` | write a user theme file |
| `POST /preview` | `{state?, patch, holdMs}` | render an ad-hoc style; no state change |

`GET /styles` reports a `source` per state, one of `built-in`, `config`,
`override` or `device`, plus the field-level detail the single-state view
renders. `POST /preview` resolves `state` (defaulting to the current one) and
applies `patch` on top, so the CLI's `preview <state> [style flags]` is one
call: it previews a real state with ad-hoc modifications, rather than requiring
every field to be restated.

CLI verbs:

```
/govee styles [state]
/govee set <state> [--color #RRGGBB] [--color2 #RRGGBB|none] [--effect <name>]
                   [--hz <n>] [--brightness <n>] [--direction <d>] [--easing <e>]
                   [--tail <n>] [--depth <n>] [--fullseconds <n>]
/govee reset <state> | /govee reset --all
/govee save
/govee revert
/govee preview <state> [style flags] [--seconds <n>]
/govee theme list | /govee theme apply <name> | /govee theme save <name>
```

`/govee styles` reads at two levels — a table for everything, detail for one
state:

```
STATE         COLOUR    EFFECT    HZ    BRIGHT  SOURCE
Thinking      #7B4DFF   breathe   0.6   55      built-in
ToolShell     #FF0000   chase     0.8   60      config, override*
                                                 * unsaved
```

`/govee styles ToolShell` breaks down field by field, naming the layer each
value came from. That is the discoverability answer, and the pending layer is
what makes it possible.

**Interactive input validates loudly.** The resolver deliberately falls back on
an unknown `Effect` and logs a warning — right for a config file read at 25fps,
wrong for a command someone just typed. `/govee set Thinking --effect chaise`
fails with the valid list rather than silently rendering solid.

This requires exporting the known-value lists, which closes a standing
follow-up: the effect list is currently duplicated across `Palette` (private),
`Test-Repo.ps1` (hardcoded `$known`), and `docs/EFFECTS.md`. `Palette` exposes
the lists, and a new `--list-known` flag lets the test derive its list instead
of restating it.

**Scope boundary:** `/govee set` operates on global states only. Per-device
overrides stay hand-edited. The engine supports them and `/govee styles` shows
when one is in play, but adding `--device` to every verb doubles the surface
for something that is set-up-once configuration, not interactive tuning.

`scripts/Govee-Cli.ps1` currently accepts two positional parameters and nothing
else. Flag parsing across ten style fields means giving it a real argument
parser — a genuine part of this work, not a footnote.

## Themes

**Built-in themes live in code**, as `Themes.BuiltIn()`. The daemon gets no
plugin root — `Ensure-Daemon.ps1` launches the executable with no arguments and
`dist/daemon` holds only the exe — so plugin-relative theme files are not
reliably findable. `Palette.Defaults()` already sets the precedent for built-in
data living in code.

```csharp
public sealed class Theme
{
    public string Name;
    public string Description;                        // shown by `theme list`
    public Dictionary<string, StateStyle> States;     // every Activity name
}
```

The roster is `default` (the built-in palette), `muted` (dim and slow, for a
shared room), `vivid`, and `mono` (one hue, distinction carried by effect rather
than colour). A theme names a style for every state, so applying one is total —
no residue from the last theme.

`theme apply default` and `reset --all` render identically but do not save
identically, and the difference is worth knowing: `reset --all` tombstones every
state, so `save` writes a config whose `States` block is empty and which
therefore tracks any future change to the built-in defaults. `theme apply
default` writes an explicit fourteen-state block that pins today's values. Use
`reset --all` to go back to stock; use the theme to freeze a copy.

**User themes** are one file per theme at
`%LOCALAPPDATA%\ClaudeGovee\themes\<name>.json`. `/govee theme save <name>`
writes the merged config+pending states, so a theme is self-contained. A user
theme shadows a built-in of the same name, and `theme list` marks which is
which.

Theme names validate against `[A-Za-z0-9_-]{1,32}`. This is user input becoming
a filesystem path, so invalid names are rejected rather than sanitised.

Saving under a built-in name is allowed and shadows it — `theme list` marks the
built-in as shadowed, and deleting the file in
`%LOCALAPPDATA%\ClaudeGovee\themes\` restores it. Built-ins live in code and are
never written to, so shadowing is always reversible.

Applying a theme fills `_pending` and therefore requires `save` to persist,
exactly like `set`.

## Testing

The engine's testable seam was `--dump-frames`; the control plane gets two more
in the same style. Both are deterministic functions of their inputs and touch no
hardware:

- `--splice-states --config <path> --states <json>` — prints the spliced result
- `--resolve-states --config <path> [--pending <json>]` — prints resolved styles
  with per-field provenance. `--pending` takes a JSON object mapping state name
  to a partial `StateStyle`, where a literal `null` value is a tombstone — the
  same shape `StyleStore` holds in memory.

The splicer fixtures carry the weight, since it is the piece that writes the
user's file. `Test-Repo.ps1` asserts against a config with comments, one with
`_examples_states`, one with `Devices[].States`, one with no `States` key, and
one where a string *value* contains the text `"States":`. Each asserts the
intended block changed and everything else survived byte-for-byte.

`--resolve-states` covers the pending layer's position in the merge: that
pending beats `cfg.States`, that `device.States` still beats pending, and that a
tombstone drops the config layer back to the built-in default.

Plus a check that every built-in theme covers all fourteen states and names only
known effects — the same shape as the existing example-config check.

**Not covered, stated plainly:** the HTTP routes and the CLI parser. The daemon
exits early without an `ApiGuid`, so standing one up in CI is not possible
without inventing a no-hardware mode, and doing that to test nine thin route
handlers is not worth it. Those get manual verification via `/govee doctor` and
hand testing.

## Documentation

- `README.md` — the `## Customising the lights` section gains the command loop
  (`set` → look → `save`), so the first thing a reader learns is that they do
  not have to edit JSON.
- `docs/EFFECTS.md` — a section on the pending layer and where it sits, since
  the inheritance chain is documented there and would otherwise be wrong.
- `commands/govee.md` — the `argument-hint` frontmatter lists the new verbs.

## Out of scope

No new effects or modifiers. No `--device` on the interactive verbs. No remote
or non-loopback access — the HTTP server stays bound to `IPAddress.Loopback`,
which is the existing security boundary. No config edits beyond the `States`
block: `Render`, `Devices`, `QuietHours` and the rest stay hand-edited.
