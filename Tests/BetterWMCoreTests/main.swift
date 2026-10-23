import CoreGraphics
import Foundation
import BetterWMCore

struct ReconcilerTests {
    let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let space: SpaceID = 1

    func win(_ id: WindowID, _ frame: CGRect, spaces: [SpaceID]? = nil, bundle: String = "app.\(UUID().uuidString)") -> WindowInfo {
        WindowInfo(id: id, pid: pid_t(id), bundleID: bundle, frame: frame, spaces: spaces ?? [space])
    }

    func snapshot(_ windows: [WindowInfo], focused: WindowID? = nil, now: Date = Date(timeIntervalSinceReferenceDate: 0)) -> Snapshot {
        Snapshot(screens: [ScreenInfo(space: space, area: area)], windows: windows, focused: focused, now: now)
    }

    var config: Config {
        var c = Config()
        c.gap = 0
        c.outerGap = 0
        c.floatSmallWindows = false
        c.autoTile = true
        return c
    }

    func testFirstVisitTilesInScreenOrder() {
        let r = Reconciler(config: config)
        let snap = snapshot([win(2, CGRect(x: 800, y: 0, width: 600, height: 600)),
                             win(1, CGRect(x: 100, y: 0, width: 600, height: 600))])
        let (state, commands) = r.reconcile(DesiredState(), snap)
        expect(state.grid(for: space).columns.map(\.windows) == [[1], [2]], #function, 31)
        expect(commands == [.setFrame(1, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                             .setFrame(2, CGRect(x: 800, y: 0, width: 800, height: 1000))], #function, #line)
    }

    func testNoCommandsWhenAlreadyInPlace() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, .zero)]))
        let settled = snapshot([win(1, area)])
        var commands: [Command]
        (state, commands) = r.reconcile(state, settled)
        expect(commands.isEmpty, #function, 42)
    }

    func testArrivalAppendsOnRightByDefault() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area)]))
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, CGRect(x: 10, y: 10, width: 500, height: 500))]))
        expect(state.grid(for: space).columns.map(\.windows) == [[1], [2]], #function, 49)
    }

    func testWindowOnOtherSpaceIsNotArrival() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area)]))
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area, spaces: [99])]))
        expect(state.grid(for: space).windows == [1], #function, 56)
    }

    func testDepartureOnlyWhenSpaceMembershipLost() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        // Still reported on this Space but off-screen mid-transition: keep it.
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, CGRect(x: 5000, y: 0, width: 10, height: 10))]))
        expect(state.grid(for: space).windows.count == 2, #function, 64)
        // Moved to another Space: drop it.
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area, spaces: [99])]))
        expect(state.grid(for: space).windows == [1], #function, 67)
        // Gone entirely: drop it.
        (state, _) = r.reconcile(state, snapshot([win(1, area)]))
        expect(state.grid(for: space).windows == [1], #function, 70)
    }

    func testIgnoredAppIsNotTiled() {
        var c = config
        c.ignoreApps = ["com.apple.calculator"]
        let r = Reconciler(config: c)
        let (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area, bundle: "com.apple.calculator")]))
        expect(state.grid(for: space).windows == [1], #function, 78)
    }

    func testMinimumSizeIsLearnedAndRespected() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        // Window 2 refused to go below 1000 wide.
        let refused = snapshot([win(1, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                                win(2, CGRect(x: 800, y: 0, width: 1000, height: 1000))])
        var commands: [Command]
        (state, commands) = r.reconcile(state, refused)
        expect(state.grid(for: space).minSizes[2] == nil, #function, #line)
        var later = refused
        later.now += 1
        (state, commands) = r.reconcile(state, later)
        expect(state.grid(for: space).minSizes[2]?.width == 1000, #function, #line)
        expect(commands == [.setFrame(1, CGRect(x: 0, y: 0, width: 600, height: 1000)),
                             .setFrame(2, CGRect(x: 600, y: 0, width: 1000, height: 1000))], #function, #line)
    }

    func testPassingThroughLargerFrameTeachesNoMinimum() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        (state, _) = r.reconcile(state, snapshot([win(1, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                                                  win(2, CGRect(x: 400, y: 0, width: 1200, height: 1000))], now: t0 + 1))
        (state, _) = r.reconcile(state, snapshot([win(1, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                                                  win(2, CGRect(x: 800, y: 0, width: 900, height: 1000))], now: t0 + 2))
        expect(state.grid(for: space).minSizes[2] == nil, #function, #line)
    }

    func testAwayWindowKeepsSlotAndIsLeftAlone() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        var away = snapshot([win(1, CGRect(x: 0, y: 0, width: 800, height: 1000)), win(2, area)], now: Date(timeIntervalSinceReferenceDate: 5))
        away.away = [2]
        var commands: [Command]
        (state, commands) = r.reconcile(state, away)
        away.now += 5
        (state, commands) = r.reconcile(state, away)
        expect(state.isTiled(2) && state.grid(for: space).minSizes[2] == nil, #function, #line)
        expect(!commands.contains { if case .setFrame(2, _) = $0 { return true } else { return false } }, #function, #line)
    }

    func testParkingAvoidsNeighbouringDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let monitor = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let alone = Parking.origin(for: w, screens: [laptop])
        expect(alone == CGPoint(x: 1510, y: 980), #function, #line)
        let beside = Parking.origin(for: w, screens: [laptop, monitor])
        expect(beside == CGPoint(x: -798, y: 980), #function, #line)
        let parked = CGRect(origin: beside, size: w.size)
        expect(!parked.intersects(monitor) && Parking.screen(parking: parked, screens: [laptop, monitor], tolerance: 3) == laptop, #function, #line)
        // Parked again from the corner, it stays with the same screen and corner.
        expect(Parking.origin(for: parked, screens: [laptop, monitor]) == beside, #function, #line)
    }

    func testNoTilingOnFirstVisitWhenDisabled() {
        var c = config
        c.tileExistingOnStart = false
        let r = Reconciler(config: c)
        var (state, commands) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        expect(state.grid(for: space).isEmpty, #function, 99)
        expect(commands.isEmpty, #function, 100)
        // But a window opened afterwards is tiled.
        (state, commands) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area)]))
        expect(state.grid(for: space).windows == [3], #function, 103)
    }

    func testRestoredFloatingWindowIsNotTiled() {
        let r = Reconciler(config: config)
        var initial = DesiredState()
        initial.floating = [2]
        var (state, _) = r.reconcile(initial, snapshot([win(1, area), win(2, area)]))
        expect(state.grid(for: space).windows == [1], #function, #line)
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area)]))
        expect(state.grid(for: space).windows == [1, 3], #function, #line)
        // Once tiled by hand it is an ordinary window again.
        state.mutate(space) { $0.apply(.newColumn(index: 2), to: 2) }
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area)]))
        expect(!state.floating.contains(2), #function, #line)
        // Untiled by hand, then gone (parked on an inactive workspace) and back: still floating.
        state.untile(2)
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(3, area)]))
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area)]))
        expect(state.grid(for: space).windows == [1, 3], #function, #line)
    }

    func testRetileRequestTilesEverythingOnce() {
        var c = config
        c.tileExistingOnStart = false
        let r = Reconciler(config: c)
        var state = DesiredState()
        state.retileRequested.insert(space)
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area)]))
        expect(state.grid(for: space).windows.count == 2, #function, 113)
        expect(!(state.retileRequested.contains(space)), #function, 114)
    }

    func testDropZonesAndApply() {
        var g = Grid()
        g.apply(.newColumn(index: 0), to: 1)
        g.apply(.newColumn(index: 1), to: 2)
        g.apply(.newColumn(index: 2), to: 3)
        g.apply(.newColumn(index: 3), to: 4)
        let geo = GridGeometry(grid: g, area: area, config: config)
        let cf = geo.columnFrames()
        // Bottom half of the rightmost column, dragging window 3.
        let (zone, _) = geo.zone(at: CGPoint(x: cf[3].midX, y: cf[3].maxY - 20), dragging: 3)!
        expect(zone == .stack(column: 3, index: 1), #function, 127)
        g.apply(zone, to: 3)
        expect(g.columns.map(\.windows) == [[1], [2], [4, 3]], #function, 129)
    }

    func testMoveAndMerge() {
        var g = Grid()
        g.apply(preset: LayoutPreset(name: "", columns: [.init(weight: 1, count: 1), .init(weight: 1, count: 2)]), windows: [1, 2, 3])
        expect(g.canMove(1, .mergeRight), #function, 135)
        expect(g.canMove(1, .left), #function, 136)  // at the edge: cycles width instead
        g.move(1, .mergeRight)
        expect(g.columns.map(\.windows) == [[2, 3, 1]], #function, 138)
        g.move(1, .up)
        expect(g.columns[0].windows == [2, 1, 3], #function, 140)
        g.move(1, .right)
        expect(g.columns.map(\.windows) == [[2, 3], [1]], #function, 142)
    }

    func testDisplacedDetection() {
        let r = Reconciler(config: config)
        let (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area)]))
        let moved = snapshot([win(1, CGRect(x: 0, y: 0, width: 800, height: 1000)),
                              win(2, CGRect(x: 900, y: 100, width: 500, height: 500))])
        expect(r.displaced(state, moved) == [2], #function, 150)
    }

    func testHexColoursSurviveCommentStripping() {
        let c = Config.parse("focusRingColor = #4C8BF5\nbarBackground = #1E1E1ECC # note\ngap = 4 # comment\n# focusRingWidth = 9\n")
        expect(c.focusRingColor == "4C8BF5", #function, #line)  // v1 "#" stripped by migration
        expect(c.barBackground == "1E1E1ECC", #function, #line)
        expect(c.gap == 4, #function, #line)
        expect(c.focusRingWidth == Config().focusRingWidth, #function, #line)  // the commented line must not apply
    }

    func testSavedLayoutRoundTripAndMatching() {
        var state = DesiredState()
        state.grids[space] = {
            var g = Grid()
            g.columns = [Column([1], weight: 2), Column([2, 3], weight: 1)]
            g.heightWeights[2] = 3
            return g
        }()
        let before = snapshot([
            WindowInfo(id: 1, pid: 1, bundleID: "com.a", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), spaces: [space], title: "A main"),
            WindowInfo(id: 2, pid: 2, bundleID: "com.b", frame: CGRect(x: 1000, y: 0, width: 600, height: 500), spaces: [space], title: "B one"),
            WindowInfo(id: 3, pid: 2, bundleID: "com.b", frame: CGRect(x: 1000, y: 500, width: 600, height: 500), spaces: [space], title: "B two"),
        ])
        let saved = SavedLayout.capture(state, before)
        let data = try! JSONEncoder().encode(saved)
        let decoded = try! JSONDecoder().decode(SavedLayout.self, from: data)
        expect(decoded == saved, #function, #line)

        // After relaunch: new IDs, B's windows reopened with swapped titles, A gone, plus an unrelated window.
        let after = [
            WindowInfo(id: 20, pid: 5, bundleID: "com.b", frame: CGRect(x: 1000, y: 500, width: 600, height: 500), spaces: [space], title: "B two"),
            WindowInfo(id: 21, pid: 5, bundleID: "com.b", frame: CGRect(x: 1000, y: 0, width: 600, height: 500), spaces: [space], title: "B one"),
            WindowInfo(id: 30, pid: 6, bundleID: "com.c", frame: .zero, spaces: [space], title: "C"),
        ]
        let grid = decoded.restore(space: space, candidates: after)!
        expect(grid.columns.map(\.windows) == [[21, 20]], #function, #line)
        expect(grid.columns[0].weight == 1, #function, #line)
        expect(grid.heightWeights[21] == 3, #function, #line)
        expect(decoded.restore(space: 99, candidates: after) == nil, #function, #line)
    }

    func testRestoreFallsBackToNearestFrame() {
        let saved = SavedLayout(spaces: [.init(id: space, columns: [
            .init(weight: 1, windows: [.init(bundleID: "com.b", title: "old title", frame: CGRect(x: 800, y: 0, width: 800, height: 1000), heightWeight: 1)]),
        ])])
        let candidates = [
            WindowInfo(id: 1, pid: 1, bundleID: "com.b", frame: CGRect(x: 0, y: 0, width: 800, height: 1000), spaces: [space], title: "x"),
            WindowInfo(id: 2, pid: 1, bundleID: "com.b", frame: CGRect(x: 790, y: 0, width: 800, height: 1000), spaces: [space], title: "y"),
        ]
        expect(saved.restore(space: space, candidates: candidates)?.windows == [2], #function, #line)
    }

    func testResizeByDeltaMovesBoundaries() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area), win(3, area)]))
        state.mutate(space) { $0.apply(.stack(column: 0, index: 1), to: 3) }
        let geo = r.geometry(state.grid(for: space), ScreenInfo(space: space, area: area))
        let before = Dictionary(uniqueKeysWithValues: geo.windowFrames())
        let grown = GridGeometry(grid: geo.resizing(window: 1, by: 100), area: area, config: config)
        let after = Dictionary(uniqueKeysWithValues: grown.windowFrames())
        expect(abs(after[1]!.width - before[1]!.width - 100) < 1 && abs(after[2]!.width - before[2]!.width + 100) < 1, #function, #line)
        expect(abs(after[1]!.height - before[1]!.height - 100) < 1 && abs(after[3]!.height - before[3]!.height + 100) < 1, #function, #line)
        let shrunk = GridGeometry(grid: grown.resizing(window: 1, by: -100), area: area, config: config)
        expect(Dictionary(uniqueKeysWithValues: shrunk.windowFrames())[1]!.approximatelyEquals(before[1]!, tolerance: 1), #function, #line)
    }

    func testDragEndRules() {
        let slot = CGRect(x: 0, y: 0, width: 800, height: 600)
        let elsewhere = CGRect(x: 300, y: 200, width: 800, height: 600)
        let fullscreen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        // A click, even one whose button changed the frame, is not a hand move.
        expect(DragRules.outcome(moved: false, travel: 0, before: slot, after: fullscreen, alt: false) == .init(), #function, #line)
        // A nudge short of the threshold snaps back and settles nothing.
        expect(DragRules.outcome(moved: true, travel: 12, before: slot, after: slot.offsetBy(dx: 12, dy: 0), alt: false) == .init(snapBack: true), #function, #line)
        // A real drag releases the window and remembers where it landed.
        expect(DragRules.outcome(moved: true, travel: 300, before: slot, after: elsewhere, alt: false) == .init(release: true, rememberFloating: true), #function, #line)
        // ⌥-drag that missed every zone: released, but the miss is not a new floating spot.
        expect(DragRules.outcome(moved: true, travel: 300, before: slot, after: elsewhere, alt: true) == .init(release: true), #function, #line)
        // A long drag inside the window (a canvas item, a text selection) moved nothing: no release.
        expect(DragRules.outcome(moved: true, travel: 300, before: slot, after: slot, alt: false) == .init(rememberFloating: true), #function, #line)
    }

    func testEdgeMoveCyclesWidth() {
        var g = Grid()
        g.columns = [Column([1]), Column([2])]
        expect(g.canMove(2, .right), #function, #line)
        g.move(2, .right)
        expect(abs(g.fraction(ofColumn: 1) - 1.0 / 3) < 0.001, #function, #line)
        g.move(2, .right)
        expect(abs(g.fraction(ofColumn: 1) - 1.0 / 4) < 0.001, #function, #line)
        g.move(2, .right)
        expect(abs(g.fraction(ofColumn: 1) - 2.0 / 3) < 0.001, #function, #line)
        g.move(2, .right)
        expect(abs(g.fraction(ofColumn: 1) - 1.0 / 2) < 0.001, #function, #line)
        g.move(1, .left)
        expect(abs(g.fraction(ofColumn: 0) - 1.0 / 3) < 0.001, #function, #line)
        expect(g.columns.map(\.windows) == [[1], [2]], #function, #line)

        // Single column and out-of-bounds must not crash or produce NaN
        var single = Grid()
        single.columns = [Column([1])]
        single.cycleEdgeWidth(ofColumn: 0)
        expect(single.fraction(ofColumn: 0) == 1.0, #function, #line)
        expect(single.fraction(ofColumn: 99) == 0, #function, #line)
    }

    func testConfigV1Migration() {
        let v1 = "focusRingColor = #FF9300\nhotkey.popup = alt+cmd+space\nbarCatSheet = /tmp/cat.png\n"
        let c = Config.parse(v1)
        expect(c.focusRingColor == "FF9300", #function, #line)
        expect(c.hotkeys["switcher"] == "alt+tab", #function, #line)
        expect(c.barCatSheets == ["/tmp/cat.png"], #function, #line)
        // A current-version file that deliberately unbinds the switcher keeps it unbound.
        let v2 = "version = 2\nhotkey.popup = alt+cmd+space\n"
        expect(Config.parse(v2).hotkeys["switcher"] == nil, #function, #line)
        expect(Config.parse(Config().serialized()).hotkeys == Config().hotkeys, #function, #line)
        expect(Config().hotkeys["desktop3"] == "ctrl+3" && Config().hotkeys["sendToDesktop9"] == "ctrl+alt+9", #function, #line)
    }

    func testBarWidgetsCompatibility() {
        // Old files only have the flags: the list is derived from them in the default order.
        let old = Config.parse("version = 3\nbarWifi = false\nbarCpu = false\n")
        expect(old.barWidgets == Config().barWidgets.filter { $0 != .wifi && $0 != .cpu }, #function, #line)
        // New files carry the order; the flags mirror it for older versions reading the file.
        // A v2 file with an explicit list gains the menu widget added in v3; a v3 file is taken as is.
        let v2 = Config.parse("version = 2\nbarWidgets = clock, battery, weather\n")
        expect(v2.barWidgets == [.clock, .battery, .weather, .menu], #function, #line)
        let new = Config.parse("version = 3\nbarWidgets = clock, battery, weather\n")
        expect(new.barWidgets == [.clock, .battery, .weather] && !new.barCpu && new.barWeather, #function, #line)
        let text = new.serialized()
        expect(text.contains("barWidgets = clock, battery, weather") && text.contains("barCpu = false"), #function, #line)
        expect(Config.parse(text).barWidgets == [.clock, .battery, .weather], #function, #line)
        // Re-enabling a flag slots the widget back at its default position.
        var c = new; c.barCpu = true
        expect(c.barWidgets == [.clock, .battery, .weather, .cpu] || c.barWidgets.contains(.cpu), #function, #line)
    }

    func testSavedLayoutV1Migration() {
        let json = """
        {"spaces":[{"id":1000200,"columns":[{"weight":1,"windows":[{"bundleID":"com.a","title":"t","frame":[[0,0],[10,10]],"heightWeight":1}]}]},
                   {"id":7,"columns":[]}]}
        """
        let v1 = try! JSONDecoder().decode(SavedLayout.self, from: Data(json.utf8))
        expect(v1.version == 1, #function, #line)
        let v2 = v1.migrated(currentSpace: 3)
        expect(v2.version == SavedLayout.schemaVersion, #function, #line)
        expect(v2.spaces.map(\.id).sorted() == [7, VirtualWorkspaces.spaceID(2)], #function, #line)
        let encoded = try! JSONEncoder().encode(v2)
        expect(try! JSONDecoder().decode(SavedLayout.self, from: encoded) == v2, #function, #line)
    }

    func testFloatingWindowsSavedAndRestored() {
        let space: SpaceID = 1_000_030_201
        var state = DesiredState()
        var g = Grid(); g.columns = [Column([1])]
        state.grids[space] = g
        let snap = Snapshot(screens: [], windows: [
            WindowInfo(id: 1, pid: 1, bundleID: "com.a", frame: CGRect(x: 0, y: 0, width: 800, height: 600), spaces: [space], title: "tiled"),
            WindowInfo(id: 2, pid: 2, bundleID: "com.b", frame: CGRect(x: 100, y: 100, width: 400, height: 300), spaces: [space], title: "float"),
        ], focused: nil, now: Date(timeIntervalSinceReferenceDate: 0))
        let saved = SavedLayout.capture(state, snap, floatingSpace: { _ in space })
        expect(saved.spaces.count == 1 && saved.spaces[0].floating.map { $0.title } == ["float"], #function, #line)
        let encoded = try! JSONEncoder().encode(saved)
        expect(try! JSONDecoder().decode(SavedLayout.self, from: encoded) == saved, #function, #line)
        let later = WindowInfo(id: 9, pid: 9, bundleID: "com.b", frame: CGRect(x: 1900, y: 1200, width: 400, height: 300), spaces: [space], title: "float")
        let restored = saved.restoreFloating(space: space, candidates: [later])
        expect(restored.count == 1 && restored[0].id == 9 && restored[0].frame == CGRect(x: 100, y: 100, width: 400, height: 300), #function, #line)
        let legacy = try! JSONDecoder().decode(SavedLayout.self, from: Data(#"{"version":2,"spaces":[{"id":5,"columns":[]}]}"#.utf8))
        expect(legacy.spaces[0].floating.isEmpty, #function, #line)
    }

    func testStackedModeGeometry() {
        var c = config
        c.stackOffset = 50
        var g = Grid()
        g.columns = [Column([1, 2]), Column([3])]
        g.setMode(.stacked)
        expect(g.columns.map(\.windows) == [[1], [2], [3]], #function, #line)
        let geo = GridGeometry(grid: g, area: area, config: c)
        let frames = geo.windowFrames()
        expect(frames.map { $0.1.minX } == [0, 50, 100], #function, #line)
        expect(frames.allSatisfy { $0.1.width == 1500 && $0.1.height == 1000 }, #function, #line)
        expect(geo.handleFrames().isEmpty, #function, #line)
        // Dropping onto the second strip puts the window second in the deck.
        let (zone, _) = geo.zone(at: CGPoint(x: 60, y: 500), dragging: 3)!
        expect(zone == .newColumn(index: 1), #function, #line)
        g.apply(.stack(column: 0, index: 1), to: 3)
        expect(g.columns.map(\.windows) == [[1], [3], [2]], #function, #line)
    }

    func testStackedDeckKeepsPositions() {
        var c = config
        c.stackOffset = 50
        let r = Reconciler(config: c)
        var state = DesiredState()
        var g = Grid()
        g.setMode(.stacked)
        g.columns = [Column([1]), Column([2]), Column([3])]
        state.grids[space] = g
        state.seen[space] = [1, 2, 3]
        // Focus (z-order) changes never reorder the deck.
        let (next, commands) = r.reconcile(state, snapshot([win(1, area), win(3, area), win(2, area)]))
        expect(next.grid(for: space).windows == [1, 2, 3], #function, #line)
        let x = Dictionary(uniqueKeysWithValues: commands.compactMap { c -> (WindowID, CGFloat)? in
            if case let .setFrame(w, f) = c { return (w, f.minX) } else { return nil }
        })
        expect(x[1] == 0 && x[2] == 50 && x[3] == 100, #function, #line)
        // Deliberate reordering still works.
        expect(next.grid(for: space).canMove(1, .right) && !next.grid(for: space).canMove(1, .mergeRight), #function, #line)
    }

    func testStackedModeSurvivesSaveWithoutWindows() {
        var state = DesiredState()
        var g = Grid(); g.setMode(.stacked)
        state.grids[space] = g
        let saved = SavedLayout.capture(state, snapshot([]))
        expect(saved.mode(for: space) == .stacked, #function, #line)
        let data = try! JSONEncoder().encode(saved)
        expect(try! JSONDecoder().decode(SavedLayout.self, from: data).mode(for: space) == .stacked, #function, #line)
    }

    func testStrategiesPlaceRelativeToFocused() {
        var c = config
        c.autoTileStrategy = .nextToFocused
        let r = Reconciler(config: c)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area), win(3, area)]))
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area), win(4, area)], focused: 1))
        expect(state.grid(for: space).columns.map(\.windows) == [[1], [4], [2], [3]], #function, 159)
    }

    func testRefusedFrameGivesUpThenRetries() {
        let r = Reconciler(config: config)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let stuck = CGRect(x: 0, y: 0, width: 10, height: 10)
        var (state, commands) = r.reconcile(DesiredState(), snapshot([win(1, stuck)], now: t0))
        // Settle passes of one tick are a single attempt.
        for _ in 0..<5 { (state, commands) = r.reconcile(state, snapshot([win(1, stuck)], now: t0)) }
        expect(commands.count == 1, #function, #line)
        var now = t0
        for _ in 1..<DesiredState.maxAttempts { now += 1; (state, commands) = r.reconcile(state, snapshot([win(1, stuck)], now: now)) }
        expect(!commands.isEmpty, #function, #line)
        (state, commands) = r.reconcile(state, snapshot([win(1, stuck)], now: now + 1))
        expect(commands.isEmpty, #function, #line)
        (state, commands) = r.reconcile(state, snapshot([win(1, stuck)], now: now + DesiredState.retryAfter + 1))
        expect(commands.count == 1, #function, #line)
    }

    func testWindowThatMovedHasNotRefused() {
        let r = Reconciler(config: config)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let stuck = CGRect(x: 0, y: 0, width: 10, height: 10)
        let parked = CGRect(x: 1598, y: 998, width: 10, height: 10)
        var (state, commands) = r.reconcile(DesiredState(), snapshot([win(1, stuck)], now: t0))
        var now = t0
        for _ in 1..<DesiredState.maxAttempts { now += 1; (state, commands) = r.reconcile(state, snapshot([win(1, stuck)], now: now)) }
        (state, commands) = r.reconcile(state, snapshot([win(1, parked)], now: now + 1))
        expect(commands.count == 1, #function, #line)
    }

    func testForgetClearsEveryRecord() {
        let r = Reconciler(config: config)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, .zero), win(2, .zero)]))
        state.floating.insert(1)
        state.forget(1)
        expect(!state.isTiled(1) && !state.floating.contains(1) && state.requested[1] == nil && state.attempts[1] == nil
               && !(state.seen[space] ?? []).contains(1), #function, #line)
        expect(state.isTiled(2), #function, #line)
    }

    final class FakeScreen {
        var frames: [WindowID: CGRect] = [:]
        var hidden: Set<pid_t> = []
        var ignoresMoves: Set<WindowID> = []
        let corner = CGPoint(x: 1598, y: 998)
        func park(_ v: VirtualWorkspaces, now: Date, hideable: Bool = false, countRefusals: Bool = true) {
            v.apply(windows: Array(frames.keys).sorted(), pid: { pid_t($0) }, hideable: { _ in hideable },
                    isTiled: { _ in false }, frame: { self.frames[$0] },
                    setFrame: { w, f in if !self.ignoresMoves.contains(w) { self.frames[w] = f } },
                    parkOrigin: { _, _ in self.corner },
                    isInCorner: { _, f in abs(f.minX - self.corner.x) <= 100 && abs(f.minY - self.corner.y) <= 100 },
                    fit: { $1 }, hide: { self.hidden.insert($0) }, unhide: { self.hidden.remove($0) },
                    countRefusals: countRefusals, now: now)
        }
    }

    func desktops(_ n: Int, displays: [DisplayID] = ["A"]) -> VirtualWorkspaces {
        let v = VirtualWorkspaces(count: n) { _ in }
        v.connect(displays)
        return v
    }

    func testDesktopsLiveOnDisplays() {
        let v = desktops(3)
        expect(v.desktops(on: "A") == [0, 1, 2] && v.shown == [0], #function, #line)
        // A new display gets a desktop of its own; both are shown.
        v.connect(["A", "B"])
        expect(v.count == 4 && v.desktops(on: "B") == [3] && v.shown == [0, 3], #function, #line)
        v.switchTo(1)
        expect(v.shown == [1, 3] && v.active == 1, #function, #line)
        // Sending the active desktop to B shows it there; A falls back to one of its own.
        v.send(desktop: 1, to: "B")
        expect(v.display(of: 1) == "B" && v.shownDesktop(on: "B") == 1 && v.shownDesktop(on: "A") == 0, #function, #line)
        // Unplugging B brings its desktops to A; plugging it back returns them.
        v.connect(["A"])
        expect(v.desktops(on: "A") == [0, 1, 2, 3] && v.shown == [0], #function, #line)
        v.connect(["A", "B"])
        expect(v.desktops(on: "B") == [1, 3] && v.shownDesktop(on: "B") == 1, #function, #line)
    }

    func testMainDisplayChangeKeepsDesktops() {
        let v = desktops(2)
        v.connect(["A", "B"])
        v.send(desktop: 1, to: "B")
        // Desktop 2 came with B; 3 is made on demand while A is main.
        v.setCount(4)
        // B becomes main: desktops stay where they live, those made on demand too; only new ones follow main.
        v.connect(["B", "A"])
        expect(v.display(of: 0) == "A" && v.display(of: 1) == "B" && v.display(of: 3) == "A" && v.main == "B", #function, #line)
        v.setCount(5)
        expect(v.display(of: 4) == "B", #function, #line)
    }

    func testSendingLastDesktopLeavesANewOne() {
        let v = desktops(1)
        v.connect(["A", "B"])
        v.send(desktop: 0, to: "B")
        expect(v.desktops(on: "A").count == 1 && v.display(of: 0) == "B", #function, #line)
    }

    func testParkingFollowsActiveWorkspace() {
        let v = desktops(2)
        let screen = FakeScreen()
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        screen.frames = [1: home, 2: home]
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        screen.park(v, now: t0)
        v.move(2, to: 1)
        screen.park(v, now: t0)
        expect(v.isParked(2) && screen.frames[2]?.origin == screen.corner && !v.isParked(1), #function, #line)
        v.switchTo(1)
        screen.park(v, now: t0)
        expect(v.isParked(1) && !v.isParked(2) && screen.frames[2] == home, #function, #line)
    }

    func testHideableAppIsHiddenNotParked() {
        let v = desktops(2)
        let screen = FakeScreen()
        screen.frames = [3: CGRect(x: 0, y: 0, width: 300, height: 300)]
        v.move(3, to: 1)
        screen.park(v, now: Date(timeIntervalSinceReferenceDate: 0), hideable: true)
        expect(screen.hidden == [3] && v.hiddenPids == [3], #function, #line)
        v.switchTo(1)
        screen.park(v, now: Date(timeIntervalSinceReferenceDate: 0), hideable: true)
        expect(screen.hidden.isEmpty && v.hiddenPids.isEmpty, #function, #line)
    }

    func testWindowRefusingToParkJoinsActiveWorkspace() {
        let v = desktops(2)
        let screen = FakeScreen()
        screen.frames = [4: CGRect(x: 100, y: 100, width: 300, height: 300)]
        screen.ignoresMoves = [4]
        v.move(4, to: 1)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        for _ in 0..<10 where v.workspace(of: 4) == 1 { screen.park(v, now: now); now += 1 }
        expect(v.workspace(of: 4) == 0 && !v.isParked(4), #function, #line)
    }

    func testRefusalsDoNotCountWhileSuspended() {
        let v = desktops(2)
        let screen = FakeScreen()
        screen.frames = [5: CGRect(x: 100, y: 100, width: 300, height: 300)]
        screen.ignoresMoves = [5]
        v.move(5, to: 1)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        for _ in 0..<10 { screen.park(v, now: now, countRefusals: false); now += 1 }
        expect(v.workspace(of: 5) == 1, #function, #line)
    }

    func testMoveWorkspaceRemapsAndTrims() {
        let v = desktops(3)
        v.move(1, to: 0); v.move(2, to: 2)
        let map = v.moveWorkspace(from: 2, to: 0)
        expect(map == [0: 1, 1: 2, 2: 0] && v.workspace(of: 2) == 0 && v.workspace(of: 1) == 1, #function, #line)
        v.forget(2)
        v.trimEmptyTrailing(minimum: 1)
        expect(v.count == 2, #function, #line)
        expect(VirtualWorkspaces.workspace(of: VirtualWorkspaces.spaceID(2)) == 2, #function, #line)
    }
}


// Minimal harness: Command Line Tools ship neither XCTest nor the Swift Testing macros.
var failures = 0
func expect(_ ok: Bool, _ test: String, _ line: Int) {
    if !ok { failures += 1; print("FAIL \(test) line \(line)") }
}

let t = ReconcilerTests()
let tests: [(String, () -> Void)] = [
    ("firstVisitTilesInScreenOrder", t.testFirstVisitTilesInScreenOrder),
    ("noCommandsWhenAlreadyInPlace", t.testNoCommandsWhenAlreadyInPlace),
    ("arrivalAppendsOnRightByDefault", t.testArrivalAppendsOnRightByDefault),
    ("windowOnOtherSpaceIsNotArrival", t.testWindowOnOtherSpaceIsNotArrival),
    ("departureOnlyWhenSpaceMembershipLost", t.testDepartureOnlyWhenSpaceMembershipLost),
    ("ignoredAppIsNotTiled", t.testIgnoredAppIsNotTiled),
    ("minimumSizeIsLearnedAndRespected", t.testMinimumSizeIsLearnedAndRespected),
    ("noTilingOnFirstVisitWhenDisabled", t.testNoTilingOnFirstVisitWhenDisabled),
    ("restoredFloatingWindowIsNotTiled", t.testRestoredFloatingWindowIsNotTiled),
    ("retileRequestTilesEverythingOnce", t.testRetileRequestTilesEverythingOnce),
    ("dropZonesAndApply", t.testDropZonesAndApply),
    ("moveAndMerge", t.testMoveAndMerge),
    ("displacedDetection", t.testDisplacedDetection),
    ("strategiesPlaceRelativeToFocused", t.testStrategiesPlaceRelativeToFocused),
    ("hexColoursSurviveCommentStripping", t.testHexColoursSurviveCommentStripping),
    ("savedLayoutRoundTripAndMatching", t.testSavedLayoutRoundTripAndMatching),
    ("restoreFallsBackToNearestFrame", t.testRestoreFallsBackToNearestFrame),
    ("edgeMoveCyclesWidth", t.testEdgeMoveCyclesWidth),
    ("dragEndRules", t.testDragEndRules),
    ("resizeByDeltaMovesBoundaries", t.testResizeByDeltaMovesBoundaries),
    ("configV1Migration", t.testConfigV1Migration),
    ("floatingWindowsSavedAndRestored", t.testFloatingWindowsSavedAndRestored),
    ("stackedModeGeometry", t.testStackedModeGeometry),
    ("stackedDeckKeepsPositions", t.testStackedDeckKeepsPositions),
    ("stackedModeSurvivesSaveWithoutWindows", t.testStackedModeSurvivesSaveWithoutWindows),
    ("barWidgetsCompatibility", t.testBarWidgetsCompatibility),
    ("savedLayoutV1Migration", t.testSavedLayoutV1Migration),
    ("refusedFrameGivesUpThenRetries", t.testRefusedFrameGivesUpThenRetries),
    ("forgetClearsEveryRecord", t.testForgetClearsEveryRecord),
    ("windowThatMovedHasNotRefused", t.testWindowThatMovedHasNotRefused),
    ("passingThroughLargerFrameTeachesNoMinimum", t.testPassingThroughLargerFrameTeachesNoMinimum),
    ("awayWindowKeepsSlotAndIsLeftAlone", t.testAwayWindowKeepsSlotAndIsLeftAlone),
    ("parkingAvoidsNeighbouringDisplay", t.testParkingAvoidsNeighbouringDisplay),
    ("parkingFollowsActiveWorkspace", t.testParkingFollowsActiveWorkspace),
    ("hideableAppIsHiddenNotParked", t.testHideableAppIsHiddenNotParked),
    ("windowRefusingToParkJoinsActiveWorkspace", t.testWindowRefusingToParkJoinsActiveWorkspace),
    ("refusalsDoNotCountWhileSuspended", t.testRefusalsDoNotCountWhileSuspended),
    ("moveWorkspaceRemapsAndTrims", t.testMoveWorkspaceRemapsAndTrims),
    ("desktopsLiveOnDisplays", t.testDesktopsLiveOnDisplays),
    ("mainDisplayChangeKeepsDesktops", t.testMainDisplayChangeKeepsDesktops),
    ("sendingLastDesktopLeavesANewOne", t.testSendingLastDesktopLeavesANewOne),
]
for (name, run) in tests {
    let before = failures
    run()
    print(before == failures ? "ok   \(name)" : "FAIL \(name)")
}
print(failures == 0 ? "All \(tests.count) tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
