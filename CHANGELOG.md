# Changelog

All notable changes to BetterWM. The format follows [Keep a Changelog](https://keepachangelog.com/); versions are tags on `master`, each with a release zip.

Config (`config.conf`) and layout state (`state.json`) are versioned and migrated on load, so upgrading never loses settings or layouts.

## [0.11.2] - 2026-10-15

### Added
- **Re-measure Window Corners** (menu, `refreshRing` action) recalculates every focus-ring corner radius; radii are also re-measured automatically when a window is resized.

### Fixed
- Retile Current Screen keeps the screen's stacked layout mode.

## [0.11.1] - 2026-10-15

### Fixed
- A hung app no longer freezes BetterWM. Accessibility calls are synchronous with a default timeout of about 6 s; every element now uses a 300 ms timeout, an app that times out is skipped for 5 s (logged), and its windows keep their place in the layout meanwhile. Thanks to @clbagrat for the report.

## [0.11.0] - 2026-10-15

### Added
- Action log at `~/.config/betterwm/log.txt` covering hotkeys, popup and menu actions, tiles, drops and releases, desktop switches and sends, reconcile changes and parking (`debugLog`).
- Menu: **Open Log File** and **Copy Diagnostics Report** (versions, screens, config with location redacted, state and recent log) for bug reports.

### Changed
- Stacked layout: windows keep their deck positions; focusing only raises. Move Left/Right reorder the deck.
- Stacked layout mode is saved per desktop, including for screens with no windows.
- Focus ring stays beneath its window, so clicks no longer re-stack it (and no longer flash), and it stays visible during drags.

### Fixed
- Tiling or dropping a window that belonged to another virtual workspace left it parked off-screen.
- Clicks in Electron apps (VS Code) made the ring blink: transient nil focus is tolerated and a press must move 4 pt before it counts as a drag.

## [0.10.0] - 2026-10-15

### Added
- Stacked (cascade) layout mode per screen: windows get almost the whole screen, shifted right by `stackOffset`; toggle with ⌃⌥S, the popup's S key or the menu; `stackScreensNarrowerThan` starts narrow screens stacked.
- Focus ring and status bar hide during Show Desktop.

### Changed
- WindowServer events go through one shared hub; SkyLight keeps a single callback per event, so separate subscribers used to steal each other's events.

## [0.9.2] - 2026-10-15

### Changed
- Full default hotkey set: ⌃] / ⌃[ focus, ⌃⌥ arrows move, ⌃⌥⇧ ←/→ merge, ⌃⌥T tile, ⌃⌥R retile, ⌃⌥E equalize, ⌃←/⌃→ and ⌃1–9 desktops, ⌃⌥1–9 send. The ⌃-arrow and ⌃-digit bindings require disabling Mission Control's own shortcuts.
- Hotkey recorder: Escape keeps the current binding; Delete clears it.

## [0.9.1] - 2026-10-15

### Changed
- Focus ring moves go straight to WindowServer (`SLSMoveWindow`); when the layout moves the focused window the ring is placed in the same pass, and on workspace switches it appears together with the windows.

## [0.9.0] - 2026-10-15

### Added
- Schema versions for `config.conf` and `state.json` with migrations on load.

### Changed
- **Virtual workspaces are the default**, and every macOS desktop now has its own independent set (active workspace, membership, grids). Switching modes no longer moves windows between Spaces.

## [0.8.1] - 2026-10-15

### Added
- Moving a lone edge column into the edge again cycles its width through 1/3, 1/4, 2/3, 1/2.
- Settings: Import… and Export….

## [0.8.0] - 2026-10-15

### Added
- ⌥Tab window switcher in ⌘Tab style, grouped by desktop with dividers and titles; ⌥⇧Tab backwards, Escape cancels, items clickable; optional window previews (`switcherThumbnails`); `switcher` toggle.
- Status bar shows the current keyboard layout (`barInputSource`).
- Virtual workspaces are created on demand when sending or switching to a higher number; trailing empty ones are trimmed.

### Changed
- Focus next/previous cycles floating windows too, in reading order.
- Focus ring hidden across virtual switches; `focusRingFloating` defaults to on.

## [0.7.0] - 2026-10-15

### Added
- Virtual workspaces mode (`workspaces = virtual`): N desktops emulated on one Space by parking other workspaces' windows just off the bottom-right corner; instant switching; focusing a parked window switches to its workspace; windows and grids migrate when switching modes.

### Fixed
- Cats stuck running in place when cornered; bystanders frozen during scenes.

## [0.6.1] - 2026-10-15

### Added
- `--demo` replays a step-per-line script with simulated cursor drags; `make demo` records it.

### Changed
- Status bar and focus ring hide on fullscreen Spaces.

## [0.6.0] - 2026-10-15

### Added
- Layouts are saved to `state.json` and restored on launch by matching windows to their old slots by app, title and frame (`restoreLayouts`).
- Multiple cats (`barCatSheets`), each with its own sprite sheet or the built-in one; pairs chase, sit, groom and nap together.

## [0.5.4] - 2026-10-15

### Added
- Settings: file picker and itch.io link for cat sprite sheets; settings pages scroll.

## [0.5.3] - 2026-10-15

### Added
- Status bar: CPU load, memory used and free disk (`barCpu`, `barMemory`, `barDisk`); percentages keep a stable two-digit width.

## [0.5.2] - 2026-10-15

### Added
- `barCatSheet`: optional sprite sheet in Last tick's "Pixel Cats 64x64" layout (never bundled).

### Changed
- Gap handles stack above the focus ring.

## [0.5.1] - 2026-10-15

### Added
- Pixel cat wandering the status bar with walk, run, sit, groom, sleep and stretch behaviours (`barCat`).
- `barBatteryPercent` toggles the battery percentage text.

## [0.5.0] - 2026-10-15

### Added
- Status bar: battery and Wi-Fi signal.

### Fixed
- Desktop chips in the bar now respond to a single click.

## [0.4.2] - 2026-10-15

### Changed
- Gap handles draw as a centred grip pill, solid with a guide line while dragging.
- Status bar sits behind app windows; configurable active desktop colour (`barActiveColor`).

### Fixed
- Crash on misaligned WindowServer event payloads.

## [0.4.1] - 2026-10-15

### Fixed
- Gap handles painted over floating windows.

## [0.4.0] - 2026-10-15

### Added
- Status bar under the auto-hidden menu bar: desktops, active window, weather (Open-Meteo, Location Services or fixed coordinates), clock; notch-aware; appearance options (background, text, border, radius, padding, margins, top offset); Settings › Bar.
- `make run` builds a signed debug `.app`.

### Fixed
- Colours are stored without a leading `#`; the parser previously read `#RRGGBB` as a comment, which lost the focus ring colour on relaunch.

## [0.3.2] - 2026-10-15

### Added
- Focus ring matches each window's own corner radius (`focusRingAutoRadius`); `focusRingFloating` rings untiled windows too.

### Changed
- Existing windows are tiled on first sight by default again (`tileExistingOnStart`); send-to-desktop items merged into one submenu.

## [0.3.1] - 2026-10-15

### Added
- Action overlay HUD showing the pressed hotkey and action (`actionOverlay`), for demos.
- MIT license.

### Changed
- Focus ring driven by WindowServer move/resize/front-change notifications instead of polling; layer-backed; no appearance animations on overlays.

## [0.3.0] - 2026-10-14

### Changed
- Layout engine rewritten as a pure reconciler over an intermediate representation (`BetterWMCore`): a `Snapshot` of the system plus the `DesiredState` yields frame commands; the app is a thin shell. Comes with an executable test suite.
- Minimum window sizes are learned only when a window ignores a requested frame; visible windows are matched to Accessibility by window ID.

### Fixed
- Crash when re-registering hotkeys; sending a tiled window reflows both desktops.

## [0.2.1] - 2026-10-14

### Added
- Layout presets in the popup (columns, main + stack, 2/3 + 1/3, 1/3 + 2/3, grid, stack), ⌥1–⌥6.
- `tileExistingOnStart` option.

### Fixed
- Desktop switches no longer retile; hotkey recording via the event tap so system-reserved combos record; one Carbon handler dispatching by ID (every binding fired the first action).

## [0.2.0] - 2026-10-14

### Added
- Configurable focus ring (outline or glow underneath).
- Send focused window to next/previous/specific desktop via SkyLight's bridged move (vendored from WhichSpace, MIT).

### Fixed
- Settings window opens on the active desktop.

## [0.1.0] - 2026-10-14

### Added
- Column-based tiling by ⌥-drag with highlighted drop zones; stacking within columns; draggable gap handles; configurable gaps.
- One grid per macOS desktop; auto-tiling of new windows with placement strategies (rightmost, leftmost, position, next to focused, stack below focused, auto split, spiral); ignore list and small-window rule.
- Window actions popup, global hotkeys, menu bar menu, settings window, `config.conf`.
- Instant desktop switching via a synthetic Dock swipe; ⌥-scroll to switch.
- Ad-hoc signed app bundle and GitHub release workflow.

[0.11.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.2
[0.11.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.1
[0.11.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.0
[0.10.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.10.0
[0.9.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.2
[0.9.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.1
[0.9.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.0
[0.8.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.8.1
[0.8.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.8.0
[0.7.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.7.0
[0.6.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.6.1
[0.6.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.6.0
[0.5.4]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.4
[0.5.3]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.3
[0.5.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.2
[0.5.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.1
[0.5.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.0
[0.4.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.2
[0.4.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.1
[0.4.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.0
[0.3.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.2
[0.3.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.1
[0.3.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.0
[0.2.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.2.1
[0.2.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.2.0
[0.1.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.1.0
