# BetterWM

Column-based tiling window manager for macOS. Tile windows by ⌥-dragging them into place; everything else stays a normal, freely movable window.

- Columns across the screen, windows stacked within a column
- Virtual workspaces per macOS desktop: instant switching, reorderable, created on demand
- Drop zones highlighted while dragging, draggable gap handles to resize
- Auto-tiling of new windows with several placement strategies
- Instant desktop switching that skips the slide animation
- Optional status bar under the auto-hidden menu bar: desktops, active window, weather, clock; notch-aware
- Menu bar menu, keyboard popup, global hotkeys, settings window

## Documentation

The [docs](docs/README.md) folder covers everything in depth: [getting started](docs/getting-started.md), [concepts](docs/concepts.md), [actions and hotkeys](docs/actions.md), the [settings reference](docs/settings.md), the [status bar](docs/status-bar.md), [cats](docs/cats.md), [troubleshooting](docs/troubleshooting.md) and [internals](docs/internals.md).

## Install

### Homebrew

```sh
brew install --cask nanot1m/tap/betterwm
```

Or install directly from this repository:

```sh
brew install --cask nanot1m/better-win-manager/betterwm
```

> The cask automatically clears Gatekeeper's `com.apple.quarantine` attribute during installation (`postflight_steps`). If you ever need to clear it manually:
> ```sh
> xattr -dr com.apple.quarantine /Applications/BetterWM.app
> ```

