import Cocoa

/// Shows and hides the chrome windows (ring, tab strips, action buttons) through a short alpha fade. A hide
/// that is still fading when the window is shown again is cancelled, so quick toggles never leave one hidden.
enum Fade {
    /// The `fadeAnimations` setting; Reduce Motion in System Settings turns every transition off as well.
    static var configured = true
    static var enabled: Bool { configured && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let duration = 0.15
    static let curve = CAMediaTimingFunction(name: .easeOut)

    /// Animates a layer property from its current (presented) value to `to`, which is also set as the model value.
    static func animate(_ layer: CALayer, _ keyPath: String, to: Any, duration: TimeInterval = duration) {
        if enabled, let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath) {
            let anim = CABasicAnimation(keyPath: keyPath)
            anim.fromValue = from
            anim.toValue = to
            anim.duration = duration
            anim.timingFunction = curve
            layer.add(anim, forKey: keyPath)
        }
        layer.setValue(to, forKeyPath: keyPath)
    }

    /// Moves a window to `frame` with an eased slide when fades are on and the window is already up.
    static func move(_ w: NSWindow, to frame: NSRect) {
        guard enabled, w.isVisible, w.frame != frame else { w.setFrame(frame, display: false); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = curve
            w.animator().setFrame(frame, display: false)
        }
    }
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
            ctx.timingFunction = curve
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
