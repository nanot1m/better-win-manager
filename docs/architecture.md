# Architecture

Diagrams of how BetterWM is put together. [Internals](internals.md) explains the rules; this page shows the shape.

## Targets and modules

Two targets: `BetterWMCore` is pure Swift with no AppKit and no system calls, which is what makes it testable; `BetterWM` is the app, which talks to macOS.

```mermaid
flowchart TB
    subgraph Core["BetterWMCore (pure, tested)"]
        Model["Model<br/>WindowInfo · ScreenInfo · Snapshot · Command"]
        Grid["Grid · GridGeometry<br/>columns, weights, zones, resizing"]
        Reconciler["Reconciler · DesiredState<br/>arrivals, departures, min sizes, refusals"]
        VW["VirtualWorkspaces<br/>desktops, homes per display, parking"]
        Parking["Parking<br/>corner clear of other displays"]
        DragRules["DragRules<br/>drop / release / snap back"]
        Config["Config<br/>parse, serialize, migrate, actions"]
        Persistence["SavedLayout<br/>state.json, restore by title"]
        Presets["LayoutPreset"]
    end

    subgraph App["BetterWM (AppKit, SkyLight, Accessibility)"]
        direction TB
        WM["WindowManager<br/>the one owner of state"]
        SO["SystemObserver<br/>snapshots on AX.queue"]
        AX["AXWindow · AXResponsiveness · AX.queue"]
        Spaces["Spaces · CGWindowInfo<br/>SkyLight, window list"]
        WSE["WindowServerEvents<br/>move/reorder/create events"]
        WO["WindowObserver<br/>AX notifications per app"]
        Drag["DragController<br/>event tap, own thread"]
        HotKey["HotKey (Carbon)"]
        Gestures["SwipeGesture (multitouch)"]
        subgraph UI["UI"]
            Bar["StatusBar · BarCat"]
            Ring["FocusRing"]
            Overlay["ZoneOverlay · HandleWindow"]
            Overview["Overview"]
            Slide["DesktopSlide"]
            Switcher["WindowSwitcher"]
            Popup["ActionPopup · ActionHUD"]
            Settings["ConfigEditor · Onboarding"]
        end
        Main["main.swift (AppDelegate)<br/>wiring, menu, actions"]
    end

    WM --> Reconciler
    WM --> VW
    WM --> Grid
    WM --> Persistence
    WM --> Parking
    WM --> SO
    SO --> AX
    SO --> Spaces
    AX --> Spaces
    WM --> WSE
    WM --> WO
    Drag --> DragRules
    Drag --> WM
    Main --> WM
    Main --> HotKey
    Main --> Gestures
    Main --> UI
    UI --> WM
    Settings --> Config
    WM --> Config
```

## Threads and queues

Nothing on the main thread waits for another app. Every Accessibility message runs on one serial queue; the event tap has its own thread; the main thread reads only what the last snapshot published.

```mermaid
flowchart LR
    subgraph TapThread["betterwm.eventtap thread"]
        Tap["CGEvent tap callback<br/>pass or swallow from flags"]
    end
    subgraph MainThread["main thread"]
        WMm["WindowManager<br/>reconcile, parking, UI"]
        UIm["bar, ring, overview, switcher…"]
        Pub["published: handles, infos, focused"]
    end
    subgraph AXQueue["AX.queue (serial)"]
        Take["take snapshot<br/>visibleWindows, tracked, focused"]
        Exec["execute commands<br/>setFrame, raise"]
        Hit["hit test, refreshFocused"]
    end
    subgraph Probe["betterwm.axprobe"]
        Pr["probe a silenced app<br/>2 s → 10 s backoff"]
    end
    Apps["other apps (AX IPC)"]

    Tap -- "copy of event, async" --> WMm
    WMm -- "refreshState()" --> Tap
    WMm -- "snapshot(tracked:)" --> Take
    Take -- "completion" --> Pub --> WMm
    WMm -- "execute(_:)" --> Exec
    WMm -- "hitTest / refreshFocused" --> Hit
    Take & Exec & Hit -- "0.3 s timeout" --> Apps
    Apps -. "timed out: noteFailure" .-> Pr
    Pr -- "answers again: onBackoffEnd" --> WMm
    UIm -- "cached reads only" --> Pub
```

## One layout pass (`tick`)

```mermaid
sequenceDiagram
    participant E as Event source<br/>(AX notification, WindowServer event, timer, hotkey)
    participant WM as WindowManager (main)
    participant SO as SystemObserver (AX.queue)
    participant R as Reconciler (Core)
    participant VW as VirtualWorkspaces (Core)
    participant UI as Ring · Bar · Handles

    E->>WM: tick()
    WM->>WM: pruneDeadWindows (window list)
    WM->>SO: snapshot(tracked:)
    SO->>SO: visible windows + tracked, focused, excuses for unreadable
    SO-->>WM: Snapshot (main thread)
    alt no window readable
        WM->>WM: ignore pass
    else
        WM->>WM: markAway (fullscreen, missing display)
        WM->>WM: assignNewVirtualWindows (saved layout, siblings, active)
        WM->>R: reconcile(state, snapshot)
        R-->>WM: state', [Command]
        WM->>WM: scheduleSave
        WM->>VW: apply(parking: hide / park / unpark)
        WM->>SO: execute(commands)
        opt commands non-empty and settle
            WM->>SO: snapshot again (≤ 3 passes)
        end
    end
    WM->>UI: refreshChrome, completions
```

## Desktops, displays and parking

```mermaid
flowchart TB
    D1["desktop 1"] & D2["desktop 2"] & D3["desktop 3"] -->|home| A["display A (main)"]
    D4["desktop 4"] & D5["desktop 5"] -->|home| B["display B"]
    A -->|shows| D2
    B -->|shows| D4
    D1 & D3 -->|"not shown: windows parked<br/>past A's clear corner,<br/>or app hidden"| PA["parking A"]
    D5 -->|"not shown"| PB["parking B"]
    B -. "unplugged > 10 s" .-> A
    classDef shown fill:#ffd97a,stroke:#333
    class D2,D4 shown
```

- Desktops are numbered globally; each has a home display (by UUID) remembered across launches.
- A vanished display keeps its desktops for 10 s; after that they show on the main display and return when it is back.
- Grids are keyed by desktop (`VirtualWorkspaces.spaceID`), so a desktop carries its layout to whatever display it is on.

## Input paths

```mermaid
flowchart LR
    Key["key press"] --> Tap
    Key --> Carbon["Carbon hotkey"] --> Actions["actionTable (main.swift)"] --> WM
    Mouse["click / drag / scroll"] --> Tap["event tap"] -->|forward| Drag["DragController (main)"]
    Drag -->|"hitTest, zones, drop / release"| WM
    Touch["multitouch"] --> Gest["SwipeGesture"] --> Overview & Slide
    Chips["bar chips, menus, popup"] --> WM
    Overview & Slide --> WM["WindowManager"]
```

## Persistence

```mermaid
flowchart LR
    Config["config.conf<br/>Config.parse / serialize<br/>schema 3, migrated"] --> WM
    State["state.json<br/>SavedLayout schema 3<br/>grids by desktop, floating frames,<br/>desktop homes, shown per display"] <--> WM["WindowManager"]
    Cats["cats.json<br/>cat memory"] <--> BarCat
    Log["log.txt (2 MB, rotated)"] <-- Log.write --- All["every component"]
```
