import CoreGraphics
import Foundation

/// One physical display, as seen at snapshot time.
/// `frame` is in global CoreGraphics coordinates (origin top-left of the main display, y grows down),
/// which is the same space the Accessibility API uses for window positions.
public struct DisplayInfo: Codable, Equatable {
    public var uuid: String
    public var name: String
    public var frame: CGRect
    public var isBuiltin: Bool

    public init(uuid: String, name: String, frame: CGRect, isBuiltin: Bool) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.isBuiltin = isBuiltin
    }
}

/// A particular combination *and arrangement* of displays.
///
/// The key includes each display's position and size, so re-arranging displays in
/// System Settings (or changing resolution) produces a new configuration. The old one
/// simply stops being seen and is pruned once it exceeds the retention period.
public struct DisplayConfiguration: Codable, Equatable {
    public private(set) var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays.sorted { $0.uuid < $1.uuid }
    }

    public var key: String {
        displays.map { d in
            let f = d.frame
            return "\(d.uuid)@\(Int(f.minX.rounded())),\(Int(f.minY.rounded())):\(Int(f.width.rounded()))x\(Int(f.height.rounded()))"
        }.joined(separator: "|")
    }

    /// e.g. "Built-in Retina Display + DELL U2720Q"
    public var summary: String {
        let ordered = displays.sorted { a, b in
            if a.isBuiltin != b.isBuiltin { return a.isBuiltin }
            return a.frame.minX < b.frame.minX
        }
        return ordered.map(\.name).joined(separator: " + ")
    }

    public func display(uuid: String) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }
}

/// A window's saved placement.
public struct WindowRecord: Codable, Equatable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String?
    /// Global frame at snapshot time.
    public var frame: CGRect
    public var displayUUID: String
    /// Frame relative to the display's origin.
    public var frameInDisplay: CGRect
    /// Stable Space identifier (empty for some built-in spaces), its WindowServer id and
    /// its position among the user desktops of its display.
    public var spaceUUID: String?
    public var spaceID: UInt64?
    public var spaceIndex: Int?
    /// n-th window of this app in front-to-back order. Used only as a last-resort match.
    public var ordinal: Int

    public init(windowID: UInt32, pid: Int32, bundleID: String?, appName: String, title: String?,
                frame: CGRect, displayUUID: String, frameInDisplay: CGRect,
                spaceUUID: String?, spaceID: UInt64?, spaceIndex: Int?, ordinal: Int) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.displayUUID = displayUUID
        self.frameInDisplay = frameInDisplay
        self.spaceUUID = spaceUUID
        self.spaceID = spaceID
        self.spaceIndex = spaceIndex
        self.ordinal = ordinal
    }
}

public struct LayoutSnapshot: Codable, Equatable {
    public var createdAt: Date
    public var reason: String
    public var windows: [WindowRecord]

    public init(createdAt: Date, reason: String, windows: [WindowRecord]) {
        self.createdAt = createdAt
        self.reason = reason
        self.windows = windows
    }
}

public struct SavedLayout: Codable, Equatable {
    public var configuration: DisplayConfiguration
    public var snapshot: LayoutSnapshot
    /// Last time this display configuration was active. Drives pruning.
    public var lastSeen: Date

    public var key: String { configuration.key }

    public init(configuration: DisplayConfiguration, snapshot: LayoutSnapshot, lastSeen: Date) {
        self.configuration = configuration
        self.snapshot = snapshot
        self.lastSeen = lastSeen
    }
}

public enum SpaceIdentity {
    /// Key used to remember a Space's name. macOS gives most Spaces a persistent UUID;
    /// the very first desktop of a display may have an empty one, so fall back to
    /// display + position.
    public static func key(uuid: String, displayUUID: String, index: Int) -> String {
        uuid.isEmpty ? "display:\(displayUUID)#\(index)" : uuid
    }
}
