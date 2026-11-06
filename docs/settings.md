# Settings reference

Settings live in `~/.config/betterwm/config.conf`: one `key = value` per line, `#` starts a comment (a `#` directly after `=` is a value, so colours never need quoting). The Settings window in the menu edits the same file; Reload Config re-reads it after a manual edit. Import… and Export… move whole files around; exports include unsaved edits.

The file carries `version = 4`. Older files are migrated on load: `#`-prefixed colours lose the `#`, missing switcher bindings are added, explicit widget lists gain the menu widget, and files from before the focus-floating action get its default binding. Keys from removed features (`workspaces`, `virtualWorkspaces`, `focusRingStyle`) are accepted and ignored, so a file from any earlier release loads unchanged. Unknown keys are skipped.

Colours are `RRGGBB` or `RRGGBBAA`, no `#`. Sizes are points.

## Layout

| Key | Default | Meaning |
| --- | --- | --- |
| `gap` | 16 | Space between tiled windows |
| `outerGap` | 16 | Space between the screen edge (and the bar) and the outermost thing at it: the focus ring, a tab strip or the ring's action pills |
| `outerGapTop`, `outerGapLeft`, `outerGapBottom`, `outerGapRight` | blank | Gap to that edge; blank takes `outerGap` |

## Tiling

| Key | Default | Meaning |
| --- | --- | --- |
| `autoTile` | false | Tile windows automatically when they open or arrive on a desktop |
| `autoTileStrategy` | rightmost | Where an auto-tiled window goes: `rightmost`, `leftmost`, `position` (where it appeared), `nextToFocused` (i3 default), `stackFocused` (below the focused window), `autoSplit` (beside if the focused window is wider than tall, else below; i3 autotiling), `spiral` (alternately beside and below the last tiled window) |
| `tileExistingOnStart` | true | When a desktop is first seen, tile the windows already on it, left to right |
| `restoreLayouts` | true | Save grids, floating windows and the active workspace to `state.json` and restore them on launch |
| `floatingOnAllDesktops` | true | Floating (untiled) windows follow to whichever desktop is shown instead of staying on one; tiling a window pins it to its desktop again |
| `dragModifiers` | alt | Keys held while dragging to tile: `cmd`, `alt`, `ctrl`, `shift` joined with `+` |
| `stackOffset` | 48 | Horizontal shift between cascaded windows in stacked layout |
| `stackStyle` | tabsTop | How a stacked screen looks: `cascade`, `tabsTop` (every window full size under a row of tabs), `tabsLeft` or `tabsRight` (sideways tabs down that edge) |
| `tabStyle` | glass | Inactive tabs: `flat` grey, or `glass` (macOS 26); the active tab keeps the ring colour |
| `tabHeight` / `tabWidth` | 30 / 240 | Thickness of the tab strip (its height on top, its width on the left, where tabs read sideways), and the longest a tab gets; the windows get the rest |
| `tabTitleFormat` | `{app} — {title}` | Tab label; `{app}` and `{title}` are replaced |
| `moveAcrossDesktops` | false | Move left/right on the outermost column carries the window to the previous/next desktop and follows it; off, the move cycles the column width |
| `tiledTabs` | false | A tab above every window in the columns layout too, showing its title or the name given to it |
| `resizeStep` | 40 | Points the `grow` / `shrink` actions resize the focused window by |
| `stackScreensNarrowerThan` | 0 | Screens narrower than this start in stacked layout; 0 never |
| `ignoreApps` | System Settings, Calculator, Activity Monitor, Installer, Passwords, App Store, 1Password, Karabiner settings and about twenty other utilities | Bundle identifiers never tiled automatically; dragging them into a column still works |
| `floatSmallWindows` | true | Leave dialog-sized windows floating |
| `smallWindowSize` | 500x400 | Width x height under which a window counts as small |

## Focus ring

