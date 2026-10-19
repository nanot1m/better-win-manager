# BetterWM documentation

BetterWM is a column-based tiling window manager for macOS with virtual workspaces and a status bar. These pages go deeper than the top-level [README](../README.md).

| Page | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Install, permissions, the first five minutes |
| [Concepts](concepts.md) | Columns, stacked layout, floating windows, workspaces, how parking and hiding work, what is remembered |
| [Actions and hotkeys](actions.md) | Every action, its default hotkey, the popup, the menu, the switcher |
| [Settings reference](settings.md) | Every key in `config.conf`, the Settings window, import/export, versioning |
| [Status bar](status-bar.md) | Chips, window title, widgets, appearance, weather, Now Playing |
| [Cats](cats.md) | Sprite sheets, behaviour, petting, the notch portals |
| [Troubleshooting](troubleshooting.md) | Permissions, Gatekeeper, system shortcuts, hung apps, reading the log, bug reports |
| [Internals](internals.md) | Architecture, the reconciler, snapshots, SkyLight use, performance rules, releasing |

Files BetterWM writes, all under `~/.config/betterwm/`:

| File | Purpose |
| --- | --- |
| `config.conf` | Settings. Key = value, `#` comments, versioned and migrated on load |
| `state.json` | Saved layouts: grids, floating windows, hidden apps, active workspace per desktop |
| `log.txt` | Action log when `debugLog` is on; rotates at 2 MB |
