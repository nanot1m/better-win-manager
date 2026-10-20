import Cocoa

/// Frames cut from a user-supplied sprite sheet laid out like Last tick's "Pixel Cats 64x64" pack
/// (14 columns of 64x64 cells, one animation per row). The art is never bundled; only the path is configured.
struct CatSheet {
    /// Animations by name, as (row facing right, row facing left) indices in the pack. Front-facing animations
    /// use the same row for both. Frame counts are read off the sheet by looking for empty cells.
    /// Only the walk rows are labelled the other way round in the pack.
    static let rows: [String: (right: Int, left: Int)] = [
        "walk": (5, 4), "run": (10, 11),
        "sit": (22, 21),              // tail wag, sitting
        "alert": (26, 25),            // tail wag, standing
        "lie": (28, 27),              // tail wag, lying
        "groom": (41, 39),            // left paw swipe, sitting
        "groom2": (42, 40),           // right paw swipe, sitting
        "swipe": (34, 32),            // paw swipe, standing
        "scratch": (18, 17),
        "sleep1": (45, 44), "sleep2": (49, 48), "sleep3": (51, 50), "sleep4": (53, 52), "sleep5": (55, 54),
        "eat": (59, 58),
        "hiss": (61, 60),
        "jump": (64, 63),
        "lick": (12, 12), "lickLie": (13, 13), "meow": (14, 14), "meowStand": (16, 16), "yawn": (43, 43), "hind": (65, 65),
    ]
    /// Body region shared by every row, so sprites keep a common baseline.
    static let crop = CGRect(x: 4, y: 8, width: 56, height: 40)
    static let cell: CGFloat = 64

    var frames: [String: [NSImage]] = [:]
    let spriteSize: NSSize

    func frames(_ name: String, right: Bool) -> [NSImage] { frames[name + (right ? "R" : "L")] ?? [] }
    func has(_ name: String) -> Bool { !(frames[name + "R"] ?? []).isEmpty }

    init?(path: String, scale: CGFloat) {
        guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first as? NSBitmapImageRep else { return nil }
        img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let cellPx = Int(CatSheet.cell)
        let rowsInSheet = rep.pixelsHigh / cellPx, colsInSheet = rep.pixelsWide / cellPx
        spriteSize = NSSize(width: CatSheet.crop.width * scale, height: CatSheet.crop.height * scale)
        // A cell with any opaque pixel is a frame; the first empty cell ends the row's animation.
        func frameCount(_ row: Int) -> Int {
            var n = 0
            columns: for col in 0..<colsInSheet {
                var opaque = false
                for y in stride(from: row * cellPx, to: (row + 1) * cellPx, by: 4) {
                    for x in stride(from: col * cellPx, to: (col + 1) * cellPx, by: 4) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        opaque = true; break
                    }
                    if opaque { break }
                }
                if !opaque { break columns }
                n += 1
            }
            return n
        }
        func cut(_ row: Int) -> [NSImage]? {
            guard row < rowsInSheet else { return nil }
            let count = frameCount(row)
            guard count > 0 else { return nil }
            return (0..<count).map { i in
                // Image coordinates are bottom-left; sheet rows are counted from the top.
                let src = CGRect(x: CGFloat(i) * CatSheet.cell + CatSheet.crop.minX,
                                 y: CGFloat(rep.pixelsHigh) - CGFloat(row + 1) * CatSheet.cell + (CatSheet.cell - CatSheet.crop.maxY),
                                 width: CatSheet.crop.width, height: CatSheet.crop.height)
                return NSImage(size: spriteSize, flipped: false) { dst in
                    NSGraphicsContext.current?.imageInterpolation = .none
                    img.draw(in: dst, from: src, operation: .sourceOver, fraction: 1)
                    return true
                }
            }
        }
        for (name, rows) in CatSheet.rows {
            // The six core animations are required; the rest are optional extras a shorter sheet may lack.
            let required = ["walk", "run", "sit", "groom", "lie", "sleep3"].contains(name)
            guard let r = cut(rows.right), let l = cut(rows.left) else { if required { return nil } else { continue } }
            frames[name + "R"] = r
            frames[name + "L"] = l
        }
        frames["sleepR"] = frames["sleep3R"]; frames["sleepL"] = frames["sleep3L"]
    }
}
