# Troubleshooting

## The app will not open

Releases are ad-hoc signed. Gatekeeper refuses the first launch of a downloaded copy until you clear the quarantine flag (`xattr -dr com.apple.quarantine /Applications/BetterWM.app`) or right-click the app and choose Open. Builds from `make install` are not quarantined.

## Nothing tiles, or windows do not move

Accessibility permission is missing or was granted to an older release. Open System Settings › Privacy & Security › Accessibility, remove any stale BetterWM entry, add the current one, and relaunch. Each release counts as a new app because the signature is ad-hoc.

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

A hung app makes Accessibility calls time out. BetterWM gives each call 0.3 s and then skips the app for five seconds (`is not responding` in the log). Its windows keep their last known state meanwhile.

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

Use Copy Diagnostics Report in the menu (BetterWM › Diagnostics). It puts the app and macOS versions, screen setup, your config (location redacted), `state.json` and the recent log on the clipboard. Paste it into an issue at https://github.com/nanot1m/better-win-manager/issues together with what you did and what you expected.
