# Concepts

## Columns and the grid

Each screen has a grid: a row of columns, each holding one or more windows stacked vertically. Column widths and the heights within a column are weights, so resizing one shares the change with its neighbours. Gaps (`gap`) and the margin to the screen edge (`outerGap`) are constant.

A window is either **tiled** (in the grid, placed by BetterWM) or **floating** (left where it is). Tiling never resizes a window below the minimum it refuses to go under; such minimums are learned when a window ignores a requested size and the layout distributes space around them.

Move actions reorder the grid: Move Left/Right carries a window to the neighbouring column (or past the edge, where it cycles through a few widths), Move Up/Down reorders within a column, Merge Left/Right folds a window into the neighbouring column. Equalize resets all weights.

## Stacked layout

Per screen, as an alternative to columns. Windows keep their deck positions; focusing one only brings it to the front, Move Left/Right reorder the deck. Toggle it with ⌃⌥S, the popup's S key, or the menu; toggling it off brings the columns back as they were, windows that arrived meanwhile in columns of their own. `stackScreensNarrowerThan` starts narrow screens in this layout.

How a stacked screen looks is `stackStyle`, tabs along the top by default: a **cascade**, where every window gets almost the whole screen and each is shifted right by `stackOffset` so the ones behind stay visible as strips you can click; or **tabs**, where the front window fills the whole screen behind a row of folder-style tabs along the top (`tabsTop`) or sideways down the left or right edge (`tabsLeft`, `tabsRight`, top to bottom), and the others wait off screen at the same size until their tab is clicked. The focused window's tab is the one in the accent colour; clicking a tab brings that window to the front. Dropping a dragged window along the strip picks its deck position. Tabs show `tabTitleFormat`; double-click a tab (or right-click it and choose Rename Tab) to give it a name of your own, which replaces the title and is saved with the layout. The same menu sends the window to another desktop and picks the stacked look; on a tab above a tiled window it hides the tabs again. An empty name, or Use Window Title in the menu, goes back to the title.

## Floating windows

Panels such as file pickers and alerts are not windows to BetterWM at all: they get no ring, no slot and no tab (they call themselves standard windows but have no close button, which is the tell). Windows float when you untile them, when their app is on the ignore list, when they are smaller than `smallWindowSize` (dialogs), or when auto-tiling is off. A window you untile by hand stays floating until you tile it again, even across workspace switches and relaunches. A floating window stays on its desktop, parked like tiled windows when that desktop is not shown, unless you pin it (`togglePin`, ⌃⌥P): a pinned window stays where it is on its display whichever desktop you switch to there, and has a chip of its own in that display's bar. Drag it to another display to pin it there instead. `autoPinFloating` pins every window that starts out floating; tiling a pinned window unpins it, and so does sending it to a desktop, where it then floats. Toggling tiling off puts the window back where it floated before, and a drag by hand of a floating window settles its new spot. A tiled window never leaves the grid by dragging: it drops into another slot or snaps back.

## Workspaces

Workspaces are numbered across all screens, and each lives on one display: every screen shows one of its own at a time, and each screen's bar lists the ones living there. ⌃1…⌃9 always mean the same workspace; switching to one shows it on its screen. ⌃→ and ⌃← move through the workspaces of the current screen. "Send this desktop to the next screen" moves the current workspace, windows and all, to the next display.

A workspace remembers its display: when that display is unplugged its workspaces show on the main display, and they go back when it returns. Which display is main follows System Settings; making another display main does not move any workspace, only where new ones and those of a missing display go. A display that arrives with no workspace of its own gets a new one. macOS itself should have a single desktop shared by all displays ("Displays have separate Spaces" off); BetterWM gives each display its own set.

Workspaces are created on demand, on the main display, when you switch to or send a window to one that does not exist yet, and trimmed when they end up empty and not shown. The chips in the bar can be dragged to reorder them; grids, floating windows and saved state follow.

Switching is instant because nothing moves through macOS Spaces. Instead:

- An app whose windows all live on inactive workspaces is **hidden** with the native Hide. Its windows keep their frames.
- An app with windows on several workspaces of the same desktop has the inactive ones **parked** just off a corner of their screen that faces no other display, since Hide is app-wide.
- Switching unparks what belongs to the new workspace, and activates its top app so focus does not fall to Finder.

Hidden and parked windows still appear in ⌘Tab; choosing one there switches to its workspace. That is the general rule: focus-follow only reacts to input that can bring an app forward, a click, a ⌘ combination or Return, and each such input allows a single follow. An app activating itself after a build never pulls you anywhere.

New windows join the active workspace when the frontmost app opened them right after your input. A window of a background app goes to the workspace that holds the app's other windows, or where its last window was, so a tool recreating its editor window does not land on your desktop.

## What is remembered

`state.json` holds, per workspace: the grid with each window's app, title and frame; floating windows with their frames; and the layout mode. Per desktop it holds the active workspace, and globally the apps BetterWM has hidden.

On launch, windows are matched to saved slots by app and title, then by nearest frame, and placed in their workspace. Frames remembered on a screen that has since gone are fitted to the current one. An app that restarts mid-session (an update) has its windows matched by exact title for fifteen seconds after launch, so they return to the workspaces they were on. Quitting unparks everything first.

A tracked window that is temporarily unreadable through Accessibility, because its app is hidden or unhiding, hung, or the screen is locked, keeps its last known state instead of dropping out of its grid. A window its app merely keeps off screen after you closed it does leave.

## Focus ring

An outline drawn just beneath the focused window, following it through WindowServer events rather than polling, with the window's own corner radius when it can be measured. Floating windows can have their own colour.
