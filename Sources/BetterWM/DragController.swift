import BetterWMCore
import Cocoa

final class DragController {
    private let manager: WindowManager
    private var tap: CFMachPort?
    private var dragged: AXWindow?
    private var dragStart: CGPoint = .zero
    private var originalFrame: CGRect = .zero
    private var intercepting = false
    private var currentZone: (DropZone, CGRect)?
    private var lastScrollSwitch = Date.distantPast

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
        if type == .keyDown || type == .leftMouseDown { manager.lastUserInput = Date() }
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
                w.frame = CGRect(origin: CGPoint(x: originalFrame.minX + dx, y: originalFrame.minY + dy), size: originalFrame.size)
            }
            if intercepting || alt {
                currentZone = manager.zone(at: p, dragging: w)
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
            let finish = { [manager] in
                manager.interacting = false
                if let w, let zone {
                    manager.drop(w, into: zone, at: p)
                } else {
                    manager.releaseDisplacedWindows()
                }
            }
            if wasIntercepting {
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
