# Changelog

All notable changes to BetterWM. The format follows [Keep a Changelog](https://keepachangelog.com/); versions are tags on `master`, each with a release zip.

Config (`config.conf`) and layout state (`state.json`) are versioned and migrated on load, so upgrading never loses settings or layouts.

## [0.17.3] - 2026-10-22

### Changed
- Lower idle CPU. The bar asked the Wi-Fi daemon for the network name and signal on every refresh, a synchronous round trip each time; Wi-Fi strength now follows CoreWLAN events. Desktop chips also asked SkyLight for the Space list once per window; once per refresh now.

## [0.17.2] - 2026-10-21

### Fixed
- A tiled window could stay stuck in the parking corner after leaving fullscreen and switching desktops quickly: frames it missed during the fullscreen animation counted as refusals, and the layout stopped moving it. Only a window that did not move at all since the last request counts as refusing now, and requests less than half a second apart (the settle passes of one update) count once, the same rules parking uses.
- A window put into fullscreen was treated as arriving on a new desktop: it lost its workspace and grid slot, was tiled on the fullscreen Space, and came back with that size. It now stays a member of its desktop, keeps its slot, and is left alone until it returns. That includes the moment macOS tears the fullscreen Space down, when the window sits on a Space that is no longer listed.
- A window leaving fullscreen came back too large: while it animated out it was briefly bigger than its slot, and that was learned as its minimum size, so every later slot was built around a screen-sized window. A minimum is learned now only from a window that had time to shrink and stayed exactly the same.

## [0.17.1] - 2026-10-21

### Fixed
- Clicking a control that changes a window's frame by itself (YouTube's fullscreen button, a double-click zoom) untiled the window as if it had been dragged by hand. Only a press that moves the mouse at least 20 points counts now; a plain click also no longer saves the fullscreen frame as the window's floating spot. A shorter drag snaps the window back to its slot on release.

## [0.17.0] - 2026-10-21

### Changed
- The bar's now-playing widget updates the moment Music or Spotify changes track or play state, instead of polling every 3 seconds.
- The bar refreshes once when a drag ends instead of re-checking every 0.1 s during it.

### Fixed
- Two Space switches in quick succession could end the first one's settle period while the second was still sliding.
- Frames a window refused before sleep or lock were still counted against it afterwards; sleep, lock and display changes now clear refusals for both the layout and parking.
- Closed windows left their focus memory, thumbnail and background-adoption marks behind.

## [0.16.6] - 2026-10-21

### Fixed
- Desktop chips showed icons for windows that had been closed: some apps (ChatGPT, Calendar) keep a closed window alive off screen, and a parked window stayed counted as long as it existed. Chips now count only windows present in the latest snapshot.

## [0.16.5] - 2026-10-21

### Fixed
- Closing the lid with an external display attached gathered parked windows on the active desktop: macOS ignored window moves for some 20 seconds while it rearranged the screens, longer than the 15-second grace period, and the ignored moves were counted during it. The grace period is now a minute and nothing is counted while it lasts. The same pause applies while the Mac sleeps, the displays sleep, the screen is locked or another user is active, and for a minute after.

## [0.16.4] - 2026-10-21

### Added
- Diagnostics › Reset Layout State…: brings every window back on screen, deletes the saved grids, floating positions and desktop assignments, and restarts BetterWM. Settings are kept.
- The diagnostics report lists every on-screen window as BetterWM sees it (whether Accessibility lists it, how long the app took to answer, its role), without titles, so a window that cannot be tiled can be diagnosed from one report.

### Fixed
- Pausing tiling was easy to do by accident and hard to notice: the bar's menu button always offered "Pause Tiling", even while paused, and nothing on screen said tiling had stopped. The menu now says "Resume Tiling" while paused, pausing and resuming always flash a notice, and Tile / Untile or Retile Current Screen resume tiling first instead of silently doing nothing.

## [0.16.3] - 2026-10-21

### Added
- Diagnostics › Report a Bug…: collects the diagnostics report and, if you agree, a screenshot into a folder, opens a prefilled GitHub issue and shows the folder so the files can be dragged in. Nothing is sent until you submit the issue.

### Changed
- Release builds redact saved window titles from the state included in the diagnostics report.

## [0.16.2] - 2026-10-21

### Changed
- Release builds no longer write window titles to the log (and so to the diagnostics report); windows are identified by app and window number. Development builds keep titles.

### Fixed
- The ⌥Tab switcher skipped a window: the first press landed two entries in, which with two windows on the desktop meant the next desktop. It now starts on the window after the focused one on the current desktop and only moves to another desktop when there is no other window.

## [0.16.1] - 2026-10-21

