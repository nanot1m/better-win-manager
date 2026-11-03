# Status bar

One bar per screen at the top edge, where the hidden system menu bar lives. Enable or disable it with `bar`; set its height with `barHeight`. Tiled windows start below it. Set "Automatically hide and show the menu bar" to Always in System Settings › Control Center so the two do not overlap; on a notched MacBook the bar is at least as tall as the notch row.

## Left side

**Desktop chips**, one per workspace living on this screen. The one you are working on uses `barActiveColor`; one merely shown on another screen is marked more lightly. Each chip shows one icon per window open there (`barDesktopApps`), in a stable order: an app keeps its slot while it has a window there and newcomers append. Click a chip to switch; drag it to reorder workspaces; right-click it for a menu: switch, send the focused window there, move left or right, send the desktop to the next screen, and for a stacked desktop pick the stacked look (cascade or tabs), for a columns desktop show or hide the tabs above its windows. Drag a window onto a chip to send the window to that desktop; the chip lights up while the window is over it. The bar stays above app windows, so a dragged window never hides it.

**Active window label**, formatted by `barTitleFormat`; a window whose tab was renamed shows that name instead. `{app}` and `{title}` are replaced, anything else is printed as is; the app name is bold. With no title, or a title equal to the app name, only the app is shown. The default is `{app}`.

**Cats** roam whatever is free between the left and right content; see [Cats](cats.md).

## Widgets

Both sides of the bar are lists of widgets. `barLeftWidgets` (default `desktops, fullscreen, title`: the desktop chips, the fullscreen-app chips, the active window label) and `barWidgets` (the right side) are the ordered lists of what appears, left to right. In Settings › Widgets each widget has a switch and a grip to drag it into place; a widget with settings of its own (desktop chip app icons, the title format, clock format, battery percentage, weather units and location) shows them under a disclosure in its row.

| Widget | Shows | Notes |
| --- | --- | --- |
| `weather` | Temperature and a condition symbol | Open-Meteo; location from Location Services (`barWeatherLocation = auto`) or fixed `lat,lon`; `barWeatherFahrenheit` |
| `cpu` | CPU load | Stable-width percentage |
| `memory` | Memory used | |
| `disk` | Free space on the boot volume | |
| `keyboard` | Current input source | Short code such as EN |
| `wifi` | Signal strength bars | Slashed when disconnected |
| `battery` | Battery icon; red under 15 % unless charging | `barBatteryPercent` adds the number |
| `clock` | Date and time | `barClockFormat`, a Unicode date pattern; default `EEE d MMM  HH:mm` |
| `menu` | Grid button that opens the BetterWM menu | |
| `sound` | Speaker icon showing the output level | Click for a popover with output volume and mute, output device, input volume and input device; scrolling over the icon changes the volume |
| `media` | Now Playing with a play/pause button | Track info only from Music and Spotify, read through their scripting interfaces while they run; macOS no longer exposes Now Playing to third-party apps. The button presses the system media key, so it controls any player |

Older configs have `barWeather`, `barCpu` and similar booleans. They are still read and written as views onto the list, so files round-trip between versions.

## Appearance

| Key | Values |
| --- | --- |
| `barBackground` | `blur` for a translucent material, `glass` for Liquid Glass (macOS 26; a blur before), or a hex colour `RRGGBB` / `RRGGBBAA` |
| `barChipStyle` | `flat` fills for the desktop chips, or `glass` capsules, the active one tinted with `barActiveColor` |
| `glassStyle` | `regular` or `clear` glass, here and on the tabs |
| `barTextColor` | `auto` for the system label colour, or hex |
| `barActiveColor` | `accent` for the system accent, or hex |
| `barBorderColor`, `barBorderWidth` | Border around the bar; width 0 hides it |
| `barRadius` | Corner radius; combine with `barMargin` for a floating pill |
| `barPadding` | Inset of the content from the bar's edges |
| `barMargin` | Horizontal distance from the screen sides; above zero the bar floats |
| `barTopOffset` | Distance from the top edge; 0 sits where the hidden menu bar lives |

Colours are stored without a leading `#`.

## Behaviour

The bar is a non-activating panel kept behind all app windows, so it never covers anything and clicks on it do not steal focus. It refreshes on focus and window changes, every ten seconds for the clock and gauges, and when weather or media updates arrive; refreshes are coalesced and paused while you drag a window.