| Key | Default | Meaning |
| --- | --- | --- |
| `focusRing` | true | Draw an outline around the focused window |
| `focusRingFloating` | true | Also around floating windows |
| `focusRingColor` | accent | Ring colour for tiled windows: hex, or `accent` for the system accent colour |
| `focusRingFloatingColor` | same | Ring colour for floating windows: hex, `accent`, or `same` as the tiled one |
| `focusRingWidth` | 6 | Thickness |
| `focusRingPadding` | 0 | Gap between a window and its ring; tiled windows shrink inside their slot by it, the ring stays put |
| `focusRingAutoRadius` | true | Measure each window's own corner radius |
| `focusRingActions` | true | Small icon buttons on the ring's top edge near the right corner. When no tab strip sits above the ring (columns layout without `tiledTabs`, or side tabs), the layout keeps room for them under the status bar |
| `fadeAnimations` | true | Transitions for the ring, tab strips and action buttons: fades in and out, the ring's colour cross-fade, tabs growing in and sliding over. Off with Reduce Motion in System Settings |
| `focusRingActionKeys` | toggleTile, toggleStack, toggleTabs, retile, sendToDesktop | Which actions the buttons run, left to right; any of toggleTile, toggleStack, toggleTabs, grow, shrink, equalize, retile, sendToPreviousDesktop, sendToNextDesktop, overview, popup |
| `focusRingRadius` | 24 | Corner radius when measuring is not possible |

## Status bar

| Key | Default | Meaning |
| --- | --- | --- |
| `bar` | true | Show the bar |
| `barHeight` | 32 | Height; at least the notch height on notched screens |
| `barTitleFormat` | {app} | Active window label; `{app}` and `{title}` are replaced |
| `barClockFormat` | EEE d MMM  HH:mm | Unicode date pattern for the clock |
| `barLeftWidgets` | desktops, fullscreen, title | Left-side widgets in order: desktop chips, fullscreen-app chips, active window label; leave one out to hide it |
| `barWidgets` | keyboard, wifi, battery, clock, menu | Right-side widgets in order; see [Status bar](status-bar.md) for the full list |
| `barDesktopApps` | true | One app icon per window on each desktop chip |
| `barBatteryPercent` | false | Number next to the battery icon |
| `barWeatherFahrenheit` | false | Weather units |
| `barWeatherLocation` | auto | `auto` for Location Services, or `latitude,longitude` |
| `barBackground` | glass | `blur`, `glass` (Liquid Glass on macOS 26, a blur before) or a colour. With `glass` the text colour always follows the system |
| `barChipStyle` | glass | `flat` colour fills for the desktop chips, or `glass` capsules with the active one tinted (macOS 26) |
| `glassStyle` | regular | Liquid Glass look wherever it is used: `regular`, or `clear` for a more transparent glass |
| `barTextColor` | auto | `auto` or a colour |
| `barActiveColor` | accent | `accent` or a colour, for the active desktop chip |
| `barFocusOutlineColor` | auto | Outline around the focused window's icon in its chip: `auto` contrasts with the chip, or a colour |
| `barBorderColor` | 424242 | Border colour |
| `barBorderWidth` | 0 | Border width; 0 none |
| `barRadius` | 0 | Corner radius |
| `barPadding` | 24 | Inset of the content from the bar's edges |
| `barMargin` | 0 | Distance from the screen sides; above zero the bar floats |
| `barPosition` | top | `top`, where the hidden menu bar lives, or `bottom`, above the Dock |
| `barTopOffset` | 0 | Distance from the edge the bar sits at |
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
| `switcherThumbnails` | false | Window previews in the switcher instead of icons with titles; needs Screen Recording, otherwise icons |
| `overview` | true | Desktop overview (see [actions](actions.md)); previews need Screen Recording, otherwise app icons |
| `overviewKey` | true | The Mission Control key (F3) opens the overview instead of Mission Control |
| `gestureFingers` | 4 | Fingers for both swipe gestures: 3 or 4 |
| `desktopSwipe` | false | Swipe left/right slides to the next/previous desktop, following the fingers (needs `overview` on), and past the last or first one on to the neighbouring macOS Space (fullscreen apps); set macOS's swipe between Spaces to three fingers or off |
| `overviewGesture` | false | Vertical swipe drives the overview; turn Mission Control's gesture off in System Settings › Trackpad › More Gestures first |
| `actionOverlay` | false | Flash the pressed hotkey and action name at the bottom of the screen |
| `debugLog` | true | Write `log.txt` |
| `checkForUpdates` | true | Ask GitHub once a day whether a newer release exists and offer it; Check for Updates… in the menu asks right away |
| `autoUpdate` | false | Download the signed release, swap it in and relaunch without asking |
| `hotkey.<action>` | see [Actions](actions.md) | Global hotkeys |

## The Settings window

Sections in the sidebar mirror this page: General, Tiling, Focus Ring, Status Bar, Widgets, Cats, Apps, Hotkeys. Nothing is applied until Save & Apply; the bar, hotkeys and focus ring then pick up the new values without a relaunch. Menu toggles (Pause, Auto-tile, Strategy, Switcher, Overlay) save immediately.