### Fixed
- Disconnecting a display could untile windows: macOS moved them while rearranging screens, the jitter guard gave up on them for good, and the next click on such a window counted as a hand move. Refused frames are now asked for again after three seconds and after any display change, and mouse-up only untiles a window that actually moved or resized during the drag.

## [0.16.0] - 2026-10-21

### Fixed
- Connecting or removing a display moved parked windows to the active desktop: macOS ignores window moves while it rearranges screens, which looked like windows refusing to leave. No window is claimed for 15 seconds after a display change, and it now takes five ignored moves rather than three.

### Added
- Sound widget for the status bar: a speaker icon with the output level; click it for output volume and mute, the output device, input volume and the input device; scroll over it to change the volume. Enable it in Settings › Widgets.

## [0.15.3] - 2026-10-21

### Fixed
- A window that refuses the frame it is given no longer jitters: after four identical attempts the reconciler leaves it where it is until the layout changes, and the log names the window.

## [0.15.2] - 2026-10-21

### Changed
- The desktop slide's finishing animation runs in the render server, so the real switch behind it can no longer drop frames.

## [0.15.1] - 2026-10-21

### Changed
- The desktop slide starts and finishes without stalls: the outgoing desktop is one screen image captured in the background the moment the fingers touch the pad, the wallpaper is cached, the incoming desktop is built from the manager's own state without Accessibility, layout passes pause while the slide is up, and the real switch runs in the last 50 ms of the ease-out instead of blocking the animation.

## [0.15.0] - 2026-10-21

### Changed
- Swiping left or right now slides between desktops like Spaces: the current desktop's windows follow your fingers out as previews while the neighbour's slide in, and the real switch happens behind the slide on release. Past the last or first desktop the swipe still moves on to the neighbouring macOS Space. The slide needs the desktop overview, which provides the previews, so the setting is only available with the overview on.
- With the overview open, a horizontal swipe scrubs the overview itself between desktops: the spread-out windows move with the fingers and the neighbour's come in beside them, with the focus ring drawn on the focused window in both the overview and the slide.
- Scroll and gesture events are swallowed while the swipe fingers are down, through the scroll's momentum, and while the overview or slide is up, so a swipe no longer scrolls the window underneath.

## [0.14.2] - 2026-10-21

### Added
- `hideApps` setting (Settings › General › Other desktops): off keeps every window of other desktops parked in the screen corner instead of hiding its app, so the overview can show them live.

## [0.14.1] - 2026-10-21

### Fixed
- With the overview turned off, windows are no longer captured before their app is hidden on a desktop switch, so BetterWM does not count as a screen-recording app unless you use the overview or switcher previews.

## [0.14.0] - 2026-10-21

### Added
- Swipe left and right (three or four fingers, `gestureFingers`) to switch desktops, opt-in with `desktopSwipe`. Past the last or first desktop the swipe moves on to the neighbouring macOS Space, which is how fullscreen apps are reached, and from a fullscreen Space back again. Next/Previous desktop hotkeys do the same.
- Fullscreen apps appear in the status bar after the desktop chips, marked ⛶; clicking one switches to it.
- The finger count for the overview swipe is configurable too; both gestures share Settings › General › Trackpad gestures.

## [0.13.2] - 2026-10-21

### Changed
- The focus ring is drawn above all normal windows instead of being slotted beneath the focused one, so it no longer lags behind raises and unhides or ends up under an overlapping floating window.
- Focus Next / Previous include BetterWM's own Settings and Welcome windows.

### Fixed
- A newly launched app that is slow to answer Accessibility (System Settings) was skipped for five seconds before its window was tracked; starting apps are retried after one second, and the end of any back-off triggers a layout pass.

## [0.13.1] - 2026-10-21

### Changed
- The overview spreads the current desktop's windows into one cell each, Exposé style, whatever the layout, so every window is fully visible.

### Fixed
- Desktops you had not visited showed app icons instead of previews in the overview: windows of hidden apps cannot be captured, so an app's windows are now captured right before it is hidden.

## [0.13.0] - 2026-10-20

### Added
- Desktop overview, Mission Control style: a strip of every desktop along the top and the current desktop's windows spread out below, with window previews. Click a window to focus it, click a desktop to switch, drag a window onto a desktop or the + tile to move it there; Escape or a click on the backdrop closes. New `overview` action; the Mission Control key (F3) opens it by default (`overviewKey`). With `overviewGesture` on, a four-finger swipe up opens it and the animation follows your fingers; swipe down closes.

- Welcome window on first launch, while Accessibility is missing: what each permission is for, with a button to the matching System Settings pane and live status. Reachable later from the menu as Permissions….
- The status bar outlines the focused window's icon in its desktop chip; the colour is configurable (`barFocusOutlineColor`, automatic by default). Chip icons follow the grid order, columns left to right, with floating windows last.
- Switching to a desktop focuses the window that was focused when you last left it.

