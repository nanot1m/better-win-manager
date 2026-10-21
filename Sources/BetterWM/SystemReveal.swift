import Cocoa

/// Detects Show Desktop: while it is active the Dock owns an extra on-screen window at layer 18 that exists at no
/// other time. Starting it emits a window-level event, which triggers the check; ending it emits nothing, so a
/// short poll runs only while it is active.
final class SystemReveal {
    private let events = WindowServerEvents()
    private(set) var active = false { didSet { if active != oldValue { onChange?(active) } } }
    var onChange: ((Bool) -> Void)?
    private var pending = false
    private var poll: Timer?

    init() {
        events.onEvent = { [weak self] event, _ in
            guard [.windowLevel, .windowCreate, .windowReorder].contains(event) else { return }
            self?.scheduleCheck()
        }
    }

    private func scheduleCheck() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.active = SystemReveal.isShowingDesktop()
            if self.active, self.poll == nil {
                self.poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if !SystemReveal.isShowingDesktop() {
                        t.invalidate()
                        self.poll = nil
                        self.active = false
                    }
                }
            }
        }
    }

    static func isShowingDesktop() -> Bool {
        // Show Desktop puts a Dock-owned window at this layer for as long as the desktop is revealed.
        CGWindowInfo.list(.optionOnScreenOnly).contains { $0.owner == "Dock" && $0.layer == 18 }
    }
}
