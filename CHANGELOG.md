# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the
`version` in `.claude-plugin/plugin.json`.

## [Unreleased]

### Changed
- The marketplace is named `claude-govee-lights` rather than
  `claude-govee-lights-local`, so the install command is
  `/plugin install claude-govee-lights@claude-govee-lights`. Anyone who added the
  old name must remove it and add the marketplace again.
- Every release is tagged (`v0.1.0` … `v0.4.0`) and the changelog links compare
  between tags.

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