### Fixed
- Windows of apps that a killed run left hidden lost their desktops on the next launch: they appeared only while the launch tick was already re-reading the screen, skipped the saved layout and landed on the active desktop as floating windows. Every window now passes through the saved layout before anything else claims it, and a window on no Space (hidden) still matches its saved desktop.

## [0.12.12] - 2026-10-20

### Fixed
- Windows of an app with windows on several desktops could reappear on screen after the app was unhidden, yet stay invisible to focus cycling, the focus ring and tiling until the next desktop switch. Parked windows now stay in the corner while their app is hidden, so there is nothing to race when it comes back.
- Re-parking a window that drifted out of the corner is spaced half a second apart and no longer gives up after three quick tries; only a window that ignores the move outright counts as refusing, and after three refusals it joins the active desktop instead of lingering unreachable.

## [0.12.11] - 2026-10-20

### Fixed
- A tiled window nudged by less than the 10pt threshold now snaps back into its slot on drop instead of waiting for the next layout pass.

## [0.12.10] - 2026-10-20

### Changed
- Dragging a tiled window by hand floats it only after it has moved or resized by more than 10 points; smaller nudges snap back into the slot.

## [0.12.9] - 2026-10-20

### Fixed
- A click shortly after switching desktops could untile windows on that desktop: mouse-up released every tiled window that was not yet in its slot, including ones still settling back from the parking corner. Only the window actually dragged is released now.

## [0.12.8] - 2026-10-20

### Changed
- Holding ⌥ no longer turns a click into a BetterWM drag: windows always move through the app's own drag, and ⌥ held at any point during that drag shows the drop zones and tiles on release. ⌥-clicks and ⌥-drags inside a window (such as cloning a Miro widget) reach the app untouched, because zones only appear once the window itself has moved.

## [0.12.7] - 2026-10-20

### Fixed
- Crash after display sleep or monitor hot-plug: CPU tick counters that reset below the previous sample no longer underflow, and screen lookups fall back safely when the display list is momentarily empty. Thanks @vteremasov.
- The drop-zone overlay now moves to the screen the zone is on, so drag previews show on external monitors. Thanks @vteremasov.
- Grid resize helpers guard column and boundary indices, so a stale index after a window closes no longer traps. Thanks @vteremasov.
- ⌥1–9 in the action popup applied presets by keycode; previously the option-modified character never matched. Thanks @vteremasov.
- Cat sprites render at pixel size on Retina displays. Thanks @vteremasov.
- The window switcher reacts to Escape and releasing ⌥ when BetterWM itself is the key app. Thanks @vteremasov.
- Accessibility observers remove their run-loop sources when an app quits, and status bar icons are cached by bundle id so relaunched apps do not show stale icons. Thanks @vteremasov.

## [0.12.6] - 2026-10-20

### Fixed
- A cat held in place while in a walking or running pose (its destination blocked by the notch, or a follower whose slot sits across it) pedalled on the spot; it now stands still and flicks its tail until it actually moves.
- Cats ran at a portal without ever getting through: the leap animation counted as resting, so the step that keeps resting cats out of the notch pushed them straight back out. Leaping cats are left alone.
- Cats could oscillate at a portal mouth when their destination lay inside the notch (a partner or slot sitting right at the edge): destinations inside the notch now snap to its nearer edge, and a cat that animates a run or leap without moving for five seconds is sat down and freed.
- Cats got stuck at a portal mouth: poking a head in switched them into the leap animation, which the poke then treated as "not running" and restarted. Pokes no longer trigger the leap, and any poke still going after six seconds is abandoned.

### Added
- Cats remember you: affection, energy and boredom are saved per cat (`~/.config/betterwm/cats.json`) and restored on launch. Affection fades a little for each day away, and a cat that likes you meows hello when you come back after half a day or more.
- Stroke to pet: rubbing the pointer back and forth over a cat pets it, no click needed.

## [0.12.5] - 2026-10-19

### Fixed
- A cat that leapt through a notch portal could get stuck jumping on the spot afterwards: the leap had no end condition it could meet. It now lands back in its stride as soon as it is clear of the notch.

## [0.12.4] - 2026-10-19

### Changed
- Cats use the whole sprite pack: five sleeping poses picked per nap (lazy cats sprawl), paw licking and both grooming swipes, a standing tail-wag for watching things, paw swipes at the pointer when they catch it and at a portal before poking into it, rearing up on hind legs when the pointer hovers right over them, a meow on the first pet, a happy jump on the third, a hiss when fed up or cornered in a chase, a yawn on waking, a leap through the notch portals, scratching when bored, and a meal by the battery icon when the charger goes in after the battery ran low. Frame counts are read from the sheet, and a sheet missing an extra animation falls back to the nearest core one.
- Cats notice the bar: when you switch desktops the awake ones glance at the new chip and a playful one trots toward it; a low battery makes them huddle by the battery icon; a busy machine makes them sit and stare at the gauges. Before visiting another cat, a cat now stops and looks at it first. With three or more cats one sometimes leads the others in a line. Playful cats poke their head into a notch portal and back a few times before going through. They are sleepier after lunch and livelier in the morning.

