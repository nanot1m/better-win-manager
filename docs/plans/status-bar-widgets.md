# Status bar as a list of widgets

The bar is a list of widgets. Each widget owns its data source, its views (one per bar window), its settings and its
refresh triggers. `StatusBar` keeps the list, lays it out and forwards configuration and events.

## Shape

- `BarWidget` (protocol, `Sources/BetterWM/BarWidgets.swift`): `id`, `makeView()` per bar window, `start()` / `stop()`
  for the data source, `apply(config)`, `render(style)` updating every view, `wantsRefresh` callback.
- `BarStyle`: the colours and the configuration a widget renders with.
- `StatusBar` builds one widget object per entry of `barWidgets`, starts the ones in use, stops the rest, and on each
  refresh renders them all after the left side.

## Steps

1. **Right side as widgets** — done. Clock, battery, Wi-Fi, keyboard, CPU, memory, disk, weather, media, sound and the
   menu button moved out of `BarView` into widget types. Services (weather, media, Wi-Fi, sound, the clock timer, the
   input-source observer) live inside the widgets that use them and run only while that widget is in the list.
2. **Left side as widgets** — desktop chips, fullscreen chips and the active window title become `side: .left`
   widgets with a `barLeftWidgets` order. Chip drag-to-reorder, the drop highlight and the chip menu move into the chips
   widget; the bar context carries the manager callbacks they need.
3. **Cats as a widget with a layout rule** — the cats need the free span between the sides and the notch portals;
   they become a free-floating widget positioned after the sides are laid out, reading the spans from the layout.
4. **Settings from a schema** — each widget declares `settings: [Setting]` (key, kind, default, note), stored under one
   namespace per widget; the Widgets page renders the schema under each widget's disclosure. Today's keys stay as
   aliases for two releases.
5. **Config** — the per-widget booleans (`barClock` and friends) go once the alias layer covers old files; unknown ids
   in `barWidgets` are kept so a widget missing in one build does not lose its place.

Steps 2 and 3 are independent of 4 and 5. Risks: the cats' roam range is derived from layout (last); chips are the
most entangled with the manager (the context must carry drag, drop and menu callbacks); renaming config keys needs the
alias layer first.
