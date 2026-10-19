# Settings reference

Settings live in `~/.config/betterwm/config.conf`: one `key = value` per line, `#` starts a comment (a `#` directly after `=` is a value, so colours never need quoting). The Settings window in the menu edits the same file; Reload Config re-reads it after a manual edit. Import… and Export… move whole files around; exports include unsaved edits.

The file carries `version = 3`. Older files are migrated on load: `#`-prefixed colours lose the `#`, missing switcher bindings are added, and explicit widget lists gain the menu widget. Keys from removed features (`workspaces`, `virtualWorkspaces`, `focusRingStyle`) are accepted and ignored, so a file from any earlier release loads unchanged. Unknown keys are skipped.

Colours are `RRGGBB` or `RRGGBBAA`, no `#`. Sizes are points.

## Layout

| Key | Default | Meaning |
| --- | --- | --- |
| `gap` | 16 | Space between tiled windows |
| `outerGap` | 16 | Space between tiled windows and the screen edge (and the bar) |
| `handleWidth` | 16 | Width of the draggable bar in each gap |

## Tiling

| Key | Default | Meaning |
| --- | --- | --- |
| `autoTile` | false | Tile windows automatically when they open or arrive on a desktop |
| `autoTileStrategy` | rightmost | Where an auto-tiled window goes: `rightmost`, `leftmost`, `position` (where it appeared), `nextToFocused` (i3 default), `stackFocused` (below the focused window), `autoSplit` (beside if the focused window is wider than tall, else below; i3 autotiling), `spiral` (alternately beside and below the last tiled window) |
| `tileExistingOnStart` | true | When a desktop is first seen, tile the windows already on it, left to right |
| `restoreLayouts` | true | Save grids, floating windows and the active workspace to `state.json` and restore them on launch |
| `dragModifiers` | alt | Keys held while dragging to tile: `cmd`, `alt`, `ctrl`, `shift` joined with `+` |
| `stackOffset` | 48 | Horizontal shift between cascaded windows in stacked layout |
| `stackScreensNarrowerThan` | 0 | Screens narrower than this start in stacked layout; 0 never |
| `ignoreApps` | System Settings, Calculator, Activity Monitor, Installer, Passwords, App Store, 1Password, Karabiner settings and about twenty other utilities | Bundle identifiers never tiled automatically; dragging them into a column still works |
| `floatSmallWindows` | true | Leave dialog-sized windows floating |
| `smallWindowSize` | 500x400 | Width x height under which a window counts as small |

## Focus ring

| Key | Default | Meaning |
| --- | --- | --- |
| `focusRing` | true | Draw an outline around the focused window |
| `focusRingFloating` | true | Also around floating windows |
| `focusRingColor` | FF9300 | Ring colour for tiled windows |
| `focusRingFloatingColor` | 009193 | Ring colour for floating windows, or `same` |
| `focusRingWidth` | 6 | Thickness |
| `focusRingAutoRadius` | true | Measure each window's own corner radius |
| `focusRingRadius` | 24 | Corner radius when measuring is not possible |

## Status bar

| Key | Default | Meaning |
| --- | --- | --- |
| `bar` | true | Show the bar |
| `barHeight` | 32 | Height; at least the notch height on notched screens |
| `barTitleFormat` | {app} | Active window label; `{app}` and `{title}` are replaced |
| `barClockFormat` | EEE d MMM  HH:mm | Unicode date pattern for the clock |
| `barWidgets` | keyboard, wifi, battery, clock, menu | Right-side widgets in order; see [Status bar](status-bar.md) for the full list |
| `barDesktopApps` | true | One app icon per window on each desktop chip |
| `barBatteryPercent` | false | Number next to the battery icon |
| `barWeatherFahrenheit` | false | Weather units |
| `barWeatherLocation` | auto | `auto` for Location Services, or `latitude,longitude` |
| `barBackground` | 000000 | `blur` or a colour |
| `barTextColor` | FFFFFF | `auto` or a colour |
| `barActiveColor` | FF9300 | `accent` or a colour, for the active desktop chip |
| `barBorderColor` | 424242 | Border colour |
| `barBorderWidth` | 0 | Border width; 0 none |
| `barRadius` | 0 | Corner radius |
| `barPadding` | 24 | Inset of the content from the bar's edges |
| `barMargin` | 0 | Distance from the screen sides; above zero the bar floats |
| `barTopOffset` | 0 | Distance from the top edge |
| `barWeather`, `barBattery`, `barWifi`, `barInputSource`, `barCpu`, `barMemory`, `barDisk`, `barClock` | mirror `barWidgets` | Kept for older versions; setting one adds or removes the widget |

## Cats

| Key | Default | Meaning |
| --- | --- | --- |
| `barCat` | true | Show the cats |
| `barCatSheets` | empty (one built-in cat) | Comma-separated: sprite sheet paths in the Pixel Cats 64×64 layout, or `builtin` |
| `barNotchPortals` | true | Cats cross the notch through portals; off, they stay left of it |

## Other

| Key | Default | Meaning |
| --- | --- | --- |
| `switcher` | true | ⌥Tab window switcher |
| `switcherThumbnails` | true | Window previews in the switcher; needs Screen Recording, otherwise icons |
| `actionOverlay` | false | Flash the pressed hotkey and action name at the bottom of the screen |
| `debugLog` | true | Write `log.txt` |
| `hotkey.<action>` | see [Actions](actions.md) | Global hotkeys |

## The Settings window

Sections in the sidebar mirror this page: General, Tiling, Focus Ring, Status Bar, Widgets, Cats, Apps, Hotkeys. Nothing is applied until Save & Apply; the bar, hotkeys and focus ring then pick up the new values without a relaunch. Menu toggles (Pause, Auto-tile, Strategy, Switcher, Overlay) save immediately.
