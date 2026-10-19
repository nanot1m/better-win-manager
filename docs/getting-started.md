# Getting started

## Install

Homebrew:

```sh
brew install --cask nanot1m/tap/betterwm
xattr -dr com.apple.quarantine /Applications/BetterWM.app
```

Or download `BetterWM-x.y.z.zip` from [Releases](https://github.com/nanot1m/better-win-manager/releases), unzip, move `BetterWM.app` to Applications, and run the same `xattr` line. Releases are ad-hoc signed, not notarized, so without it Gatekeeper refuses the first launch; right-clicking the app and choosing Open once also works.

From source, with Command Line Tools only (no Xcode): `make install` builds, bundles, signs and copies to Applications.

## Permissions

| Permission | Needed for | When asked |
| --- | --- | --- |
| Accessibility | Reading and moving windows. Nothing works without it | First launch; the app waits until granted |
| Screen Recording | Window previews in the ⌥Tab switcher | Optional; without it the switcher shows app icons |
| Location Services | Weather for your current position | Optional; set a fixed `barWeatherLocation` instead |

Because the signature is ad-hoc, macOS treats every release as a new app and asks for Accessibility again after each update. Grant it and relaunch.

## The first five minutes

1. **The status bar** appears at the top of each screen. It is meant to replace the system menu bar: set "Automatically hide and show the menu bar" to Always in System Settings › Control Center. The app offers to open that pane once.
2. **Tile a window.** Hold ⌥ and drag any window. Drop zones light up: the left or right half of another window makes a new column on that side, the top or bottom half stacks it in that column. Let go to tile. Drag the bar in a gap to resize.
3. **Untile.** Move or resize a tiled window by hand and it leaves the grid, or press ⌃⌥T. Toggling again puts it back where it floated.
4. **Switch desktops.** ⌃1 to ⌃9, or click a chip in the bar. Desktops beyond the ones you have are created the moment you switch or send a window to them, and disappear again when empty. ⌃⌥1 to ⌃⌥9 send the focused window.
5. **Everything else** is in the menu behind the grid button at the right end of the bar (or the menu bar icon when the system bar is visible), and in the Window Actions popup, ⌥⌘Space.

The windows open when a desktop is first seen are tiled left to right. Turn that off with "Tile existing windows" in Settings › General if you would rather start from a clean slate.

## Where things are

- Settings: the menu, or `~/.config/betterwm/config.conf` plus Reload Config.
- Layouts: `~/.config/betterwm/state.json`, written automatically and restored on launch.
- Log: `~/.config/betterwm/log.txt`; Copy Diagnostics Report in the menu bundles it with your config and state for a bug report.
