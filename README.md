# BetterWM

Column-based tiling window manager for macOS, driven by ⌥-drag.

## Run

```sh
swift build && .build/debug/BetterWM
```

Grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility), then relaunch.

## Use

- Hold ⌥ and drag any window. Drop zones highlight as you move:
  - left/right half of a window → new column on that side
  - top/bottom half of a window → stack above/below it
- Drag the bar in a gap between columns or stacked windows to resize them.
- Move or resize a tiled window normally and it leaves the grid; the others reflow.

## Config

`~/.config/betterwm/config.json` (created on first run):

```json
{ "gap": 16, "outerGap": 16, "handleWidth": 16 }
```
