import CoreGraphics
import Foundation
import BetterWMCore

struct ReconcilerTests {
    let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let space: SpaceID = 1

    func win(_ id: WindowID, _ frame: CGRect, spaces: [SpaceID]? = nil, bundle: String = "app.\(UUID().uuidString)") -> WindowInfo {
        WindowInfo(id: id, pid: pid_t(id), bundleID: bundle, frame: frame, spaces: spaces ?? [space])
    }

    func snapshot(_ windows: [WindowInfo], focused: WindowID? = nil) -> Snapshot {
        Snapshot(screens: [ScreenInfo(space: space, area: area)], windows: windows, focused: focused)
    }

    var config: Config {
        var c = Config()
        c.gap = 0
        c.outerGap = 0
        c.floatSmallWindows = false
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
        expect(state.grid(for: space).minSizes[2]?.width == 1000, #function, 89)
        expect(commands == [.setFrame(1, CGRect(x: 0, y: 0, width: 600, height: 1000)),
                             .setFrame(2, CGRect(x: 600, y: 0, width: 1000, height: 1000))], #function, #line)
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
        expect(!(g.canMove(1, .left)), #function, 136)
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
        expect(c.focusRingColor == "#4C8BF5", #function, #line)
        expect(c.barBackground == "#1E1E1ECC", #function, #line)
        expect(c.gap == 4, #function, #line)
        expect(c.focusRingWidth == 3, #function, #line)
    }

    func testStrategiesPlaceRelativeToFocused() {
        var c = config
        c.autoTileStrategy = .nextToFocused
        let r = Reconciler(config: c)
        var (state, _) = r.reconcile(DesiredState(), snapshot([win(1, area), win(2, area), win(3, area)]))
        (state, _) = r.reconcile(state, snapshot([win(1, area), win(2, area), win(3, area), win(4, area)], focused: 1))
        expect(state.grid(for: space).columns.map(\.windows) == [[1], [4], [2], [3]], #function, 159)
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
    ("retileRequestTilesEverythingOnce", t.testRetileRequestTilesEverythingOnce),
    ("dropZonesAndApply", t.testDropZonesAndApply),
    ("moveAndMerge", t.testMoveAndMerge),
    ("displacedDetection", t.testDisplacedDetection),
    ("strategiesPlaceRelativeToFocused", t.testStrategiesPlaceRelativeToFocused),
    ("hexColoursSurviveCommentStripping", t.testHexColoursSurviveCommentStripping),
]
for (name, run) in tests {
    let before = failures
    run()
    print(before == failures ? "ok   \(name)" : "FAIL \(name)")
}
print(failures == 0 ? "All \(tests.count) tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