### Fixed
- After a desktop switch the focus ring could end up beneath other windows: it was ordered under its window before that window was raised and before hidden apps came back. The ring is re-ordered once those settle.

## [0.12.3] - 2026-10-19

### Changed
- Switching to the desktop that is already active (its hotkey, chip or menu item) cycles focus through its windows instead of doing nothing.

## [0.12.2] - 2026-10-19

### Changed
- The Settings window follows System Settings: a sidebar of sections (General, Tiling, Focus Ring, Status Bar, Widgets, Cats, Apps, Hotkeys) and grouped rows with a plain title, a one-line explanation and the control on the right; switches instead of checkboxes; resizable. All settings and the import/export/save flow are unchanged.

### Added
- Documentation in `docs/`: getting started, concepts, actions and hotkeys, a full settings reference, status bar, cats, troubleshooting and internals.

## [0.12.1] - 2026-10-19

### Fixed
- A config reload or any setting change folded on-demand desktops (5 and up) back into the last configured one, moving their windows there. The configured count is now a minimum; extra desktops go away only once empty.

### Added
- The active workspace of each desktop is remembered and restored at launch.

### Removed
- The workspace count setting (`virtualWorkspaces`): desktops are created on demand and trimmed when empty, so a fixed number served no purpose. The key is accepted and ignored.
- The "glow underneath" focus ring style (`focusRingStyle`); the ring is always an outline. The key is accepted and ignored.

### Changed
- New defaults for fresh installs: status bar on with a black background, white text and orange accents, keyboard/Wi-Fi/battery/clock/menu widgets, app-only window title, 32pt bar with 24pt padding, orange focus ring (6pt, 24pt radius) with a teal ring for floating windows, auto-tiling off. Existing configs are untouched.
- Switch to Desktop and Send to Desktop list all nine desktops; ones that do not exist yet are marked (new) and created when chosen.
- The settings window no longer puts the cursor into the first text field when it opens or when you switch tabs.
- The menu is grouped into Window, Screen, Desktops, Tiling and BetterWM sections, with the diagnostics items in a submenu.
- Menu items, including the Move, Switch to Desktop and Send to Desktop submenus, show the hotkeys you configured instead of made-up ⌘ shortcuts that never worked from the menu bar.

## [0.12.0] - 2026-10-19

### Added
- Homebrew tap: `brew install --cask nanot1m/tap/betterwm`, then clear the quarantine flag as for a downloaded zip. The release workflow updates the cask on every tag.

### Removed
- The native macOS Spaces mode (`workspaces = native`). Virtual workspaces are the only mode now; the `workspaces` config key is accepted and ignored, so older files load unchanged. Gone with it: synthetic Dock-swipe Space switching, the SkyLight window-move bridge vendored from WhichSpace, the title-bar-drag fallback for moving windows between Spaces, and the native/virtual migrations.

## [0.11.20] - 2026-10-19

### Fixed
- Unplugging a monitor left things in a mess: windows parked in the old screen's corner were pulled onto the remaining screen and re-parked in a loop, floating windows came back with the old screen's size, and windows of apps that had been hidden for a while were dropped from their grid when unhidden because the two-second read grace had long expired. Frames remembered on a vanished screen are now fitted to the current one, re-parking gives up after three attempts, and the grace window is kept open for as long as a window is carried for a known reason. When a tracked window does leave the snapshot the log now records why.

## [0.11.19] - 2026-10-19

### Fixed
- A window closed by the user but kept off screen by its app (ChatGPT does this) stayed in the grid and reserved its slot, since 0.11.16 treated any window WindowServer still lists as alive. A window that fails to read is now carried only while there is a reason: it was readable within the last two seconds, its app is hidden or unresponsive, or the screen is locked.

## [0.11.18] - 2026-10-19

### Fixed
- Desktops created on demand (sending a window to desktop 5 with four configured) were not recreated at launch; their saved windows ended up on the last configured desktop. Restoring a window to a higher desktop now creates it.
- Switching to a workspace holding one window of an app whose other windows live elsewhere sometimes showed all of them: the corner move issued while the app was still unhiding was lost. Parked windows found away from the corner are parked again, and a follow-up pass runs shortly after every unhide.

### Added
- Virtual workspaces can be reordered: drag a desktop chip in the status bar to a new slot, or use the Move This Desktop Left/Right menu items and the `desktopMoveLeft`/`desktopMoveRight` actions (unbound by default). Grids, floating windows and saved layouts follow the desktop. Native macOS Spaces cannot be reordered this way.

