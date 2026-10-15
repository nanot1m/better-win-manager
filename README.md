# BetterWM

Column-based tiling window manager for macOS. Tile windows by ⌥-dragging them into place; everything else stays a normal, freely movable window.

- Columns across the screen, windows stacked within a column
- One grid per desktop (Space) and per screen
- Drop zones highlighted while dragging, draggable gap handles to resize
- Auto-tiling of new windows with several placement strategies
- Instant desktop switching that skips the slide animation
- Menu bar menu, keyboard popup, global hotkeys, settings window

## Install

### From a release

Download `BetterWM-x.y.z.zip` from [Releases](https://github.com/nanot1m/better-win-manager/releases), unzip, and move `BetterWM.app` to Applications.

Releases are ad-hoc signed, not notarized, so Gatekeeper blocks the first launch. Either right-click the app and choose Open, or clear the quarantine flag:

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

Nothing is rearranged on launch. Use Retile Current Screen from the menu to tile what is open, or enable `tileExistingOnStart` in the config.

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

Every popup action, plus retile, equalize, pause and desktop switching, can also be bound to a global hotkey in the config.

### Menu bar

Window actions, Focus next/previous, Retile, Equalize, Auto-tile toggle and strategy, Switch to Desktop, Pause, Settings.

## Configuration

Open Settings from the menu bar, or edit `~/.config/betterwm/config.conf` and choose Reload Config. The file is created on first run with every option commented.

```ini
gap = 16
outerGap = 16
handleWidth = 16

tileExistingOnStart = false
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
- Desktop identity and ordering come from SkyLight private functions loaded with `dlsym`. Desktop switching posts the same Dock-swipe event sequence a three-finger trackpad swipe produces, which is why it is instant. Sending a window to another desktop uses SkyLight's bridged move operation via code vendored from [WhichSpace](https://github.com/gechr/WhichSpace) (MIT); the exported APIs for this stopped working with SIP enabled. All of these are undocumented and may need updating on new macOS releases.
- The focus ring is a layer-backed click-through overlay driven by WindowServer move/resize/front-change notifications (the SkyLight mechanism JankyBorders uses), with frames read via `SLSGetWindowBounds`; no polling beyond a slow safety net.
- Windows that ignore a requested size are remembered as minimums and the layout distributes space around them.

## Development

```sh
swift build
.build/debug/BetterWM --settings                       # open Settings on launch
.build/debug/BetterWM --snapshot-settings /tmp/s.png   # render each Settings tab to PNG
make zip                                               # dist/BetterWM-<version>.zip, ad-hoc signed
swift run CoreTests                                    # reconciler tests (plain executable; CLT has no XCTest)
```

The layout logic lives in the `BetterWMCore` library: a pure `Reconciler` turns a `Snapshot` of the system plus the `DesiredState` into frame commands, with no Accessibility calls. The app is a thin shell that builds snapshots, executes commands and turns gestures into state changes.

Pushing a tag like `v0.1.0` runs the Release workflow, which builds the zip and publishes a GitHub release.

## License

MIT. The SkyLight bridge in `Sources/SkyLightBridge` is vendored from [WhichSpace](https://github.com/gechr/WhichSpace), also MIT; see its license file there.
