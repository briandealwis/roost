import AppKit
import Combine

enum LabelStyle: String, CaseIterable {
    case watermark, badge
    var title: String { self == .watermark ? "Large, behind windows" : "Small badge, above windows" }
}

enum LabelPosition: String, CaseIterable {
    case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight
    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }
}

extension Notification.Name {
    static let roostSettingsChanged = Notification.Name("RoostSettingsChanged")
    static let roostSpaceNamesChanged = Notification.Name("RoostSpaceNamesChanged")
}

/// UserDefaults-backed preferences. Every setter posts `.roostSettingsChanged`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let autoRestore = "autoRestore"
        static let moveAcrossSpaces = "moveAcrossSpaces"
        static let snapshotInterval = "snapshotIntervalSeconds"
        static let retentionDays = "retentionDays"
        static let spaceNamesEnabled = "spaceNamesEnabled"
        static let showNameInMenuBar = "showSpaceNameInMenuBar"
        static let showLabels = "showSpaceLabels"
        static let labelUnnamed = "labelUnnamedSpaces"
        static let labelStyle = "spaceLabelStyle"
        static let labelPosition = "spaceLabelPosition"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.autoRestore: true,
            Key.moveAcrossSpaces: true,
            Key.snapshotInterval: 120,
            Key.retentionDays: 30,
            Key.spaceNamesEnabled: true,
            Key.showNameInMenuBar: true,
            Key.showLabels: true,
            Key.labelUnnamed: false,
            Key.labelStyle: LabelStyle.watermark.rawValue,
            Key.labelPosition: LabelPosition.bottomRight.rawValue,
        ])
    }

    private func set(_ value: Any, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .roostSettingsChanged, object: nil)
    }

    var autoRestore: Bool {
        get { defaults.bool(forKey: Key.autoRestore) }
        set { set(newValue, Key.autoRestore) }
    }

    var moveAcrossSpaces: Bool {
        get { defaults.bool(forKey: Key.moveAcrossSpaces) }
        set { set(newValue, Key.moveAcrossSpaces) }
    }

    /// Seconds between background snapshots; 0 disables them.
    var snapshotInterval: Int {
        get { defaults.integer(forKey: Key.snapshotInterval) }
        set { set(newValue, Key.snapshotInterval) }
    }

    /// Forget a display setup that hasn't been seen for this many days; 0 = never.
    var retentionDays: Int {
        get { defaults.integer(forKey: Key.retentionDays) }
        set { set(newValue, Key.retentionDays) }
    }

    var retention: TimeInterval? { retentionDays > 0 ? TimeInterval(retentionDays) * 86_400 : nil }

    /// Master switch for the Space naming feature.
    var spaceNamesEnabled: Bool {
        get { defaults.bool(forKey: Key.spaceNamesEnabled) }
        set { set(newValue, Key.spaceNamesEnabled) }
    }

    var showNameInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showNameInMenuBar) }
        set { set(newValue, Key.showNameInMenuBar) }
    }

    var showLabels: Bool {
        get { defaults.bool(forKey: Key.showLabels) }
        set { set(newValue, Key.showLabels) }
    }

    /// Also show "Desktop N" on Spaces that haven't been named.
    var labelUnnamedSpaces: Bool {
        get { defaults.bool(forKey: Key.labelUnnamed) }
        set { set(newValue, Key.labelUnnamed) }
    }

    var labelStyle: LabelStyle {
        get { LabelStyle(rawValue: defaults.string(forKey: Key.labelStyle) ?? "") ?? .watermark }
        set { set(newValue.rawValue, Key.labelStyle) }
    }

    var labelPosition: LabelPosition {
        get { LabelPosition(rawValue: defaults.string(forKey: Key.labelPosition) ?? "") ?? .bottomRight }
        set { set(newValue.rawValue, Key.labelPosition) }
    }
}

/// User-chosen Space names, keyed by the Space's persistent identity.
@MainActor
final class SpaceNames {
    static let shared = SpaceNames()
    private let key = "spaceNames"
    private var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func customName(for space: SpaceInfo) -> String? { names[space.nameKey] }

    func displayName(for space: SpaceInfo) -> String { customName(for: space) ?? space.defaultName }

    func setName(_ name: String?, for space: SpaceInfo) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[space.nameKey] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: key)
        NotificationCenter.default.post(name: .roostSpaceNamesChanged, object: nil)
    }
}