## [0.11.17] - 2026-10-18

### Changed
- Desktop chips show one icon per window, so an app with two windows on a desktop shows its icon twice (replaces the count badge from 0.11.16).

## [0.11.16] - 2026-10-18

### Added
- Desktop chips show a small count on an app's icon when it has more than one window on that desktop.

### Fixed
- Tiled windows were dropped from their grid ("detached") whenever a snapshot could not read them through Accessibility while they still existed: an app hidden for an inactive workspace being unhidden, a hung app in its cooldown, a locked screen. The snapshot now keeps the last known state of any tracked window WindowServer still lists, so a transient read failure no longer untiles it. Thanks to @clbagrat for the diagnostics.

## [0.11.15] - 2026-10-17

### Fixed
- App icons on the desktop chips shuffled whenever focus changed, because they followed window z-order. Each desktop now keeps a stable order: apps hold their slot while they have a window there and new ones append.

## [0.11.14] - 2026-10-16

### Added
- Status bar: the active window label is formatted by `barTitleFormat` (default `{app} — {title}`; Settings › Bar › Window title).
- Status bar: a Now Playing widget (off by default; enable in Settings › Widgets) showing the current Music or Spotify track with a play/pause button. The button presses the system media key, so it also controls other players; track info is read only from Music and Spotify, since macOS no longer exposes Now Playing to third-party apps.

### Fixed
- Floating windows of apps hidden for an inactive workspace were not saved, so they lost their workspace on relaunch. Every window a workspace knows is now part of the snapshot and the saved layout.
- Closed windows stayed in the workspace bookkeeping, so a desktop chip kept showing an app that had no window there, and after an app restarted (Chrome updating itself) the old and new processes both showed. Dead windows are now pruned every tick.
- When an app restarts mid-session (an update), its windows reopened on the active workspace. Windows of an app launched in the last 15 seconds are matched against the latest saved layout by exact title and sent back to the workspace they were on.
- Switching workspaces sometimes left Finder frontmost with no window: hiding the departing app let macOS pick the next one. The destination workspace's top app is activated first; an empty workspace activates BetterWM itself instead.

## [0.11.13] - 2026-10-16

### Fixed
- The menu widget's click area was only as big as its icon; it now spans the bar height and a wider margin.

## [0.11.12] - 2026-10-16

Config schema is now version 3 (adds the menu widget to saved widget lists); older files are migrated on load.

### Fixed
- Retile (ctrl+alt+r, Tile All Windows in the menu) tiles hand-floated windows on that screen again; since 0.11.8 they were skipped as deliberately floating.

### Added
- Status bar: the notch portals are a setting (`barNotchPortals`, Settings › Bar); off, cats stay left of the notch. A long window title no longer runs up to the notch and traps the cats there: room is reserved for them, and if there is none they live right of the notch.
- Status bar: a BetterWM menu widget (grid icon, last on the right by default) that opens the app menu on click. Toggle or move it in Settings › Widgets.
- Focus ring: a separate colour for a focused floating (untiled) window (`focusRingFloatingColor`, default "same"; Settings › General › Focus Ring › Floating).

### Changed
- Cats have drives and personalities. Energy, boredom and affection move slowly with what each cat does and decide its next pose instead of a dice roll: tired cats nap (longer if lazy), bored playful cats run or start a chase, petted cats groom and seek company. Each cat's temperament is seeded from its sprite sheet, so the same cat behaves the same every launch. Two-cat scenes are now started by a cat and pick the nearest partner, with the kind of scene following the mood: cuddle when tired, grooming when affectionate, chase when bored.
- Hunting the pointer is by interest: playful or well-petted cats join, others carry on (one always humours you), and interest fades after a while. When the pointer leaves, interested cats stroll to where it was and look for it.
- Petting: a sleeping cat wakes and looks around; three pets in a row make it lie down purring; too many and it walks off, a little offended.

## [0.11.11] - 2026-10-16

### Fixed
- Notch portals were drawn over the cats; cats now pass in front of the portal ovals.

## [0.11.10] - 2026-10-16

### Added
- Status bar widgets have their own Settings tab: tick to show, arrows to reorder. The order is stored as `barWidgets` (comma-separated: weather, cpu, memory, disk, keyboard, wifi, battery, clock); the old `barWeather`/`barCpu`/… flags are still read and written so older configs and older versions keep working. The clock can now be hidden too.
- Cats are interactive: hover the empty part of the bar and they run over to catch the pointer, sitting side by side when they get there; click a cat to pet it (it grooms or lies down, with a heart).
- Cats cross the notch through a pair of Portal-style portals, blue on the left and orange on the right, lit only while a cat is passing. The part of the cat that has gone into one edge comes out of the other, so it never disappears.

