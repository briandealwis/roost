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

    func start() {
        currentSpaceID = CGS.activeSpaceID()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateHotKey), name: .roostSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(recordingChanged(_:)), name: .roostShortcutRecording, object: nil)
        updateHotKey()
    }

    /// The Space to go back to, if it still exists.
    var previousSpace: SpaceInfo? {
        previousSpaceID.flatMap { SpacesState.current().space(id: $0) }
    }

    @objc private func activeSpaceChanged() {
        guard let now = CGS.activeSpaceID(), now != currentSpaceID else { return }
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
            return
        }
        HotKeyCenter.shared.register(id: Self.hotKeyID, combo: combo) { [weak self] in
            self?.switchToPreviousSpace()
        }
    }

    func switchToPreviousSpace() {
        guard let target = previousSpace else {
            NSSound.beep()
            return
        }
        switchTo(target)
    }

    func switchTo(_ space: SpaceInfo) {
        if !space.isFullscreen, let shortcut = MissionControlShortcuts.switchToDesktop(space.number) {
            Task { @MainActor in
                // The user is probably still holding the modifiers of our own shortcut; let go
                // of them first so Mission Control sees exactly its shortcut.
                await Self.waitForModifierRelease()
                shortcut.post()
            }
            return
        }
        if bringForwardWindow(on: space) { return }
        NSSound.beep()
        explainDesktopShortcuts(for: space)
    }

    private func bringForwardWindow(on space: SpaceInfo) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // Front-to-back order, so this picks the window that was on top on that Space.
        for window in catalog.liveWindows() where window.spaces == [space.id] {
            guard let element = catalog.elements(for: [window])[window.id],
                  !element.isMinimized else { continue }
            element.set("AXMain", true)
            AXUIElementPerformAction(element, "AXRaise" as CFString)
            AXUIElementCreateApplication(window.pid).set("AXFrontmost", true)
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            return true
        }
        return false
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

    private static func waitForModifierRelease() async {
        for _ in 0..<40 where !NSEvent.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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
