# Status bar

One bar per screen at the top edge, where the hidden system menu bar lives. Enable or disable it with `bar`; set its height with `barHeight`. Tiled windows start below it. Set "Automatically hide and show the menu bar" to Always in System Settings › Control Center so the two do not overlap; on a notched MacBook the bar is at least as tall as the notch row.

## Left side

**Desktop chips**, one per workspace of the current macOS desktop. The active one uses `barActiveColor`. Each chip shows one icon per window open there (`barDesktopApps`), in a stable order: an app keeps its slot while it has a window there and newcomers append. Click a chip to switch; drag it to reorder workspaces.

**Active window label**, formatted by `barTitleFormat`. `{app}` and `{title}` are replaced, anything else is printed as is; the app name is bold. With no title, or a title equal to the app name, only the app is shown. The default is `{app}`.

**Cats** roam whatever is free between the left and right content; see [Cats](cats.md).

## Right side: widgets

`barWidgets` is the ordered list of what appears, left to right. Toggle and reorder them in Settings › Widgets.

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
| `media` | Now Playing with a play/pause button | Track info only from Music and Spotify, read through their scripting interfaces while they run; macOS no longer exposes Now Playing to third-party apps. The button presses the system media key, so it controls any player |

Older configs have `barWeather`, `barCpu` and similar booleans. They are still read and written as views onto the list, so files round-trip between versions.

## Appearance

| Key | Values |
| --- | --- |
| `barBackground` | `blur` for a translucent material, or a hex colour `RRGGBB` / `RRGGBBAA` |
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