### Changed
- Move Left/Right/Up/Down and Merge now work on a floating window: it is tiled where it sits first, then moved. The popup and menu no longer grey these out for floating windows.

### Fixed
- Apps hidden for inactive workspaces stayed hidden when BetterWM was killed (SIGTERM, as `pkill` or `make run` do) rather than quit. SIGTERM now runs the normal quit path, and the set of hidden apps is saved so a launch after a crash unhides them first.

## [0.11.9] - 2026-10-16

### Changed
- Virtual workspaces: an app whose windows all live on inactive workspaces is now hidden with the native Hide instead of being moved to the screen corner, where a sliver of each window stayed visible. Only apps with windows on several workspaces of the same desktop still park the inactive ones in the corner. Hidden windows keep their real frames, stay in the ⌥Tab switcher and the desktop chips, and the app is unhidden the moment one of its windows' workspaces becomes active. Quitting unhides everything.

### Fixed
- Idle CPU (about 2%): a full Accessibility snapshot of every window ran once a second, and the focus ring re-resolved focus once a second, whether or not anything had changed. Both now react to WindowServer and Accessibility events, with 5-second safety timers. Idle main-thread work dropped by about two thirds in sampling; what remains is mostly the pixel cat animation (`barCat = false` removes it).

## [0.11.8] - 2026-10-16

### Fixed
- Virtual workspaces: floating windows came back after a relaunch on the wrong workspace, stuck in the parking corner. Their workspace and real frame are now saved in state.json and restored on launch, and they stay floating instead of being tiled as new windows (native desktops too); quitting unparks everything first; a window still found stranded in a corner is pulled back on screen.
- Virtual workspaces: a window untiled by hand was tiled again after leaving and returning to its workspace, because parking hid it from the desktop's known set and it came back as a new arrival. Hand-untiled windows now stay floating until tiled again.
- Menu toggles (Auto-tile New Windows, the strategy, ⌥Tab switcher, action overlay) were not written to the config and reset on relaunch.
- ⌥-dragging a window lagged. Profiling under a synthetic drag found the main thread, where the event tap runs, blocked by Accessibility round-trips per mouse move: the Accessibility observer treated every window-moved and window-resized notification as a focus change (two focus lookups and a status bar refresh each); the focus ring did a full focus lookup for moves of windows other than the ringed one; the status bar's per-desktop app scan went through Accessibility for every window; the dragged window's ID was re-resolved per move; and the window itself was moved with synchronous calls inside the tap. Moves now run off-thread with only the latest position applied, moved/resized notifications only nudge the ring (and not during a drag), the app scan uses the window list alone, bar refreshes wait until the drag ends, and screens and the window ID are resolved once per drag.

### Added
- A window dragged or resized by hand (without ⌥) that ends up floating remembers that spot, so toggling tiling off later returns it there. ⌥-dropping into a zone keeps the pre-drag position as the floating spot.

## [0.11.7] - 2026-10-16

### Added
- Toggling tiling off for the focused window puts it back where it floated before it was tiled by hand (⌥-drop or the toggleTile action).
- Status bar: each desktop chip shows the icons of the apps open there (`barDesktopApps`, on by default; toggle in Settings › Bar).

## [0.11.6] - 2026-10-15

### Fixed
- Virtual workspaces: the desktop flipped back and forth when two apps fought over focus (Unity grabbing it after a compile while you typed in another app). Focus is now followed only after input that can bring an app forward (a click, a ⌘ combo such as ⌘Tab, or Return), and each such input allows a single follow. Diagnosed from @clbagrat's recording.

## [0.11.5] - 2026-10-15

### Fixed
- Virtual workspaces: an app recreating its only window (Unity on scene reload or Play mode) had no sibling windows to follow, so the new window still landed on the active workspace. Each app's last workspace is now remembered and used instead; only a window the frontmost app opens right after user input joins the active workspace. A window placed on a background workspace this way no longer pulls focus (and the desktop) there when its app focuses it. Thanks again to @clbagrat for the follow-up.

## [0.11.4] - 2026-10-15

### Fixed
- Copy Diagnostics Report (and the demo runner) left the action overlay switched on; confirmations now flash without changing the setting.

## [0.11.3] - 2026-10-15

### Fixed
- Virtual workspaces: a window opened by an app that isn't frontmost (Unity recreating its editor window, a background app opening a document) now joins the workspace holding the app's other windows instead of the active one, so it no longer appears on your desktop out of nowhere.
- Focus-following switches workspaces only after user input (⌘Tab, Dock, a click); an app activating itself after a build no longer yanks you to its workspace.
- Saved layouts record parked windows at their real slot rather than the off-screen parking position. Thanks to @clbagrat for the report.

## [0.11.2] - 2026-10-15

