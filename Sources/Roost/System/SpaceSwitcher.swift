import AppKit
import Carbon.HIToolbox

/// Remembers the previously active Space and switches back to it.
///
/// There's no public API for changing Spaces, so we use, in order:
/// 1. Mission Control's own "Switch to Desktop N" shortcut, when the user has it enabled in
///    System Settings › Keyboard › Keyboard Shortcuts › Mission Control. We read the key
///    binding from the system's preferences and press it for the user. Same animation and
///    behaviour as doing it by hand.
/// 2. Otherwise, bring forward a window that lives on that Space; macOS follows it there
///    (this also covers full-screen Spaces, which have no Desktop N shortcut).
@MainActor
final class SpaceSwitcher: NSObject {
    static let shared = SpaceSwitcher()
    private static let hotKeyID: UInt32 = 1

    private let settings = Settings.shared
    private let catalog = WindowCatalog()
    private var currentSpaceID: CGSSpaceID?
    private(set) var previousSpaceID: CGSSpaceID?
    private var isRecordingShortcut = false
    private var hasExplainedShortcuts = false
    /// What the last switch attempt did, shown in the menu while we debug this feature.
    private(set) var lastResult = "Not used yet"
    private(set) var isHotKeyRegistered = false

    private func note(_ message: String) {
        lastResult = message
        Log.spaces.notice("Switch back: \(message, privacy: .public)")
    }

