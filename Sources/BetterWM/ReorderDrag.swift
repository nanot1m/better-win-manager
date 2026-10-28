import Cocoa

/// Drag-to-reorder for a row or column of sibling views: the grabbed view follows the pointer, the others slide
/// aside to show where it will land, and on release it glides into its slot. Works on layer transforms only, so
/// the owner re-lays its views out once the drop is reported and the transforms are cleared together.
final class ReorderDrag {
    private let items: [NSView]
    private let index: Int
    private let horizontal: Bool
    private let frames: [CGRect]
    private let step: CGFloat
    private var shifts: [CGFloat]
    private(set) var target: Int
    var grabbed: NSView { items[index] }
    private static let duration = 0.16

    /// `items` in visual order along the axis; `index` is the grabbed one.
    init(items: [NSView], index: Int, horizontal: Bool) {
        self.items = items
        self.index = index
        self.horizontal = horizontal
        frames = items.map(\.frame)
        let gap = items.count > 1 ? (horizontal ? frames[1].minX - frames[0].maxX : frames[1].minY - frames[0].maxY) : 0
        step = (horizontal ? frames[index].width : frames[index].height) + max(0, gap)
        shifts = Array(repeating: 0, count: items.count)
        target = index
        items[index].layer?.zPosition = 10
        items[index].alphaValue = 0.85
    }

    /// `delta`: pointer travel along the axis since the press.
    func update(delta: CGFloat) {
        let grabbed = items[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grabbed.layer?.setAffineTransform(horizontal ? CGAffineTransform(translationX: delta, y: 0) : CGAffineTransform(translationX: 0, y: delta))
        CATransaction.commit()
        let centre = (horizontal ? frames[index].midX : frames[index].midY) + delta
        var t = 0
        for (j, f) in frames.enumerated() where j != index {
            if (horizontal ? f.midX : f.midY) < centre { t += 1 }
        }
        target = t
        for j in items.indices where j != index {
            let shift: CGFloat = j > index && j <= target ? -step : (j < index && j >= target ? step : 0)
            if shift != shifts[j] {
                shifts[j] = shift
                animate(items[j], to: shift)
            }
        }
        CATransaction.flush()
    }

    /// Glides the grabbed view into its slot, then reports the slot it landed in. The owner reorders its views and
    /// calls `settle()` from its next `layout()`: AppKit applies view frames to layers during the display pass, so
    /// clearing the transforms any earlier shows the old positions for a frame.
    func end(_ completion: @escaping (Int) -> Void) {
        let final: CGFloat
        if target > index {
            final = (horizontal ? frames[target].maxX - frames[index].width - frames[index].minX : frames[target].maxY - frames[index].height - frames[index].minY)
        } else {
            final = (horizontal ? frames[target].minX - frames[index].minX : frames[target].minY - frames[index].minY)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in completion(target) }
        animate(items[index], to: final)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Clears every transform once the views sit at their new frames.
    func settle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in items { v.layer?.setAffineTransform(.identity); v.layer?.removeAllAnimations() }
        items[index].layer?.zPosition = 0
        items[index].alphaValue = 1
        CATransaction.commit()
    }

    /// AppKit's layer-backed views swallow implicit animations; an explicit one from the presented value does it.
    private func animate(_ v: NSView, to offset: CGFloat) {
        guard let layer = v.layer else { return }
        let to = horizontal ? CATransform3DMakeTranslation(offset, 0, 0) : CATransform3DMakeTranslation(0, offset, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = to
        anim.duration = Self.duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = to
        layer.add(anim, forKey: "reorder")
    }
}