### Added
- **Re-measure Window Corners** (menu, `refreshRing` action) recalculates every focus-ring corner radius; radii are also re-measured automatically when a window is resized.

### Fixed
- Retile Current Screen keeps the screen's stacked layout mode.

## [0.11.1] - 2026-10-15

### Fixed
- A hung app no longer freezes BetterWM. Accessibility calls are synchronous with a default timeout of about 6 s; every element now uses a 300 ms timeout, an app that times out is skipped for 5 s (logged), and its windows keep their place in the layout meanwhile. Thanks to @clbagrat for the report.

## [0.11.0] - 2026-10-15

### Added
- Action log at `~/.config/betterwm/log.txt` covering hotkeys, popup and menu actions, tiles, drops and releases, desktop switches and sends, reconcile changes and parking (`debugLog`).
- Menu: **Open Log File** and **Copy Diagnostics Report** (versions, screens, config with location redacted, state and recent log) for bug reports.

### Changed
- Stacked layout: windows keep their deck positions; focusing only raises. Move Left/Right reorder the deck.
- Stacked layout mode is saved per desktop, including for screens with no windows.
- Focus ring stays beneath its window, so clicks no longer re-stack it (and no longer flash), and it stays visible during drags.

### Fixed
- Tiling or dropping a window that belonged to another virtual workspace left it parked off-screen.
- Clicks in Electron apps (VS Code) made the ring blink: transient nil focus is tolerated and a press must move 4 pt before it counts as a drag.

## [0.10.0] - 2026-10-15

### Added
- Stacked (cascade) layout mode per screen: windows get almost the whole screen, shifted right by `stackOffset`; toggle with ⌃⌥S, the popup's S key or the menu; `stackScreensNarrowerThan` starts narrow screens stacked.
- Focus ring and status bar hide during Show Desktop.

### Changed
- WindowServer events go through one shared hub; SkyLight keeps a single callback per event, so separate subscribers used to steal each other's events.

## [0.9.2] - 2026-10-15

