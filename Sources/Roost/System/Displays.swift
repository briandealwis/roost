import AppKit
import RoostCore

enum Displays {
    /// The active displays (mirrored secondaries excluded) as a configuration.
    static func currentConfiguration() -> DisplayConfiguration {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplayConfiguration(displays: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplayConfiguration(displays: [])
        }

        var seen: [String: Int] = [:]
        var displays: [DisplayInfo] = []
        for id in ids.prefix(Int(count)) {
            if CGDisplayIsInMirrorSet(id) != 0, CGDisplayMirrorsDisplay(id) != 0 { continue }
            var uuid = uuidString(for: id) ?? "display-\(id)"
            // Two identical monitors without serial numbers can share a UUID.
            let n = seen[uuid, default: 0]
            seen[uuid] = n + 1
            if n > 0 { uuid += "~\(n)" }
            displays.append(DisplayInfo(uuid: uuid, name: name(for: id), frame: CGDisplayBounds(id),
                                        isBuiltin: CGDisplayIsBuiltin(id) != 0))
        }
        return DisplayConfiguration(displays: displays)
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return (string as String).uppercased()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(forDisplayUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            displayID(of: screen).flatMap(uuidString(for:)) == uuid.uppercased()
        }
    }

    static var mainDisplayUUID: String? { uuidString(for: CGMainDisplayID()) }

    private static func name(for id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { displayID(of: $0) == id }?.localizedName ?? "Display \(id)"
    }
}
