import BetterWMCore
import Cocoa

/// The event tap, on a thread of its own. Every click, drag, key press and scroll passes through the tap before
/// the app under the cursor sees it, so the tap callback must never wait: it decides pass-or-swallow from a few
/// flags the main thread keeps current, and posts a copy of the event to the main thread for the real work.
/// A stall on the main thread (an app slow to answer Accessibility) then costs a late drop zone, not a frozen cursor.
final class DragController {
    private let manager: WindowManager
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var dragged: AXWindow?
    private var draggedID: WindowID?
    private var dragStart: CGPoint = .zero
    private var originalFrame: CGRect = .zero
    private var currentZone: (DropZone, CGRect)?
    /// A drag inside the window (⌥-drag of a canvas item, text selection) never moves the window; only a drag that
    /// does is ours to tile. Confirmed once per drag, polled sparingly because a frame read is IPC into the app.
    private var windowMoved = false
    private var lastMoveCheck = Date.distantPast
    private var lastScrollSwitch = Date.distantPast
    /// The Mission Control key (keycode 160) when the overview has taken it over.
    var onOverviewKey: (() -> Void)?
    /// While true, scroll and gesture events are swallowed (a swipe is in progress or the overview is open).
    var swallowScrolling: () -> Bool = { false }

    /// What the tap thread needs to decide; written on the main thread, read under the lock on the tap thread.
    private struct TapState {
        var swallowScroll = false
        var dragging = false
        var dragFlags: CGEventFlags = []
        var overviewKey = false
        var recording = false
    }
    private var tapState = TapState()
    private var lock = os_unfair_lock()
    /// Tap-thread state: a scroll sequence that started while swallowing stays swallowed through its momentum,
    /// which outlives the fingers.
    private var swallowingSequence = false

    init(manager: WindowManager) { self.manager = manager }

    /// Call whenever something the tap decides on changed: the overview or slide opened or closed, fingers landed
    /// or lifted, a hotkey recorder took focus, the config changed. Also called after every event handled here.
    func refreshState() {
        let s = TapState(swallowScroll: swallowScrolling(), dragging: dragged != nil,
                         dragFlags: HotKey.eventFlags(manager.config.dragModifiers),
                         overviewKey: manager.config.overview && manager.config.overviewKey,
                         recording: KeyRecorderView.active != nil)
        os_unfair_lock_lock(&lock)
        tapState = s
        os_unfair_lock_unlock(&lock)
    }