### Changed
- Full default hotkey set: ⌃] / ⌃[ focus, ⌃⌥ arrows move, ⌃⌥⇧ ←/→ merge, ⌃⌥T tile, ⌃⌥R retile, ⌃⌥E equalize, ⌃←/⌃→ and ⌃1–9 desktops, ⌃⌥1–9 send. The ⌃-arrow and ⌃-digit bindings require disabling Mission Control's own shortcuts.
- Hotkey recorder: Escape keeps the current binding; Delete clears it.

## [0.9.1] - 2026-10-15

### Changed
- Focus ring moves go straight to WindowServer (`SLSMoveWindow`); when the layout moves the focused window the ring is placed in the same pass, and on workspace switches it appears together with the windows.

## [0.9.0] - 2026-10-15

### Added
- Schema versions for `config.conf` and `state.json` with migrations on load.

### Changed
- **Virtual workspaces are the default**, and every macOS desktop now has its own independent set (active workspace, membership, grids). Switching modes no longer moves windows between Spaces.

## [0.8.1] - 2026-10-15

### Added
- Moving a lone edge column into the edge again cycles its width through 1/3, 1/4, 2/3, 1/2.
- Settings: Import… and Export….

## [0.8.0] - 2026-10-15

### Added
- ⌥Tab window switcher in ⌘Tab style, grouped by desktop with dividers and titles; ⌥⇧Tab backwards, Escape cancels, items clickable; optional window previews (`switcherThumbnails`); `switcher` toggle.
- Status bar shows the current keyboard layout (`barInputSource`).
- Virtual workspaces are created on demand when sending or switching to a higher number; trailing empty ones are trimmed.

### Changed
- Focus next/previous cycles floating windows too, in reading order.
- Focus ring hidden across virtual switches; `focusRingFloating` defaults to on.

## [0.7.0] - 2026-10-15

### Added
- Virtual workspaces mode (`workspaces = virtual`): N desktops emulated on one Space by parking other workspaces' windows just off the bottom-right corner; instant switching; focusing a parked window switches to its workspace; windows and grids migrate when switching modes.

### Fixed
- Cats stuck running in place when cornered; bystanders frozen during scenes.

## [0.6.1] - 2026-10-15

### Added
- `--demo` replays a step-per-line script with simulated cursor drags; `make demo` records it.

### Changed
- Status bar and focus ring hide on fullscreen Spaces.

## [0.6.0] - 2026-10-15

### Added
- Layouts are saved to `state.json` and restored on launch by matching windows to their old slots by app, title and frame (`restoreLayouts`).
- Multiple cats (`barCatSheets`), each with its own sprite sheet or the built-in one; pairs chase, sit, groom and nap together.

## [0.5.4] - 2026-10-15

### Added
- Settings: file picker and itch.io link for cat sprite sheets; settings pages scroll.

## [0.5.3] - 2026-10-15

### Added
- Status bar: CPU load, memory used and free disk (`barCpu`, `barMemory`, `barDisk`); percentages keep a stable two-digit width.

## [0.5.2] - 2026-10-15

### Added
- `barCatSheet`: optional sprite sheet in Last tick's "Pixel Cats 64x64" layout (never bundled).

### Changed
- Gap handles stack above the focus ring.

## [0.5.1] - 2026-10-15

### Added
- Pixel cat wandering the status bar with walk, run, sit, groom, sleep and stretch behaviours (`barCat`).
- `barBatteryPercent` toggles the battery percentage text.

## [0.5.0] - 2026-10-15

### Added
- Status bar: battery and Wi-Fi signal.

### Fixed
- Desktop chips in the bar now respond to a single click.

## [0.4.2] - 2026-10-15

### Changed
- Gap handles draw as a centred grip pill, solid with a guide line while dragging.
- Status bar sits behind app windows; configurable active desktop colour (`barActiveColor`).

### Fixed
- Crash on misaligned WindowServer event payloads.

## [0.4.1] - 2026-10-15

### Fixed
- Gap handles painted over floating windows.

## [0.4.0] - 2026-10-15

### Added
- Status bar under the auto-hidden menu bar: desktops, active window, weather (Open-Meteo, Location Services or fixed coordinates), clock; notch-aware; appearance options (background, text, border, radius, padding, margins, top offset); Settings › Bar.
- `make run` builds a signed debug `.app`.

### Fixed
- Colours are stored without a leading `#`; the parser previously read `#RRGGBB` as a comment, which lost the focus ring colour on relaunch.

## [0.3.2] - 2026-10-15

### Added
- Focus ring matches each window's own corner radius (`focusRingAutoRadius`); `focusRingFloating` rings untiled windows too.

### Changed
- Existing windows are tiled on first sight by default again (`tileExistingOnStart`); send-to-desktop items merged into one submenu.

## [0.3.1] - 2026-10-15

### Added
- Action overlay HUD showing the pressed hotkey and action (`actionOverlay`), for demos.
- MIT license.

### Changed
- Focus ring driven by WindowServer move/resize/front-change notifications instead of polling; layer-backed; no appearance animations on overlays.

## [0.3.0] - 2026-10-14

### Changed
- Layout engine rewritten as a pure reconciler over an intermediate representation (`BetterWMCore`): a `Snapshot` of the system plus the `DesiredState` yields frame commands; the app is a thin shell. Comes with an executable test suite.
- Minimum window sizes are learned only when a window ignores a requested frame; visible windows are matched to Accessibility by window ID.

### Fixed
- Crash when re-registering hotkeys; sending a tiled window reflows both desktops.

## [0.2.1] - 2026-10-14

### Added
- Layout presets in the popup (columns, main + stack, 2/3 + 1/3, 1/3 + 2/3, grid, stack), ⌥1–⌥6.
- `tileExistingOnStart` option.

### Fixed
- Desktop switches no longer retile; hotkey recording via the event tap so system-reserved combos record; one Carbon handler dispatching by ID (every binding fired the first action).

## [0.2.0] - 2026-10-14

### Added
- Configurable focus ring (outline or glow underneath).
- Send focused window to next/previous/specific desktop via SkyLight's bridged move (vendored from WhichSpace, MIT).

### Fixed
- Settings window opens on the active desktop.

## [0.1.0] - 2026-10-14

### Added
- Column-based tiling by ⌥-drag with highlighted drop zones; stacking within columns; draggable gap handles; configurable gaps.
- One grid per macOS desktop; auto-tiling of new windows with placement strategies (rightmost, leftmost, position, next to focused, stack below focused, auto split, spiral); ignore list and small-window rule.
- Window actions popup, global hotkeys, menu bar menu, settings window, `config.conf`.
- Instant desktop switching via a synthetic Dock swipe; ⌥-scroll to switch.
- Ad-hoc signed app bundle and GitHub release workflow.

[0.11.4]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.4
[0.11.3]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.3
[0.11.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.2
[0.11.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.1
[0.11.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.11.0
[0.10.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.10.0
[0.9.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.2
[0.9.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.1
[0.9.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.9.0
[0.8.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.8.1
[0.8.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.8.0
[0.7.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.7.0
[0.6.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.6.1
[0.6.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.6.0
[0.5.4]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.4
[0.5.3]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.3
[0.5.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.2
[0.5.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.1
[0.5.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.5.0
[0.4.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.2
[0.4.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.1
[0.4.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.4.0
[0.3.2]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.2
[0.3.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.1
[0.3.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.3.0
[0.2.1]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.2.1
[0.2.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.2.0
[0.1.0]: https://github.com/nanot1m/better-win-manager/releases/tag/v0.1.0
