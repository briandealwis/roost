import CoreGraphics
import Foundation

public enum Geometry {
    /// Where a saved window should go on `display` (global coordinates).
    /// Keeps the saved offset from the display origin, shrinks the window if it no longer
    /// fits and nudges it back on screen if it would otherwise be invisible.
    ///
    /// When the layout was saved on a different display (`source`) of another size, position and
    /// size are scaled proportionally, so e.g. a window filling the left half still does.
    public static func targetFrame(for record: WindowRecord, on display: DisplayInfo, from source: DisplayInfo? = nil) -> CGRect {
        let d = display.frame
        var rel = record.frameInDisplay
        if let source, source.frame.width > 0, source.frame.height > 0, source.frame.size != d.size {
            let sx = d.width / source.frame.width
            let sy = d.height / source.frame.height
            rel = CGRect(x: rel.minX * sx, y: rel.minY * sy, width: rel.width * sx, height: rel.height * sy)
        }
        var f = CGRect(x: d.minX + rel.minX,
                       y: d.minY + rel.minY,
                       width: min(rel.width, d.width),
                       height: min(rel.height, d.height))
        if !f.intersects(d) || f.minY < d.minY || f.minY > d.maxY - 20 {
            f.origin.x = min(max(f.minX, d.minX), d.maxX - f.width)
            f.origin.y = min(max(f.minY, d.minY), d.maxY - f.height)
        }
        return f
    }

    public static func relative(_ frame: CGRect, to display: DisplayInfo) -> CGRect {
        frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// The display containing most of `frame`, or the nearest one if it's off screen.
    public static func bestDisplay(for frame: CGRect, among displays: [DisplayInfo]) -> DisplayInfo? {
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        if let best = displays.max(by: { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }),
           area(best.frame.intersection(frame)) > 0 {
            return best
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { distance($0.frame, center) < distance($1.frame, center) }
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
