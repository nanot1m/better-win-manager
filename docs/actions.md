# Actions and hotkeys

Every action has a key used in `config.conf` as `hotkey.<key> = <modifiers>+<key name>`. Modifiers are `cmd`, `alt`, `ctrl`, `shift`; key names are letters, digits, `space`, `return`, `tab`, `escape`, `left`, `right`, `up`, `down` and punctuation. Comment a line out to unbind. The menu shows whatever you have bound next to each item.

Hotkeys are registered globally with Carbon. A combination macOS already uses, such as ⌃← / ⌃→ or ⌃1–9 for Mission Control, never reaches BetterWM until you disable it in System Settings › Keyboard › Keyboard Shortcuts › Mission Control; a failed registration is noted in the log.

## Windows

| Action | Default | Does |
| --- | --- | --- |
| `popup` | ⌥⌘Space | Window Actions popup, centred on the focused window |
| `toggleTile` | ⌃⌥T | Tile the focused window where it sits, or untile it back to its remembered floating spot |
| `togglePin` | ⌃⌥P | Pin the focused floating window so it follows to whichever desktop is shown (a tiled one is untiled first), or unpin it; pinned windows share a ⧉ chip in the status bar. The ring button shows only on floating windows |
| `moveLeft` / `moveRight` | ⌃⌥← / ⌃⌥→ | Move to the neighbouring column; at the edge, cycle the column width, or with `moveAcrossDesktops` carry the window to the previous/next desktop. A floating window is tiled first |
| `moveUp` / `moveDown` | ⌃⌥↑ / ⌃⌥↓ | Reorder within the column |
| `mergeLeft` / `mergeRight` | ⌃⌥⇧← / ⌃⌥⇧→ | Fold into the neighbouring column |
| `grow` / `shrink` | ⌃= / ⌃- | Resize the focused window by `resizeStep`: a tiled one takes space from (or gives it to) its neighbours in every direction it has one; a floating one grows around its centre |
| `focusNext` / `focusPrevious` | ⌃] / ⌃[ | Cycle focus through the desktop's windows in reading order, tiled or floating |
| `focusFloating` | ⌃F | Cycle focus through the floating windows on this desktop, pinned ones included |
| `focusLeft` / `focusRight` / `focusUp` / `focusDown` | unbound | i3-style directional focus: the neighbouring column or the window above/below in the column. At the screen edge, left and right go to the neighbouring display, or else to the previous or next desktop of this display (round and round), landing on the window nearest the entry side; up and down wrap within the grid. A floating window picks the nearest window in that direction |
| `switcher` / `switcherBack` | ⌥Tab / ⌥⇧Tab | ⌘Tab-style strip of all windows grouped by desktop; release ⌥ or press Return to pick, Esc to cancel |
| `overview` | unbound; the Mission Control key (F3) when `overviewKey` is on | Desktop overview: every desktop in a strip along the top, the current desktop's windows spread out below. Click a window to focus it, a desktop to switch, drag a window onto a desktop or the + tile to move it; Esc or a click on the backdrop closes. With `overviewGesture` on, a four-finger swipe up opens it and follows your fingers, swipe down closes |

## Screen

| Action | Default | Does |
| --- | --- | --- |
| `retile` | ⌃⌥R | Tile every window on the screen: columns and their stacks stay as arranged, sizes go back to equal shares, hand-floated windows join in columns of their own |
| `equalize` | ⌃⌥E | Reset all column widths and row heights to equal weights |
| `toggleStack` | ⌃⌥S | Switch the screen between columns and stacked layout |
| `toggleZen` | ⌃⌥Z | Zen mode on this screen: one window at a time, centred and at most `zenMaxWidth` wide, the others waiting off screen; focus actions cycle through them, and grow/shrink change the width (all the way to the whole screen). Toggling again restores the layout |
| `toggleTabs` | unbound; a ring button by default | On a columns screen, show or hide the tabs above tiled windows (`tiledTabs`); on a stacked screen, step to the next stacked look (cascade, tabs on top, left, right) |
| `pause` | unbound | Stop reconciling until pressed again; windows stay where they are |
| `refreshRing` | unbound | Re-measure window corner radii for the focus ring |

## Desktops

| Action | Default | Does |
| --- | --- | --- |
| `desktop1` … `desktop9` | ⌃1 … ⌃9 | Switch; a missing desktop is created |
| `desktopNext` / `desktopPrevious` (past the last or first desktop: the neighbouring macOS Space, e.g. a fullscreen app; from a fullscreen Space: back) | ⌃→ / ⌃← | Switch to the next or previous desktop on the same screen |
| `sendToDesktop1` … `sendToDesktop9` | ⌃⌥1 … ⌃⌥9 | Send the focused window; it is tiled there if it was tiled here |
| `sendToNextDesktop` / `sendToPreviousDesktop` | unbound | Send relative to the current desktop |
| `sendToDesktop` | unbound; a ring button by default | A menu of every desktop plus a new one; pick where the focused window goes |
| `desktopMoveLeft` / `desktopMoveRight` | unbound | Reorder the current desktop among its neighbours |
| `desktopToNextScreen` | unbound | Move the current desktop, windows and all, to the next screen, where it stays shown |

Dragging a chip in the status bar also reorders desktops, and ⌥ + scroll wheel switches them. Dragging a window onto a desktop chip in the status bar sends it to that desktop.

## The Window Actions popup

⌥⌘Space opens a modal panel that shows the focused window's neighbours and what each key does. While it is open:

| Key | Action |
| --- | --- |
| ← → ↑ ↓ or H L K J | Move the focused window |
| ⇧← ⇧→ or ⇧H ⇧L | Merge into the left / right column |
| Tab, ⇧Tab | Focus next / previous window (the popup stays open) |
| T | Tile / untile |
| S | Toggle stacked layout on this screen |
| 1–9 | Switch to that desktop |
| ⇧1–9 | Send the focused window to that desktop |
| N, P | Send to the next / previous desktop |
| ⌥1–6 | Apply a layout preset for the windows on this screen |
| Esc | Close |

## The menu

Behind the grid button at the right end of the bar, and behind the menu bar icon when the system bar is visible. Sections: Window, Screen, Desktops, Tiling (pause, auto-tile and its strategy, switcher, overlay), BetterWM (settings, config file, reload, diagnostics). Submenus list all nine desktops, with ones that do not exist yet marked (new).

## Mouse

| Gesture | Does |
| --- | --- |
| ⌥-drag a floating window (`dragModifiers`) | Tile it into the highlighted drop zone; ⌥ only matters while a drag is in progress, so ⌥-clicking stays an ordinary click |
| Drag a tiled window | The same, with or without ⌥: drop it into a zone to move it in the grid, or let go anywhere else and it snaps back to its slot. Untile with `toggleTile` |
| Drag a tiled window's edge | Resize the tiles: the boundary with the neighbour follows; an edge with no neighbour snaps back |
| ⌥ + scroll | Switch desktop |
| Click a chip | Switch desktop; drag it to reorder |
| Click a cat | Pet it |
