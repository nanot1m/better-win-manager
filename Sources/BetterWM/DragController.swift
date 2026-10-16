import BetterWMCore
import Cocoa

final class DragController {
    private let manager: WindowManager
    private var tap: CFMachPort?
    private var dragged: AXWindow?
    private var draggedID: WindowID?
    private var dragStart: CGPoint = .zero
    private var originalFrame: CGRect = .zero
    private var intercepting = false
    private var currentZone: (DropZone, CGRect)?
    private var lastScrollSwitch = Date.distantPast
    /// AX moves are synchronous IPC into the target app; done inside the tap callback they stall every event in
    /// the system, so they run off-thread and only the latest position is applied.
    private let moveQueue = DispatchQueue(label: "betterwm.drag", qos: .userInteractive)
    private let moveLock = NSLock()
    private var pendingOrigin: CGPoint?
    private var moveInFlight = false

    private func scheduleMove(_ w: AXWindow, to origin: CGPoint) {
        moveLock.lock()
        pendingOrigin = origin
        let start = !moveInFlight
        moveInFlight = true
        moveLock.unlock()
        guard start else { return }
        moveQueue.async { [self] in
            while true {
                moveLock.lock()
                guard let o = pendingOrigin else { moveInFlight = false; moveLock.unlock(); return }
                pendingOrigin = nil
                moveLock.unlock()
                w.setOrigin(o)
            }
        }
    }

    init(manager: WindowManager) { self.manager = manager }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<DragController>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
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
            // Feed an active hotkey recorder before macOS gets a chance to treat the press as a system shortcut.
            guard let recorder = KeyRecorderView.active else { return Unmanaged.passUnretained(event) }
            let consumed = recorder.record(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
            return consumed ? nil : Unmanaged.passUnretained(event)
        case .scrollWheel:
            guard alt, dragged == nil else { return Unmanaged.passUnretained(event) }
            let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let delta = abs(dx) > abs(dy) ? dx : dy
            // Trackpads emit a burst per gesture; one step per burst.
            if delta != 0, Date().timeIntervalSince(lastScrollSwitch) > 0.35 {
                lastScrollSwitch = Date()
                manager.switchDesktop(next: delta < 0)
            }
            return nil
        case .leftMouseDown:
            dragStart = p
            guard manager.enabled, let w = AXWindow.at(point: p) else { return Unmanaged.passUnretained(event) }
            dragged = w
            draggedID = manager.id(w)
            dragStart = p
            originalFrame = w.frame
            currentZone = nil
            // Without Option the app runs its own drag; we only watch in case Option is pressed later.
            intercepting = alt
            return alt ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            if dragged == nil, alt, manager.enabled, let w = AXWindow.focused {
                // Hit-testing failed on mouse-down; the window being dragged is the frontmost app's focused one.
                dragged = w
                draggedID = manager.id(w)
                manager.interacting = true
                originalFrame = w.frame
            }
            guard let w = dragged else { return Unmanaged.passUnretained(event) }
            // Clicks often carry a pixel of motion; only real movement suspends reconciling and the focus ring.
            if !manager.interacting, hypot(p.x - dragStart.x, p.y - dragStart.y) < 4 {
                return intercepting ? nil : Unmanaged.passUnretained(event)
            }
            manager.interacting = true
            if intercepting {
                let dx = p.x - dragStart.x, dy = p.y - dragStart.y
                scheduleMove(w, to: CGPoint(x: originalFrame.minX + dx, y: originalFrame.minY + dy))
            }
            if intercepting || alt {
                currentZone = manager.zone(at: p, draggingID: draggedID)
                manager.overlay.show(zone: currentZone?.1)
            } else {
                currentZone = nil
                manager.overlay.hide()
            }
            return intercepting ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp:
            let w = dragged
            dragged = nil
            manager.overlay.hide()
            let zone = currentZone?.0
            let wasIntercepting = intercepting
            intercepting = false
            let original = originalFrame
            let finish = { [manager] in
                manager.interacting = false
                if let w, let zone {
                    manager.drop(w, into: zone, at: p, from: original)
                } else {
                    manager.releaseDisplacedWindows()
                    // Only a plain drag or resize settles a new floating spot; a ⌥-drag that misses every zone does not.
                    if let w, !wasIntercepting { manager.rememberFloatingFrame(w) }
                }
            }
            if wasIntercepting {
                moveQueue.sync {}
                finish()
                return nil
            }
            // Let the app complete its own move or resize before we inspect frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: finish)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
