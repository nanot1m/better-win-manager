# Troubleshooting

## The app will not open

Releases since 0.25.2 are signed with a Developer ID and notarized; Gatekeeper opens them. An older ad-hoc signed release refuses the first launch of a downloaded copy until you clear the quarantine flag (`xattr -dr com.apple.quarantine /Applications/BetterWM.app`) or right-click the app and choose Open. Builds from `make install` are ad-hoc signed but not quarantined.

## Nothing tiles, or windows do not move

Accessibility permission is missing, or was granted to an ad-hoc signed build (a release before 0.25.2, or one from `make install`), which macOS treats as a different app from a signed release. Open System Settings › Privacy & Security › Accessibility, remove any stale BetterWM entry, add the current one, and relaunch. Signed releases keep the permission across updates.

## A hotkey does nothing

- Check the log for `hotkey ... failed to register`: the combination belongs to macOS. ⌃← / ⌃→ and ⌃1–9 are Mission Control shortcuts; disable them in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.
- Another app may own the combination globally.
- The ⌥Tab switcher is skipped when `switcher` is off.

## A window keeps floating

Windows you untiled by hand stay floating on purpose. Tile it with ⌃⌥T or ⌥-drag, or use Retile (⌃⌥R) to tile everything on the screen. Apps on the ignore list and windows smaller than `smallWindowSize` also float; auto-tiling is off by default, so new windows float until you tile them.

## Something sits in the bottom-right corner

That is a parked window: its app has windows on more than one workspace of this desktop, so the inactive ones are moved to the corner instead of hidden. Switch to its workspace or send it to the current one. If a window is stranded there after a crash, the next launch pulls it back on screen.

## Windows jumped to another desktop, or the desktop switched by itself

Focus-follow reacts only to clicks, ⌘ combinations and Return. If it still happens, the log shows a `focus follows` line with the window that triggered it; include it in a report.

## An app freezes everything for a moment

A hung app (Unity compiling, say) makes Accessibility calls time out. BetterWM gives each call 0.3 s; after the first failure it stops asking the app at all (`is not responding` in the log) and a probe off the main thread, every 2 to 10 seconds, waits for it to answer (`responds again`). Its windows keep their last known state meanwhile, and moves asked of them wait for the next layout pass. Since every Accessibility call runs on a background queue, a slow app only slows its own layout pass; the UI never waits for it.

## After unplugging a monitor

Windows that were parked in the old screen's corner are pulled onto the remaining screen by macOS; BetterWM parks them again, fits remembered frames to the new screen, and gives up after three attempts on a window macOS refuses to move. Visit each workspace once to have its grid relaid for the new screen.

## Reading the log

`~/.config/betterwm/log.txt`, on when `debugLog` is true, rotates at 2 MB. Lines are `HH:mm:ss.SSS [category] message`. Useful categories:

| Category | What it records |
| --- | --- |
| `hotkey`, `popup`, `menu` | Every action you trigger and how |
| `tile`, `layout`, `reconcile` | Tiles, untiles, moves, and windows added to or dropped from a grid |
| `desktop`, `park` | Workspace switches, focus-follow decisions, hide/unhide/park/unpark |
| `adopt`, `restore` | Which workspace a new window joined and why; what was restored from `state.json` |
| `snapshot` | Windows carried from cache while unreadable, and why a tracked window left the snapshot |
| `ax` | Apps skipped for not responding |

## Reporting a bug

The quickest way is BetterWM › Diagnostics › Report a Bug…: it saves the diagnostics report (and, if you agree, a screenshot) into a folder, opens a prefilled GitHub issue and shows the folder so you can drag the files in; nothing is sent until you submit. To do it by hand, use Copy Diagnostics Report in the same menu. It puts the app and macOS versions, screen setup, your config (location redacted), `state.json` and the recent log on the clipboard. Paste it into an issue at https://github.com/nanot1m/better-win-manager/issues together with what you did and what you expected.
