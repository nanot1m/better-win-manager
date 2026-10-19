# Internals

## Architecture

Two targets plus tests, buildable with Command Line Tools alone.

- **BetterWMCore** is pure Swift with no AppKit: the model (`Snapshot`, `WindowInfo`, `ScreenInfo`), the `Grid` and its geometry, the `Reconciler`, `SavedLayout` persistence, `Config` parsing and serialisation, layout presets. Everything here is deterministic and covered by `swift run CoreTests`, a plain executable with its own `expect` harness because the toolchain has no XCTest.
- **BetterWM** is the app shell: `SystemObserver` builds snapshots from Accessibility and the window list and executes frame commands; `WindowManager` owns the desired state, runs ticks, and holds the virtual workspace sets; `VirtualWorkspaces` is the per-desktop membership, parking and hiding model; `DragController` is the event tap; `FocusRing`, `StatusBar`, `BarCat`, `WindowSwitcher`, `ActionPopup`, `ConfigEditor` are the UI; `Spaces` and `WindowServerEvents` wrap the private SkyLight calls; `HotKey` wraps Carbon hotkeys.

## The tick

A tick is: take a snapshot (visible windows plus every tracked window, with cached state for ones that are alive but unreadable), assign new windows to workspaces (saved slots first), reconcile each active screen's grid against the snapshot, log changes, schedule a save, apply parking and hiding, pre-position the focus ring, execute the frame commands; up to three passes so windows that refuse a size settle. Ticks run on WindowServer create/destroy events, Accessibility window-created and geometry notifications (never during a drag), focus and Space changes, and a five-second safety timer. Reconciling only ever reads `Snapshot` and `DesiredState`, so the same inputs give the same frames.

The reconciler treats a tiled window as departed only when it is missing from the snapshot or no longer on the space. Departures caused by transient unreadability are prevented upstream: the snapshot keeps the last known state of a window that WindowServer still lists while its app is hidden or unhiding, unresponsive, the screen is locked, or it was read within two seconds.

## Virtual workspaces

Model Space ids encode `(real Space, workspace, screen)` as `1_000_000_000 + real*10_000 + ws*100 + screen`, so grids keyed by them stay stable across launches and the observer can report a window's workspace as its "space". Membership is by window id; dead ids are pruned every tick against the full window list. Parking moves a window to `(maxX-2, maxY-2)` of the nearest screen corner, with a tolerance that accounts for macOS keeping about 44 points of a window on screen; hiding uses `NSRunningApplication.hide`. Reordering remaps every structure keyed by workspace index.

## Private API use

All loaded with `dlsym`, so a removed symbol disables a feature instead of preventing launch:

- `CGSMainConnectionID`, `CGSManagedDisplayGetCurrentSpace`, `CGSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`: which Space a screen shows and a window is on, and whether a Space is fullscreen. Nothing is switched or moved through SkyLight.
- `SLSRegisterNotifyProc`, `SLSRequestNotificationsForWindows`: window move, resize, reorder, level, create, destroy, Space and front-change events. One process-wide callback per event id; notifications only flow after at least one window has been requested, and registering every event id breaks delivery.
- `SLSGetWindowBounds`, `SLSMoveWindow`: cheap frame reads for the focus ring and moving our own ring window without AppKit's layout pass.
- `SLSWindowQueryWindows` and the iterator functions: a window's compositor corner radius for the ring.
- `_AXUIElementGetWindow`: the CGWindowID behind an Accessibility element.

## Performance rules learned the hard way

- The event tap runs on the main run loop. Anything synchronous on the main thread delays every mouse and keyboard event in the system. Window moves during a drag run on a background queue with only the latest position applied; screen geometry and the dragged window's id are resolved once per drag.
- Accessibility calls are IPC into the target app and can take hundreds of milliseconds when the app is busy. Every call has a 0.3 s messaging timeout and a failing app is skipped for five seconds. Nothing per-mouse-move may call into Accessibility; the focus ring follows WindowServer bounds, and the bar's app scan uses the window list alone.
- Accessibility window-moved and window-resized notifications fire for every frame of a drag. They only nudge the ring and schedule a tick, never a focus lookup.
- Bursts (an app opening three windows, a Space switch) are coalesced: one ring update per run-loop pass, one bar refresh per 100 ms, one tick per 150 ms.

## Persistence formats

`config.conf` is key = value with `#` comments; `Config.parse` tolerates unknown keys and `Config.migrate` upgrades older versions. `state.json` is `SavedLayout`, version 2: spaces with columns of (bundle id, title, frame, height weight), floating windows, layout mode; plus hidden pids and the active workspace per desktop. Both are written atomically; the layout save is throttled to once per 1.5 s and skipped when nothing changed.

## Releasing

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`: tests, `make zip` (bundle, ad-hoc sign, zip), a GitHub release with notes taken from the matching `CHANGELOG.md` section, and, when a `TAP_TOKEN` secret exists, an update of the Homebrew cask in `nanot1m/homebrew-tap` with the new version and SHA-256.

Dev flags on the binary: `--settings`, `--snapshot-settings <png>`, `--snapshot-bar <png>`, `--snapshot-hud`, `--snapshot-handle`, `--snapshot-switcher`, `--snapshot-popup`, `--test-record`, `--test-hotkeys`, `--demo <script>`. `make run` builds a debug `.app` (needed for Location Services), `make demo` records `demo/demo.txt`.
