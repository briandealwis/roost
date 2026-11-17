import AppKit

enum SystemSettings {
    static let displaysURL = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboardURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    static let missionControlURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
    private static let bundleID = "com.apple.systempreferences"

    static func openDisplays() {
        NSWorkspace.shared.open(displaysURL)
    }

    /// Opens Displays and, if we have Accessibility access, presses its "Arrange…" button so
    /// the arrangement sheet opens directly. There's no URL for that sheet, so we find the
    /// button in System Settings' accessibility tree. The button only exists with 2+ displays;
    /// if it can't be found we simply leave the Displays pane open.
    @MainActor
    static func openDisplayArrangement() {
        openDisplays()
        guard AXIsProcessTrusted(), NSScreen.screens.count > 1 else { return }
        Task { @MainActor in
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.5)
                if let button = findArrangeButton(in: root) {
                    button.press()
                    return
                }
            }
            Log.system.notice("Couldn't find the Arrange button in System Settings")
        }
    }

    /// "Arrange…" in the languages we know; the identifier check covers the rest if Apple sets one.
    private static let arrangeTitles = [
        "arrange", "anordnen", "disposer", "organizar", "disponi", "rangschik", "ordna", "arranger",
        "järjestä", "uspořádat", "rozmieść", "упорядочить", "расположить", "düzenle", "配置", "排列", "정렬",
    ]

    private static func findArrangeButton(in root: AXUIElement) -> AXUIElement? {
        var queue = root.elements("AXWindows")
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if element.role == "AXButton" {
                let identifier = element.string("AXIdentifier")?.lowercased() ?? ""
                let labels = [element.title, element.string("AXDescription")].compactMap { $0?.lowercased() }
                if identifier.contains("arrange") ||
                    labels.contains(where: { label in arrangeTitles.contains { label.hasPrefix($0) } }) {
                    return element
                }
            }
            queue.append(contentsOf: element.elements("AXChildren"))
        }
        return nil
    }
}

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time; afterwards macOS just returns the current state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Sending keystrokes (used to press Mission Control's "Switch to Desktop N") is a separate
    /// permission from Accessibility, although both are listed under Privacy & Security ›
    /// Accessibility. macOS only adds an app to that list once it asks for it.
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Shows the system prompt the first time; afterwards macOS just returns the current state.
    @discardableResult
    static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }
}
