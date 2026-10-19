# Changelog

All notable changes to BetterWM. The format follows [Keep a Changelog](https://keepachangelog.com/); versions are tags on `master`, each with a release zip.

Config (`config.conf`) and layout state (`state.json`) are versioned and migrated on load, so upgrading never loses settings or layouts.

## [0.12.5] - 2026-10-19

### Fixed
- A cat that leapt through a notch portal could get stuck jumping on the spot afterwards: the leap had no end condition it could meet. It now lands back in its stride as soon as it is clear of the notch.

## [0.12.4] - 2026-10-19

### Changed
- Cats use the whole sprite pack: five sleeping poses picked per nap (lazy cats sprawl), paw licking and both grooming swipes, a standing tail-wag for watching things, paw swipes at the pointer when they catch it and at a portal before poking into it, rearing up on hind legs when the pointer hovers right over them, a meow on the first pet, a happy jump on the third, a hiss when fed up or cornered in a chase, a yawn on waking, a leap through the notch portals, scratching when bored, and a meal by the battery icon when the charger goes in after the battery ran low. Frame counts are read from the sheet, and a sheet missing an extra animation falls back to the nearest core one.
- Cats notice the bar: when you switch desktops the awake ones glance at the new chip and a playful one trots toward it; a low battery makes them huddle by the battery icon; a busy machine makes them sit and stare at the gauges. Before visiting another cat, a cat now stops and looks at it first. With three or more cats one sometimes leads the others in a line. Playful cats poke their head into a notch portal and back a few times before going through. They are sleepier after lunch and livelier in the morning.

### Fixed
- After a desktop switch the focus ring could end up beneath other windows: it was ordered under its window before that window was raised and before hidden apps came back. The ring is re-ordered once those settle.

## [0.12.3] - 2026-10-19

### Changed
- Switching to the desktop that is already active (its hotkey, chip or menu item) cycles focus through its windows instead of doing nothing.

## [0.12.2] - 2026-10-19

### Changed
- The Settings window follows System Settings: a sidebar of sections (General, Tiling, Focus Ring, Status Bar, Widgets, Cats, Apps, Hotkeys) and grouped rows with a plain title, a one-line explanation and the control on the right; switches instead of checkboxes; resizable. All settings and the import/export/save flow are unchanged.

### Added
- Documentation in `docs/`: getting started, concepts, actions and hotkeys, a full settings reference, status bar, cats, troubleshooting and internals.

## [0.12.1] - 2026-10-19

### Fixed
- A config reload or any setting change folded on-demand desktops (5 and up) back into the last configured one, moving their windows there. The configured count is now a minimum; extra desktops go away only once empty.

### Added
- The active workspace of each desktop is remembered and restored at launch.

### Removed
- The workspace count setting (`virtualWorkspaces`): desktops are created on demand and trimmed when empty, so a fixed number served no purpose. The key is accepted and ignored.
- The "glow underneath" focus ring style (`focusRingStyle`); the ring is always an outline. The key is accepted and ignored.

### Changed
- New defaults for fresh installs: status bar on with a black background, white text and orange accents, keyboard/Wi-Fi/battery/clock/menu widgets, app-only window title, 32pt bar with 24pt padding, orange focus ring (6pt, 24pt radius) with a teal ring for floating windows, auto-tiling off. Existing configs are untouched.
- Switch to Desktop and Send to Desktop list all nine desktops; ones that do not exist yet are marked (new) and created when chosen.
- The settings window no longer puts the cursor into the first text field when it opens or when you switch tabs.
- The menu is grouped into Window, Screen, Desktops, Tiling and BetterWM sections, with the diagnostics items in a submenu.
- Menu items, including the Move, Switch to Desktop and Send to Desktop submenus, show the hotkeys you configured instead of made-up ⌘ shortcuts that never worked from the menu bar.

## [0.12.0] - 2026-10-19

### Added
- Homebrew tap: `brew install --cask nanot1m/tap/betterwm`, then clear the quarantine flag as for a downloaded zip. The release workflow updates the cask on every tag.

### Removed
- The native macOS Spaces mode (`workspaces = native`). Virtual workspaces are the only mode now; the `workspaces` config key is accepted and ignored, so older files load unchanged. Gone with it: synthetic Dock-swipe Space switching, the SkyLight window-move bridge vendored from WhichSpace, the title-bar-drag fallback for moving windows between Spaces, and the native/virtual migrations.

## [0.11.20] - 2026-10-19

### Fixed
- Unplugging a monitor left things in a mess: windows parked in the old screen's corner were pulled onto the remaining screen and re-parked in a loop, floating windows came back with the old screen's size, and windows of apps that had been hidden for a while were dropped from their grid when unhidden because the two-second read grace had long expired. Frames remembered on a vanished screen are now fitted to the current one, re-parking gives up after three attempts, and the grace window is kept open for as long as a window is carried for a known reason. When a tracked window does leave the snapshot the log now records why.

## [0.11.19] - 2026-10-19

### Fixed
- A window closed by the user but kept off screen by its app (ChatGPT does this) stayed in the grid and reserved its slot, since 0.11.16 treated any window WindowServer still lists as alive. A window that fails to read is now carried only while there is a reason: it was readable within the last two seconds, its app is hidden or unresponsive, or the screen is locked.

## [0.11.18] - 2026-10-19

### Fixed
- Desktops created on demand (sending a window to desktop 5 with four configured) were not recreated at launch; their saved windows ended up on the last configured desktop. Restoring a window to a higher desktop now creates it.
- Switching to a workspace holding one window of an app whose other windows live elsewhere sometimes showed all of them: the corner move issued while the app was still unhiding was lost. Parked windows found away from the corner are parked again, and a follow-up pass runs shortly after every unhide.

### Added
- Virtual workspaces can be reordered: drag a desktop chip in the status bar to a new slot, or use the Move This Desktop Left/Right menu items and the `desktopMoveLeft`/`desktopMoveRight` actions (unbound by default). Grids, floating windows and saved layouts follow the desktop. Native macOS Spaces cannot be reordered this way.

## [0.11.17] - 2026-10-18

### Changed
- Desktop chips show one icon per window, so an app with two windows on a desktop shows its icon twice (replaces the count badge from 0.11.16).

## [0.11.16] - 2026-10-18

### Added
- Desktop chips show a small count on an app's icon when it has more than one window on that desktop.

### Fixed
- Tiled windows were dropped from their grid ("detached") whenever a snapshot could not read them through Accessibility while they still existed: an app hidden for an inactive workspace being unhidden, a hung app in its cooldown, a locked screen. The snapshot now keeps the last known state of any tracked window WindowServer still lists, so a transient read failure no longer untiles it. Thanks to @clbagrat for the diagnostics.

## [0.11.15] - 2026-10-17

### Fixed
- App icons on the desktop chips shuffled whenever focus changed, because they followed window z-order. Each desktop now keeps a stable order: apps hold their slot while they have a window there and new ones append.

## [0.11.14] - 2026-10-16

### Added
- Status bar: the active window label is formatted by `barTitleFormat` (default `{app} — {title}`; Settings › Bar › Window title).
- Status bar: a Now Playing widget (off by default; enable in Settings › Widgets) showing the current Music or Spotify track with a play/pause button. The button presses the system media key, so it also controls other players; track info is read only from Music and Spotify, since macOS no longer exposes Now Playing to third-party apps.

### Fixed
- Floating windows of apps hidden for an inactive workspace were not saved, so they lost their workspace on relaunch. Every window a workspace knows is now part of the snapshot and the saved layout.
- Closed windows stayed in the workspace bookkeeping, so a desktop chip kept showing an app that had no window there, and after an app restarted (Chrome updating itself) the old and new processes both showed. Dead windows are now pruned every tick.
- When an app restarts mid-session (an update), its windows reopened on the active workspace. Windows of an app launched in the last 15 seconds are matched against the latest saved layout by exact title and sent back to the workspace they were on.
- Switching workspaces sometimes left Finder frontmost with no window: hiding the departing app let macOS pick the next one. The destination workspace's top app is activated first; an empty workspace activates BetterWM itself instead.

## [0.11.13] - 2026-10-16

### Fixed
- The menu widget's click area was only as big as its icon; it now spans the bar height and a wider margin.

## [0.11.12] - 2026-10-16

Config schema is now version 3 (adds the menu widget to saved widget lists); older files are migrated on load.

### Fixed
- Retile (ctrl+alt+r, Tile All Windows in the menu) tiles hand-floated windows on that screen again; since 0.11.8 they were skipped as deliberately floating.

### Added
- Status bar: the notch portals are a setting (`barNotchPortals`, Settings › Bar); off, cats stay left of the notch. A long window title no longer runs up to the notch and traps the cats there: room is reserved for them, and if there is none they live right of the notch.
- Status bar: a BetterWM menu widget (grid icon, last on the right by default) that opens the app menu on click. Toggle or move it in Settings › Widgets.
- Focus ring: a separate colour for a focused floating (untiled) window (`focusRingFloatingColor`, default "same"; Settings › General › Focus Ring › Floating).

### Changed
- Cats have drives and personalities. Energy, boredom and affection move slowly with what each cat does and decide its next pose instead of a dice roll: tired cats nap (longer if lazy), bored playful cats run or start a chase, petted cats groom and seek company. Each cat's temperament is seeded from its sprite sheet, so the same cat behaves the same every launch. Two-cat scenes are now started by a cat and pick the nearest partner, with the kind of scene following the mood: cuddle when tired, grooming when affectionate, chase when bored.
- Hunting the pointer is by interest: playful or well-petted cats join, others carry on (one always humours you), and interest fades after a while. When the pointer leaves, interested cats stroll to where it was and look for it.
- Petting: a sleeping cat wakes and looks around; three pets in a row make it lie down purring; too many and it walks off, a little offended.

## [0.11.11] - 2026-10-16

### Fixed
- Notch portals were drawn over the cats; cats now pass in front of the portal ovals.

## [0.11.10] - 2026-10-16

### Added
- Status bar widgets have their own Settings tab: tick to show, arrows to reorder. The order is stored as `barWidgets` (comma-separated: weather, cpu, memory, disk, keyboard, wifi, battery, clock); the old `barWeather`/`barCpu`/… flags are still read and written so older configs and older versions keep working. The clock can now be hidden too.
- Cats are interactive: hover the empty part of the bar and they run over to catch the pointer, sitting side by side when they get there; click a cat to pet it (it grooms or lies down, with a heart).
- Cats cross the notch through a pair of Portal-style portals, blue on the left and orange on the right, lit only while a cat is passing. The part of the cat that has gone into one edge comes out of the other, so it never disappears.

### Changed
- Move Left/Right/Up/Down and Merge now work on a floating window: it is tiled where it sits first, then moved. The popup and menu no longer grey these out for floating windows.

### Fixed
- Apps hidden for inactive workspaces stayed hidden when BetterWM was killed (SIGTERM, as `pkill` or `make run` do) rather than quit. SIGTERM now runs the normal quit path, and the set of hidden apps is saved so a launch after a crash unhides them first.

## [0.11.9] - 2026-10-16

### Changed
- Virtual workspaces: an app whose windows all live on inactive workspaces is now hidden with the native Hide instead of being moved to the screen corner, where a sliver of each window stayed visible. Only apps with windows on several workspaces of the same desktop still park the inactive ones in the corner. Hidden windows keep their real frames, stay in the ⌥Tab switcher and the desktop chips, and the app is unhidden the moment one of its windows' workspaces becomes active. Quitting unhides everything.

### Fixed
- Idle CPU (about 2%): a full Accessibility snapshot of every window ran once a second, and the focus ring re-resolved focus once a second, whether or not anything had changed. Both now react to WindowServer and Accessibility events, with 5-second safety timers. Idle main-thread work dropped by about two thirds in sampling; what remains is mostly the pixel cat animation (`barCat = false` removes it).

## [0.11.8] - 2026-10-16

### Fixed
- Virtual workspaces: floating windows came back after a relaunch on the wrong workspace, stuck in the parking corner. Their workspace and real frame are now saved in state.json and restored on launch, and they stay floating instead of being tiled as new windows (native desktops too); quitting unparks everything first; a window still found stranded in a corner is pulled back on screen.
- Virtual workspaces: a window untiled by hand was tiled again after leaving and returning to its workspace, because parking hid it from the desktop's known set and it came back as a new arrival. Hand-untiled windows now stay floating until tiled again.
- Menu toggles (Auto-tile New Windows, the strategy, ⌥Tab switcher, action overlay) were not written to the config and reset on relaunch.
- ⌥-dragging a window lagged. Profiling under a synthetic drag found the main thread, where the event tap runs, blocked by Accessibility round-trips per mouse move: the Accessibility observer treated every window-moved and window-resized notification as a focus change (two focus lookups and a status bar refresh each); the focus ring did a full focus lookup for moves of windows other than the ringed one; the status bar's per-desktop app scan went through Accessibility for every window; the dragged window's ID was re-resolved per move; and the window itself was moved with synchronous calls inside the tap. Moves now run off-thread with only the latest position applied, moved/resized notifications only nudge the ring (and not during a drag), the app scan uses the window list alone, bar refreshes wait until the drag ends, and screens and the window ID are resolved once per drag.

### Added
- A window dragged or resized by hand (without ⌥) that ends up floating remembers that spot, so toggling tiling off later returns it there. ⌥-dropping into a zone keeps the pre-drag position as the floating spot.

## [0.11.7] - 2026-10-16

### Added
- Toggling tiling off for the focused window puts it back where it floated before it was tiled by hand (⌥-drop or the toggleTile action).
- Status bar: each desktop chip shows the icons of the apps open there (`barDesktopApps`, on by default; toggle in Settings › Bar).

## [0.11.6] - 2026-10-15

### Fixed
- Virtual workspaces: the desktop flipped back and forth when two apps fought over focus (Unity grabbing it after a compile while you typed in another app). Focus is now followed only after input that can bring an app forward (a click, a ⌘ combo such as ⌘Tab, or Return), and each such input allows a single follow. Diagnosed from @clbagrat's recording.

## [0.11.5] - 2026-10-15

### Fixed
- Virtual workspaces: an app recreating its only window (Unity on scene reload or Play mode) had no sibling windows to follow, so the new window still landed on the active workspace. Each app's last workspace is now remembered and used instead; only a window the frontmost app opens right after user input joins the active workspace. A window placed on a background workspace this way no longer pulls focus (and the desktop) there when its app focuses it. Thanks again to @clbagrat for the follow-up.

## [0.11.4] - 2026-10-15

### Fixed
- Copy Diagnostics Report (and the demo runner) left the action overlay switched on; confirmations now flash without changing the setting.

## [0.11.3] - 2026-10-15

### Fixed
- Virtual workspaces: a window opened by an app that isn't frontmost (Unity recreating its editor window, a background app opening a document) now joins the workspace holding the app's other windows instead of the active one, so it no longer appears on your desktop out of nowhere.
- Focus-following switches workspaces only after user input (⌘Tab, Dock, a click); an app activating itself after a build no longer yanks you to its workspace.
- Saved layouts record parked windows at their real slot rather than the off-screen parking position. Thanks to @clbagrat for the report.

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

[0.11.4]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.4
[0.11.3]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.3
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