The cask lives in [nanot1m/homebrew-tap](https://github.com/nanot1m/homebrew-tap) and in this repository, updated on each release.

### From a release

Download `BetterWM-x.y.z.zip` from [Releases](https://github.com/nanot1m/better-win-manager/releases), unzip, and move `BetterWM.app` to Applications.

Releases are ad-hoc signed, not notarized, so Gatekeeper blocks the first launch if downloaded via a browser. Either right-click the app and choose Open, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/BetterWM.app
```

Grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility), then relaunch. Because the signature is ad-hoc, macOS treats each release as a new app and asks for Accessibility again after updating.

### From source

```sh
git clone git@github.com:nanot1m/better-win-manager.git
cd better-win-manager
make install        # builds, bundles, ad-hoc signs, copies to /Applications
```

Or run the bare binary during development with `swift build && .build/debug/BetterWM`. Requires macOS 13+ and Swift 5.9+; Command Line Tools are enough, no Xcode needed.

On the first run the windows on the current desktop are tiled, ordered left to right. Set `tileExistingOnStart = false` in the config to keep launch from rearranging anything. Each desktop's grid is saved to `~/.config/betterwm/state.json` and restored on the next launch by matching windows to their old slots by app and title (`restoreLayouts`).

## Usage

### Tiling with the mouse

- Hold ⌥ and drag any window. You can also press ⌥ partway through a normal drag.
- Left or right half of a window: new column on that side.
- Top or bottom half: stack above or below it.
- Empty column: fills it.
- Drag the bar in a gap between columns or stacked windows to resize them.
- Move or resize a tiled window normally and it leaves the grid; the others reflow.
- ⌥ + scroll wheel switches desktop.

### Keyboard

⌥⌘Space opens the Window Actions popup, centred on the focused window. While it is open:

| Key | Action |
| --- | --- |
| ← → ↑ ↓ or H L K J | Move the focused window |
| ⇧← ⇧→ or ⇧H ⇧L | Merge into the left / right column |
| Tab, ⇧Tab | Focus next / previous window |
| T | Tile / untile the focused window |
| 1–9 | Switch to that desktop |
| Esc | Close |

Default global hotkeys: ⌥⌘Space popup, ⌥Tab switcher, ⌃] / ⌃[ focus next/previous, ⌃⌥ arrows move, ⌃⌥⇧ ←/→ merge, ⌃⌥T tile, ⌃⌥R retile, ⌃⌥E equalize, ⌃←/⌃→ and ⌃1–9 switch desktop, ⌃⌥1–9 send the window there. The ⌃-arrow and ⌃-digit ones collide with Mission Control's own shortcuts; disable those in System Settings › Keyboard › Keyboard Shortcuts › Mission Control. All bindings are editable in Settings › Hotkeys or the config.

### Stacked layout

Per screen, as an alternative to columns: every tiled window gets almost the whole screen and each is shifted right by `stackOffset` points, so the windows behind stay visible as strips you can peek at and click. Windows keep their positions in the deck; focusing one only brings it to the front. Move Left/Right reorder the deck. Toggle it for the current screen with ⌃⌥S, the popup's S key, or the menu. `stackScreensNarrowerThan` starts narrow screens in this mode automatically.

### Virtual workspaces

Every macOS desktop gets its own independent set of workspaces, created on demand (switch or send a window to desktop 4 and desktops 2 to 4 exist) and trimmed when empty, with its own active workspace, window membership and grids; nothing crosses between macOS desktops. Switching is instant and needs no Mission Control tricks: an app whose windows all live on inactive workspaces is hidden, and an app with windows on several workspaces has the inactive ones parked just off the bottom-right corner of the screen, like AeroSpace does. Drag a chip in the status bar or use Move This Desktop Left/Right to reorder them. All desktop actions, the popup, hotkeys, the ⌥Tab switcher and the bar chips refer to the current macOS desktop's workspaces. Hidden and parked windows still appear in ⌘Tab.

### Status bar

Enable it in Settings › Bar or with `bar = true`. Pixel cats wander the free part of the bar (`barCat`); list sprite sheets in Last tick's free [Pixel Cats 64x64](https://last-tick.itch.io/animated-pixel-cats-64x64) layout in `barCatSheets`, one cat each, and two or more cats will chase, sit, groom and nap together. That pack forbids redistribution, so it is never bundled; download it yourself. It sits at the top of each screen where the system menu bar lives, so set "Automatically hide and show the menu bar" to Always in System Settings › Control Center; the app offers to open that pane once. Tiled windows start below the bar. Desktop chips switch desktops on click. Weather comes from Open-Meteo using either Location Services or fixed `barWeatherLocation = lat,lon`.

### Debugging and bug reports

BetterWM keeps an action log at `~/.config/betterwm/log.txt` (hotkeys, popup and menu actions, tiles and drops, workspace switches, reconcile changes, parking, errors; `debugLog = false` turns it off). For a bug report use **Copy Diagnostics Report** in the menu: it puts the app and macOS versions, screen setup, config (location redacted), `state.json` and the recent log on the clipboard.

### Menu bar

Window actions, Focus next/previous, Retile, Equalize, Auto-tile toggle and strategy, Switch to Desktop, Pause, Settings.

## Configuration

Open Settings from the menu bar, or edit `~/.config/betterwm/config.conf` and choose Reload Config. The file is created on first run with every option commented.

Both `config.conf` and `state.json` carry a `version`; files written by older releases are migrated on load (renamed keys keep working, stored ids are upgraded), so updating never loses settings or layouts.

```ini
gap = 16
outerGap = 16
handleWidth = 16

tileExistingOnStart = true
autoTile = true
# rightmost, leftmost, position, nextToFocused, stackFocused, autoSplit, spiral
autoTileStrategy = rightmost

# Bundle identifiers never tiled automatically (System Settings, Calculator, ... by default)
ignoreApps = com.apple.systempreferences, com.apple.calculator
floatSmallWindows = true
smallWindowSize = 500x400

dragModifiers = alt

hotkey.popup = alt+cmd+space
# hotkey.moveLeft = alt+cmd+h
# hotkey.desktop1 = alt+cmd+1
```

Placement strategies:

| Strategy | New window goes |
| --- | --- |
| `rightmost` / `leftmost` | New column at the right / left edge |
| `position` | New column where the window appeared on screen |
| `nextToFocused` | New column right after the focused window's column (i3 default) |
| `stackFocused` | Below the focused window in its column |
| `autoSplit` | Beside the focused window if it is wider than tall, otherwise below (i3 autotiling) |
| `spiral` | Alternately beside and below the last tiled window; approximates dwindle layouts |

## How it works

- Windows are read and moved through the Accessibility API; a CGEvent tap catches ⌥-drags and ⌥-scroll.
- Identifying the current macOS desktop and the desktop a window is on uses SkyLight private functions loaded with `dlsym`; nothing is switched or moved through them. Workspace switching hides apps and parks windows with ordinary Accessibility calls. The private functions are undocumented and may need updating on new macOS releases.
- The focus ring is a layer-backed click-through overlay driven by WindowServer move/resize/front-change notifications (the SkyLight mechanism JankyBorders uses), with frames read via `SLSGetWindowBounds`; no polling beyond a slow safety net.
- Windows that ignore a requested size are remembered as minimums and the layout distributes space around them.

## Development

```sh
swift build
.build/debug/BetterWM --settings                       # open Settings on launch
.build/debug/BetterWM --snapshot-settings /tmp/s.png   # render each Settings tab to PNG
make zip                                               # dist/BetterWM-<version>.zip, ad-hoc signed
swift run CoreTests                                    # reconciler tests (plain executable; CLT has no XCTest)
make run                                               # debug build as a signed .app (needed for Location Services)
make demo                                              # record demo/demo.txt to dist/demo.mov (+ .mp4 with ffmpeg)
```

The layout logic lives in the `BetterWMCore` library: a pure `Reconciler` turns a `Snapshot` of the system plus the `DesiredState` into frame commands, with no Accessibility calls. The app is a thin shell that builds snapshots, executes commands and turns gestures into state changes.

`demo/demo.txt` is a step-per-line script (`open`, `drag`, `action`, `layout`, `popup`, `caption`, `wait`, `quit`) that the app replays with `--demo`, so recordings are repeatable; `make demo` wraps it in `screencapture`, which needs Screen Recording permission for the terminal. Press the popup hotkey (⌥⌘Space by default) to abort a running demo; Ctrl+C in the terminal stops the recording and quits the app.

Pushing a tag like `v0.1.0` runs the Release workflow, which builds the zip and publishes a GitHub release.

## Changelog

See [CHANGELOG.md](CHANGELOG.md); release notes on GitHub are taken from it.

## License

MIT.
