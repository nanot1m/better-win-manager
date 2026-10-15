import Cocoa

/// Frames cut from a user-supplied sprite sheet laid out like Last tick's "Pixel Cats 64x64" pack
/// (14 columns of 64x64 cells, one animation per row). The art is never bundled; only the path is configured.
struct CatSheet {
    struct Row { let index: Int; let frames: Int }
    /// Rows for side-view animations, ordered by on-screen facing (right, then left). Only the walk
    /// rows are labelled the other way round in the pack.
    static let walk = (Row(index: 5, frames: 6), Row(index: 4, frames: 6))
    static let run = (Row(index: 10, frames: 5), Row(index: 11, frames: 5))
    static let sit = (Row(index: 22, frames: 5), Row(index: 21, frames: 5))
    static let groom = (Row(index: 41, frames: 11), Row(index: 39, frames: 11))
    static let lie = (Row(index: 28, frames: 3), Row(index: 27, frames: 3))
    static let sleep = (Row(index: 51, frames: 2), Row(index: 50, frames: 2))
    /// Body region shared by every side-view row, so sprites keep a common baseline.
    static let crop = CGRect(x: 4, y: 8, width: 56, height: 40)
    static let cell: CGFloat = 64

    var frames: [String: [NSImage]] = [:]
    let spriteSize: NSSize

    func frames(_ name: String, right: Bool) -> [NSImage] { frames[name + (right ? "R" : "L")] ?? [] }

    init?(path: String, scale: CGFloat) {
        guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first as? NSBitmapImageRep else { return nil }
        let rowsInSheet = rep.pixelsHigh / Int(CatSheet.cell)
        spriteSize = NSSize(width: CatSheet.crop.width * scale, height: CatSheet.crop.height * scale)
        func cut(_ row: Row) -> [NSImage]? {
            guard row.index < rowsInSheet else { return nil }
            return (0..<row.frames).map { i in
                // Image coordinates are bottom-left; sheet rows are counted from the top.
                let src = CGRect(x: CGFloat(i) * CatSheet.cell + CatSheet.crop.minX,
                                 y: CGFloat(rep.pixelsHigh) - CGFloat(row.index + 1) * CatSheet.cell + (CatSheet.cell - CatSheet.crop.maxY),
                                 width: CatSheet.crop.width, height: CatSheet.crop.height)
                return NSImage(size: spriteSize, flipped: false) { dst in
                    NSGraphicsContext.current?.imageInterpolation = .none
                    img.draw(in: dst, from: src, operation: .sourceOver, fraction: 1)
                    return true
                }
            }
        }
        for (name, rows) in [("walk", CatSheet.walk), ("run", CatSheet.run), ("sit", CatSheet.sit),
                             ("groom", CatSheet.groom), ("lie", CatSheet.lie), ("sleep", CatSheet.sleep)] {
            guard let r = cut(rows.0), let l = cut(rows.1) else { return nil }
            frames[name + "R"] = r
            frames[name + "L"] = l
        }
    }
}
