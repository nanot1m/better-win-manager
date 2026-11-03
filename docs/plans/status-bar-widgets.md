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
2. **Left side as widgets** — done. Desktop chips, fullscreen chips and the active window title are widgets with a
   `barLeftWidgets` order, switchable and reorderable in Settings. Chip drag-to-reorder, the drop highlight and the
   chip menu live in the chips widget; `BarContext` carries the manager callbacks.
3. **Cats as a widget with a layout rule** — done. `CatsWidget` owns one `BarCat` per bar and the reactions; its
   view is the bar's `BarFreeView`, handed the free span and the notch gap after each layout. It is switched by
   `barCat`, not by either order list.
4. **Settings from a schema** — done. `Config.BarWidget.settings` describes each widget's settings (config key, title,
   note, kind: toggle, text, auto-or-text); the Widgets page renders them under the widget's disclosure, reading and
   writing through `Config.value(forKey:)` and `Config.set(_:to:)`. The keys stay the existing ones (`barClockFormat`,
   …), so no alias layer is needed; a per-widget namespace can come with step 5 if wanted.
5. **Config** — the per-widget booleans (`barClock` and friends) go once the alias layer covers old files; unknown ids
   in `barWidgets` are kept so a widget missing in one build does not lose its place.

Steps 2 and 3 are independent of 4 and 5. Risks: the cats' roam range is derived from layout (last); chips are the
most entangled with the manager (the context must carry drag, drop and menu callbacks); renaming config keys needs the
alias layer first.
