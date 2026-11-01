import Cocoa

/// Shows and hides the chrome windows (ring, tab strips, action buttons) through a short alpha fade. A hide
/// that is still fading when the window is shown again is cancelled, so quick toggles never leave one hidden.
enum Fade {
    static var enabled = true
    static let duration = 0.15
    private static var generation: [Int: Int] = [:]
    /// Windows mid fade-out: still visible, and `alphaValue` reads 1 until the animation writes it back.
    private static var hiding: Set<Int> = []

    /// Orders the window in with `order` and fades it to full alpha; a plain order when fades are off.
    static func show(_ w: NSWindow, _ order: () -> Void) {
        generation[w.windowNumber, default: 0] += 1
        let wasHiding = hiding.remove(w.windowNumber) != nil
        guard enabled else { order(); w.alphaValue = 1; return }
        if w.isVisible, !wasHiding { order(); return }
        if !w.isVisible { w.alphaValue = 0 }
        order()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            w.animator().alphaValue = 1
        }
    }

    /// `done` runs once the window is ordered out; not at all if a show cancels the fade.
    static func hide(_ w: NSWindow, done: (() -> Void)? = nil) {
        guard w.isVisible else { done?(); return }
        generation[w.windowNumber, default: 0] += 1
        guard enabled else { w.orderOut(nil); done?(); return }
        let mine = generation[w.windowNumber]!
        hiding.insert(w.windowNumber)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            w.animator().alphaValue = 0
        }, completionHandler: {
            guard generation[w.windowNumber] == mine else { return }
            hiding.remove(w.windowNumber)
            w.orderOut(nil)
            done?()
        })
    }
}