    func start() {
        currentSpaceID = CGS.activeSpaceID()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateHotKey), name: .roostSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(recordingChanged(_:)), name: .roostShortcutRecording, object: nil)
        updateHotKey()
        if settings.previousSpaceShortcut != nil, !Permissions.canPostEvents {
            Permissions.requestPostEvents()
        }
    }

    /// The Space to go back to, if it still exists.
    var previousSpace: SpaceInfo? {
        previousSpaceID.flatMap { SpacesState.current().space(id: $0) }
    }

    @objc private func activeSpaceChanged() {
        guard let now = CGS.activeSpaceID(), now != currentSpaceID else {
            Log.spaces.info("Active Space notification, but active Space unchanged (\(CGS.activeSpaceID() ?? 0))")
            return
        }
        Log.spaces.info("Active Space \(self.currentSpaceID ?? 0) → \(now)")
        // Going back makes the Space we left the new "previous", so pressing the shortcut
        // repeatedly toggles between two Spaces.
        previousSpaceID = currentSpaceID
        currentSpaceID = now
    }

    @objc private func recordingChanged(_ note: Notification) {
        isRecordingShortcut = note.userInfo?["active"] as? Bool ?? false
        updateHotKey()
    }

    @objc private func updateHotKey() {
        guard let combo = settings.previousSpaceShortcut, !isRecordingShortcut else {
            HotKeyCenter.shared.unregister(id: Self.hotKeyID)
            isHotKeyRegistered = false
            return
        }
        isHotKeyRegistered = HotKeyCenter.shared.register(id: Self.hotKeyID, combo: combo) { [weak self] in
            Log.spaces.notice("Switch back: shortcut pressed")
            self?.switchToPreviousSpace()
        }
        Log.spaces.notice("Shortcut \(combo.display, privacy: .public) (key \(combo.keyCode), modifiers \(combo.carbonModifiers)) registered: \(self.isHotKeyRegistered)")
    }

    func switchToPreviousSpace() {
        guard let target = previousSpace else {
            note(previousSpaceID == nil ? "No previous Space recorded yet" : "Previous Space \(previousSpaceID ?? 0) no longer exists")
            NSSound.beep()
            return
        }
        switchTo(target)
    }

    func switchTo(_ space: SpaceInfo) {
        let label = "\(space.defaultName) (id \(space.id))"
        let shortcut = space.isFullscreen ? nil : MissionControlShortcuts.switchToDesktop(space.number)
        if shortcut != nil, !Permissions.canPostEvents {
            // Without this permission macOS silently drops the keystroke.
            Permissions.requestPostEvents()
        }
        if let shortcut, Permissions.canPostEvents {
            Task { @MainActor in
                // The user is probably still holding the modifiers of our own shortcut; let go
                // of them first so Mission Control sees exactly its shortcut.
                let released = await Self.waitForModifierRelease()
                shortcut.post()
                self.note("Pressed Mission Control shortcut (key \(shortcut.keyCode), flags \(shortcut.flags)) for \(label); "
                    + "modifiers released: \(released)")
            }
            return
        }
        let why = shortcut == nil ? "No Desktop \(space.number) shortcut" : "Not allowed to send keystrokes"
        if let app = bringForwardWindow(on: space) {
            note("\(why); brought forward a \(app) window on \(label)")
            return
        }
        note("\(why) and no window found on \(label); Accessibility: \(AXIsProcessTrusted())")
        NSSound.beep()
        if !AXIsProcessTrusted() || (shortcut != nil && !Permissions.canPostEvents) {
            explainMissingPermissions(for: space)
        } else {
            explainDesktopShortcuts(for: space)
        }
    }

    /// Returns the app name whose window was brought forward.
    private func bringForwardWindow(on space: SpaceInfo) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        // Front-to-back order, so this picks the window that was on top on that Space.
        for window in catalog.liveWindows() where window.spaces == [space.id] {
            guard let element = catalog.elements(for: [window])[window.id],
                  !element.isMinimized else { continue }
            element.set("AXMain", true)
            AXUIElementPerformAction(element, "AXRaise" as CFString)
            AXUIElementCreateApplication(window.pid).set("AXFrontmost", true)
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            return window.appName
        }
        return nil
    }

    private func explainMissingPermissions(for space: SpaceInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Roost can’t switch to \(SpaceNames.shared.displayName(for: space))"
        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("Accessibility access") }
        if !Permissions.canPostEvents { missing.append("permission to send keystrokes") }
        alert.informativeText = "Roost doesn’t have \(missing.joined(separator: " or ")). "
            + "Turn Roost on in System Settings › Privacy & Security › Accessibility.\n\n"
            + "If Roost already looks turned on there, it was probably rebuilt: macOS ties the permission "
            + "to the exact build. Remove Roost from the list with −, add it back, and relaunch Roost."
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.requestPostEvents()
            NSWorkspace.shared.open(SystemSettings.accessibilityURL)
        }
    }

    private func explainDesktopShortcuts(for space: SpaceInfo) {
        guard !hasExplainedShortcuts else { return }
        hasExplainedShortcuts = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Roost can’t switch to \(SpaceNames.shared.displayName(for: space))"
        alert.informativeText = "That Space has no windows to bring forward. Turn on “Switch to Desktop \(space.number)” " +
            "in System Settings › Keyboard › Keyboard Shortcuts › Mission Control and Roost will use it."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(SystemSettings.keyboardURL)
        }
    }

    /// Returns whether the modifiers were released within a second.
    private static func waitForModifierRelease() async -> Bool {
        for _ in 0..<40 {
            if NSEvent.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
}

/// Mission Control's "Switch to Desktop N" shortcuts, as configured in System Settings.
enum MissionControlShortcuts {
    struct Shortcut {
        var keyCode: UInt16
        var flags: UInt64

        func post() {
            let source = CGEventSource(stateID: .hidSystemState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
                event?.flags = CGEventFlags(rawValue: flags)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Symbolic hotkey ids 118…133 are "Switch to Desktop 1…16".
    static func switchToDesktop(_ number: Int) -> Shortcut? {
        guard (1...16).contains(number),
              let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(117 + number)] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count >= 3, parameters[1].intValue != 0xFFFF
        else { return nil }
        return Shortcut(keyCode: parameters[1].uint16Value, flags: parameters[2].uint64Value)
    }

    static func enabledDesktopNumbers() -> [Int] {
        (1...16).filter { switchToDesktop($0) != nil }
    }
}
