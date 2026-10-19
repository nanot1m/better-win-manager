# Concepts

## Columns and the grid

Each screen has a grid: a row of columns, each holding one or more windows stacked vertically. Column widths and the heights within a column are weights, so resizing one shares the change with its neighbours. Gaps (`gap`) and the margin to the screen edge (`outerGap`) are constant.

A window is either **tiled** (in the grid, placed by BetterWM) or **floating** (left where it is). Tiling never resizes a window below the minimum it refuses to go under; such minimums are learned when a window ignores a requested size and the layout distributes space around them.

Move actions reorder the grid: Move Left/Right carries a window to the neighbouring column (or past the edge, where it cycles through a few widths), Move Up/Down reorders within a column, Merge Left/Right folds a window into the neighbouring column. Equalize resets all weights.

## Stacked layout

Per screen, as an alternative to columns. Every tiled window gets almost the whole screen and each is shifted right by `stackOffset`, so the windows behind stay visible as strips you can click. Windows keep their deck positions; focusing one only brings it to the front, Move Left/Right reorder the deck. Toggle it with ⌃⌥S, the popup's S key, or the menu. `stackScreensNarrowerThan` starts narrow screens in this layout.

## Floating windows

Windows float when you untile them, when their app is on the ignore list, when they are smaller than `smallWindowSize` (dialogs), or when auto-tiling is off. A window you untile by hand stays floating until you tile it again, even across workspace switches and relaunches. Toggling tiling off puts the window back where it floated before, and a drag or resize by hand that ends untiled settles a new floating spot.

## Workspaces

Every macOS desktop (Space) gets its own independent set of workspaces: its own active one, window membership, grids, chip order. Nothing crosses between macOS desktops. Workspaces are created on demand, when you switch to or send a window to one that does not exist yet, and trimmed when they end up empty and inactive. The chips in the bar can be dragged to reorder them; grids, floating windows and saved state follow.

Switching is instant because nothing moves through macOS Spaces. Instead:

- An app whose windows all live on inactive workspaces is **hidden** with the native Hide. Its windows keep their frames.
- An app with windows on several workspaces of the same desktop has the inactive ones **parked** just off the bottom-right corner of their screen, since Hide is app-wide.
- Switching unhides and unparks what belongs to the new workspace, and activates its top app so focus does not fall to Finder.

Hidden and parked windows still appear in ⌘Tab; choosing one there switches to its workspace. That is the general rule: focus-follow only reacts to input that can bring an app forward, a click, a ⌘ combination or Return, and each such input allows a single follow. An app activating itself after a build never pulls you anywhere.

New windows join the active workspace when the frontmost app opened them right after your input. A window of a background app goes to the workspace that holds the app's other windows, or where its last window was, so a tool recreating its editor window does not land on your desktop.

## What is remembered

`state.json` holds, per workspace: the grid with each window's app, title and frame; floating windows with their frames; and the layout mode. Per desktop it holds the active workspace, and globally the apps BetterWM has hidden.

On launch, windows are matched to saved slots by app and title, then by nearest frame, and placed in their workspace. Frames remembered on a screen that has since gone are fitted to the current one. An app that restarts mid-session (an update) has its windows matched by exact title for fifteen seconds after launch, so they return to the workspaces they were on. Quitting unparks and unhides everything first; a run that was killed leaves a record of hidden apps so the next launch can unhide them.

A tracked window that is temporarily unreadable through Accessibility, because its app is hidden or unhiding, hung, or the screen is locked, keeps its last known state instead of dropping out of its grid. A window its app merely keeps off screen after you closed it does leave.

## Focus ring

An outline drawn just beneath the focused window, following it through WindowServer events rather than polling, with the window's own corner radius when it can be measured. Floating windows can have their own colour.
