# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the
`version` in `.claude-plugin/plugin.json`.

## [Unreleased]

### Added
- The daemon heals a rejected API GUID by itself. When Govee Desktop rejects the GUID in
  use (a fast `1001`), the daemon tries every other GUID it knows on that same attempt:
  `config.json`'s first, then each `Govee-API-GUID.txt` seed (beside `config.json`, then
  up from the exe), then `known-guids.txt`, the last five GUIDs Desktop accepted. If one
  connects, `/health` and `/status` report `usingFallbackGuid`, and `/govee doctor` says
  `config.json`'s GUID is wrong. Nothing is sticky: every connection attempt re-checks
  the whole list, so at the next reconnect or restart the daemon goes back to
  `config.json`'s GUID (`govee_guid_config_restored`) if Govee Desktop accepts it again.
  `config.json`'s GUID is read live, so a GUID pasted into it by hand connects without a
  restart, and fixing it clears `usingFallbackGuid` at once. The history is what heals
  a GUID that flips and flips back, even after `/govee guid` has overwritten config and
  seed with the short-lived value. The slow (~6 s) `1001`, which is the missing
  bindingRedirect, never triggers a swap. Log lines name the fix that matches the
  timing: the bindingRedirect for a slow `1001`, and for code `100`, elevation only when
  it is fast; a slow `100` is Desktop still starting. CI checks those rules, and that
  `config.json`'s GUID is tried first, through a new headless `--dump-guid-gate` mode.
- `/govee guid` also writes the seed beside `config.json`, so a config that is later
  overwritten with a bad GUID heals on its own.
- `/status` counts consecutive connection failures (`govee.initFailures`).
- `scripts/Test-GuidSelfHeal.ps1`: a hardware-gated integration test that runs an
  isolated daemon against the real Govee Desktop. It skips cleanly when no Govee Desktop
  is present.

### Changed
- The marketplace is named `claude-govee-lights` rather than
  `claude-govee-lights-local`, so the install command is
  `/plugin install claude-govee-lights@claude-govee-lights`. Anyone who added the
  old name must remove it and add the marketplace again.
- Every release is tagged (`v0.1.0` … `v0.4.0`) and the changelog links compare
  between tags.
- A `config.json` whose `ApiGuid` is empty now starts from the seed when one exists,
  instead of refusing. With no seed the daemon still exits with code 2.

### Fixed
- A rejected GUID no longer fails quietly. Every retry used to log a WARN (about once a
  minute), which buried the one line that mattered, and a real outage went unnoticed for
  about two weeks. The first failure is now an ERROR that names the fix; an unchanged
  failure repeats at most every 15 minutes. Logs show only the last four characters of a
  GUID, never the whole credential.
- `docs/API-NOTES.md` said a `1001` after ~6 s meant a bad GUID. A wrong GUID is
  rejected in ~15–30 ms; the ~6 s `1001` is the missing bindingRedirect.

## [0.4.0] - 2026-08-26

### Added
- `/govee guid <value>` writes the Govee Desktop API GUID into `config.json` and
  starts the daemon, so first-time setup no longer needs a hand-edited file. It is
  the one verb that edits the config directly rather than asking the daemon, because
  a missing GUID is the one condition under which the daemon refuses to run.
  `/govee doctor` now names that fix when the GUID is what's missing.
- `bubblegum` example theme: pastel pink, mint, lavender and lemon with slow sparkles.
- Six example themes shipped in `themes/` (`sunset`, `ocean`, `forest`, `neon`, `candle`,
  `signal`) and a `/govee theme install <name>|--all` verb to copy them into your own
  themes folder.
- Per-device trace of what each device resolves and sends, for diagnosing segment
  rendering.

### Changed
- Segment writes are paced (`MinSegmentIntervalMs`, default 200 ms) and DreamView is
  kept alive, so segment effects actually render on the strip instead of being
  flattened by the hardware under a write flood. Transitions into or out of a
  segment-rendering state now jump-cut rather than cross-fade for the same reason.
- README setup is now build → `guid` → `doctor`; the `Govee-API-GUID.txt` seed file
  remains as a development convenience.
- Two API polarities settled and documented in `docs/API-NOTES.md`; `IsGradientOff`
  stays at its default of `1`.

## [0.3.0] - 2026-08-13

The control plane: tune the lights from the prompt.

### Added
- `/govee styles [state]`, `set`, `preview`, `reset`, `save`, `revert` and `theme`
  verbs, with `--color`, `--color2`, `--effect`, `--hz`, `--brightness`,
  `--direction`, `--easing`, `--tail`, `--depth` and `--fullseconds` flags.
- A pending style layer between the saved config and the device: edits apply at
  once and stay unsaved until `/govee save`; `/govee revert` discards them.
- Built-in themes `default`, `muted`, `vivid` and `mono`, plus user themes saved to
  `%LOCALAPPDATA%\ClaudeGovee\themes\`. Applying a theme is total — anything it
  does not mention falls back to built-in.
- `/govee save` splices only the `States` block into `config.json`, preserving
  comments, key order and indentation everywhere else, and the daemon reloads the
  file after writing it.
- Style and theme endpoints on the daemon (`/styles`, `/styles/set`, `/themes`,
  `/preview` and friends), serialised against concurrent edits.

### Fixed
- `reset` then `set` lands on built-in-plus-patch, not config-plus-patch.
- Daemon error bodies surface in the CLI instead of being read as "not running".

## [0.2.0] - 2026-08-12

The style engine: composable effects.

### Added
- A shape-plus-stages effects pipeline: every effect produces one weight per
  segment, then shared direction, easing, depth and colour stages transform it.
- `wipe`, `progress`, `sparkle` and `rainbow` effects alongside `solid`, `breathe`,
  `pulse`, `blink`, `chase` and `comet`; `scanner` is `chase` with
  `Direction: pingpong`.
- Style modifiers `Color2`, `Direction`, `Easing`, `Tail`, `Depth` and `FullSeconds`.
- Styles resolve through a four-layer merge (device override → pending → config →
  built-in) so partial overrides apply, and per device so each strip can differ.
- Whole-frame cross-fades so motion blends across state changes.
- A headless frame-dump harness with golden frames, and `docs/EFFECTS.md`.

### Fixed
- Spatial effects fall back to `breathe` on single-zone devices; `pingpong` no
  longer teleports at the turnaround.

## [0.1.1] - 2026-08-09

### Fixed
- The daemon could idle out mid-session and never come back.
- Lights stayed dark after a reboot until `/govee refresh`: the cold-start roster
  window is documented and its recovery guarded.

## [0.1.0] - 2026-08-09

### Added
- Ambient Govee lighting driven by Claude Code activity: a Windows daemon fed by
  the plugin's hooks, a `/govee` slash command, and states for idle, thinking, each
  tool class, waiting on you, compacting, errors and done.
- CI on `windows-latest` that guards the silent-failure invariants — above all the
  `System.Runtime.CompilerServices.Unsafe` binding redirect, without which every
  Govee call times out with a bogus GUID error.

[Unreleased]: https://github.com/FlashGalatine/claude-govee-lights/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/FlashGalatine/claude-govee-lights/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/FlashGalatine/claude-govee-lights/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/FlashGalatine/claude-govee-lights/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/FlashGalatine/claude-govee-lights/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/FlashGalatine/claude-govee-lights/releases/tag/v0.1.0
