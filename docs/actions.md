# Actions and hotkeys

Every action has a key used in `config.conf` as `hotkey.<key> = <modifiers>+<key name>`. Modifiers are `cmd`, `alt`, `ctrl`, `shift`; key names are letters, digits, `space`, `return`, `tab`, `escape`, `left`, `right`, `up`, `down` and punctuation. Comment a line out to unbind. The menu shows whatever you have bound next to each item.

Hotkeys are registered globally with Carbon. A combination macOS already uses, such as ⌃← / ⌃→ or ⌃1–9 for Mission Control, never reaches BetterWM until you disable it in System Settings › Keyboard › Keyboard Shortcuts › Mission Control; a failed registration is noted in the log.

## Windows

| Action | Default | Does |
| --- | --- | --- |
| `popup` | ⌥⌘Space | Window Actions popup, centred on the focused window |
| `toggleTile` | ⌃⌥T | Tile the focused window where it sits, or untile it back to its remembered floating spot |
| `moveLeft` / `moveRight` | ⌃⌥← / ⌃⌥→ | Move to the neighbouring column; at the edge, cycle the column width. A floating window is tiled first |
| `moveUp` / `moveDown` | ⌃⌥↑ / ⌃⌥↓ | Reorder within the column |
| `mergeLeft` / `mergeRight` | ⌃⌥⇧← / ⌃⌥⇧→ | Fold into the neighbouring column |
| `focusNext` / `focusPrevious` | ⌃] / ⌃[ | Cycle focus through the desktop's windows in reading order, tiled or floating |
| `switcher` / `switcherBack` | ⌥Tab / ⌥⇧Tab | ⌘Tab-style strip of all windows grouped by desktop; release ⌥ or press Return to pick, Esc to cancel |

## Screen

| Action | Default | Does |
| --- | --- | --- |
| `retile` | ⌃⌥R | Start the screen's grid afresh and tile every window on it, hand-floated ones included; keeps the layout mode |
| `equalize` | ⌃⌥E | Reset all column widths and row heights to equal weights |
| `toggleStack` | ⌃⌥S | Switch the screen between columns and stacked layout |
| `pause` | unbound | Stop reconciling until pressed again; windows stay where they are |
| `refreshRing` | unbound | Re-measure window corner radii for the focus ring |

## Desktops

| Action | Default | Does |
| --- | --- | --- |
| `desktop1` … `desktop9` | ⌃1 … ⌃9 | Switch; a missing desktop is created |
| `desktopNext` / `desktopPrevious` | ⌃→ / ⌃← | Switch relative to the current one |
| `sendToDesktop1` … `sendToDesktop9` | ⌃⌥1 … ⌃⌥9 | Send the focused window; it is tiled there if it was tiled here |
| `sendToNextDesktop` / `sendToPreviousDesktop` | unbound | Send relative to the current desktop |
| `desktopMoveLeft` / `desktopMoveRight` | unbound | Reorder the current desktop among its neighbours |

Dragging a chip in the status bar also reorders desktops, and ⌥ + scroll wheel switches them.

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
| ⌥-drag a window (`dragModifiers`) | Tile it into the highlighted drop zone; pressing ⌥ partway through a normal drag works too |
| Drag a gap handle | Resize the columns or rows on either side |
| Plain move or resize of a tiled window | Untiles it; the grid reflows |
| ⌥ + scroll | Switch desktop |
| Click a chip | Switch desktop; drag it to reorder |
| Click a cat | Pet it |