    private var state: TapState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return tapState
    }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << 29) | (1 << 30) | (1 << 31)
            | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<DragController>.fromOpaque(refcon!).takeUnretainedValue()
                return me.decide(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }
        self.tap = tap
        refreshState()
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "betterwm.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        return true
    }

    // MARK: Tap thread

    private func decide(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let s = state
        if type.rawValue >= 29 && type.rawValue <= 31 { return s.swallowScroll ? nil : Unmanaged.passUnretained(event) }
        switch type {
        case .scrollWheel:
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            // Phases: 1 began, 2 changed, 4 ended, 8 cancelled. A plain mouse wheel has no phases and is judged on its own.
            if phase == 1 { swallowingSequence = s.swallowScroll }
            else if s.swallowScroll { swallowingSequence = true }
            let inSequence = phase != 0 || momentum != 0
            if inSequence ? swallowingSequence : s.swallowScroll {
                if momentum == 4 || momentum == 8 { swallowingSequence = false }
                return nil
            }
            // Modifier + scroll switches desktops; the switch itself happens on the main thread.
            guard event.flags.contains(s.dragFlags), !s.dragging else { return Unmanaged.passUnretained(event) }
            forward(type, event)
            return nil
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            forward(type, event)
            return (code == 160 && s.overviewKey) || s.recording ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            forward(type, event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func forward(_ type: CGEventType, _ event: CGEvent) {
        guard let copy = event.copy() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handle(type: type, event: copy)
            self?.refreshState()
        }
    }

    // MARK: Main thread

    private func handle(type: CGEventType, event: CGEvent) {
        let p = event.location
        let alt = event.flags.contains(HotKey.eventFlags(manager.config.dragModifiers))
        if type == .keyDown || type == .leftMouseDown {
            manager.lastUserInput = Date()
            // Only input that can bring another app forward: a click (Dock, window, notification), a ⌘ combo
            // (⌘Tab, ⌘`), or Return (Spotlight, Launchpad). Typing in the current app never switches apps.
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .leftMouseDown || event.flags.contains(.maskCommand) || key == 36 || key == 76 { manager.lastFocusInput = Date() }
        }
        switch type {
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if manager.config.overview, manager.config.overviewKey, code == 160 { onOverviewKey?(); return }
            // The tap swallowed the press for the recorder; a key it cannot record is simply lost.
            _ = KeyRecorderView.active?.record(keyCode: code, flags: event.flags)
        case .scrollWheel:
            guard alt, dragged == nil else { return }
            let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let delta = abs(dx) > abs(dy) ? dx : dy
            // Trackpads emit a burst per gesture; one step per burst.
            if delta != 0, Date().timeIntervalSince(lastScrollSwitch) > 0.35 {
                lastScrollSwitch = Date()
                manager.switchDesktop(next: delta < 0)
            }
        case .leftMouseDown:
            dragStart = p
            guard manager.enabled, let w = AXWindow.at(point: p) else { return }
            dragged = w
            draggedID = manager.id(w)
            originalFrame = w.frame
            currentZone = nil
            windowMoved = false
        case .leftMouseDragged:
            if dragged == nil, alt, manager.enabled, let w = AXWindow.focused {
                // Hit-testing failed on mouse-down; the window being dragged is the frontmost app's focused one.
                dragged = w
                draggedID = manager.id(w)
                manager.interacting = true
                originalFrame = w.frame
                windowMoved = false
            }
            guard let w = dragged else { return }
            // Clicks often carry a pixel of motion; only real movement suspends reconciling and the focus ring.
            if !manager.interacting, hypot(p.x - dragStart.x, p.y - dragStart.y) < 4 { return }
            manager.interacting = true
            if alt, !windowMoved, Date().timeIntervalSince(lastMoveCheck) > 0.1 {
                lastMoveCheck = Date()
                windowMoved = hypot(w.frame.minX - originalFrame.minX, w.frame.minY - originalFrame.minY) >= 4
            }
            if alt, windowMoved {
                currentZone = manager.zone(at: p, draggingID: draggedID)
                manager.overlay.show(zone: currentZone?.1)
            } else {
                currentZone = nil
                manager.overlay.hide()
            }
        case .leftMouseUp:
            let w = dragged
            dragged = nil
            manager.overlay.hide()
            let zone = currentZone?.0
            let original = originalFrame
            let id = draggedID
            // A click that changes the window's frame by itself (a fullscreen button, a double-click zoom) is
            // not the user placing it; only a press that carried the mouse at least 20pt is.
            let moved = manager.interacting
            let byHand = moved && hypot(p.x - dragStart.x, p.y - dragStart.y) >= 20
            let finish = { [manager] in
                manager.interacting = false
                if let w, let zone {
                    manager.drop(w, into: zone, at: p, from: original)
                } else if byHand {
                    // Only a window that actually moved or resized during this drag was placed by hand; one that
                    // was merely off its slot already (macOS moved it, it refused a size) must not be untiled.
                    if let id, let w, !w.frame.approximatelyEquals(original, tolerance: 10) { manager.releaseDisplacedWindow(id) }
                    // Only a plain drag or resize settles a new floating spot; a ⌥-drag that misses every zone does not.
                    if let w, !alt { manager.rememberFloatingFrame(w) }
                } else if moved {
                    // A nudge short of the threshold: tiled windows go straight back to their slots.
                    manager.apply()
                }
            }
            // Let the app complete its own move or resize before we inspect frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: finish)
        default:
            break
        }
    }
}
