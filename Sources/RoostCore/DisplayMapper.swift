import CoreGraphics
import Foundation

/// Applies a layout saved for one display setup to a different one (e.g. home → office).
public enum DisplayMapper {
    /// Maps each display of `source` (by uuid) to a display of `target`:
    /// 1. the same physical display, if it's connected (typically the laptop's built-in screen),
    /// 2. built-in to built-in,
    /// 3. the remaining displays paired by where they sit in the arrangement (left to right,
    ///    then top to bottom),
    /// 4. any source displays left over go to the target display in the most similar position.
    public static func map(from source: DisplayConfiguration, to target: DisplayConfiguration) -> [String: DisplayInfo] {
        guard !target.displays.isEmpty else { return [:] }
        var result: [String: DisplayInfo] = [:]
        var sources = source.displays
        var targets = target.displays

        func pair(_ s: DisplayInfo, _ t: DisplayInfo) {
            result[s.uuid] = t
            sources.removeAll { $0.uuid == s.uuid }
            targets.removeAll { $0.uuid == t.uuid }
        }

        for s in sources {
            if let t = targets.first(where: { $0.uuid == s.uuid }) { pair(s, t) }
        }
        if let s = sources.first(where: \.isBuiltin), let t = targets.first(where: \.isBuiltin) {
            pair(s, t)
        }

        let sourceBounds = bounds(of: source.displays)
        let targetBounds = bounds(of: target.displays)
        func ordered(_ displays: [DisplayInfo], in bounds: CGRect) -> [DisplayInfo] {
            displays.sorted {
                let a = normalizedCenter($0, in: bounds), b = normalizedCenter($1, in: bounds)
                return abs(a.x - b.x) > 0.01 ? a.x < b.x : a.y < b.y
            }
        }
        for (s, t) in zip(ordered(sources, in: sourceBounds), ordered(targets, in: targetBounds)) {
            pair(s, t)
        }

        for s in sources {
            let c = normalizedCenter(s, in: sourceBounds)
            result[s.uuid] = target.displays.min { a, b in
                distance(normalizedCenter(a, in: targetBounds), c) < distance(normalizedCenter(b, in: targetBounds), c)
            }
        }
        return result
    }

    /// Higher is more alike: shared physical displays count most, then the same number of
    /// displays, then a built-in display on both sides.
    public static func similarity(_ a: DisplayConfiguration, _ b: DisplayConfiguration) -> Int {
        let shared = Set(a.displays.map(\.uuid)).intersection(b.displays.map(\.uuid)).count
        let sameCount = a.displays.count == b.displays.count ? 1 : 0
        let bothBuiltin = a.displays.contains(where: \.isBuiltin) == b.displays.contains(where: \.isBuiltin) ? 1 : 0
        return shared * 100 + sameCount * 10 + bothBuiltin - abs(a.displays.count - b.displays.count)
    }

    private static func bounds(of displays: [DisplayInfo]) -> CGRect {
        displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    private static func normalizedCenter(_ display: DisplayInfo, in bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: (display.frame.midX - bounds.minX) / bounds.width,
                       y: (display.frame.midY - bounds.minY) / bounds.height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
