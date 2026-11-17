import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: a virtual key code plus Command/Option/Control/Shift.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to `relevantModifiers`.
    var modifiers: UInt
    /// e.g. "⌥⌘F3"
    var display: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static let defaultPreviousSpace = KeyCombo(
        keyCode: UInt16(kVK_F3),
        modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
        display: "⌥⌘F3")

    init(keyCode: UInt16, modifiers: UInt, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// A combo from a key press, or nil if it isn't usable as a global shortcut
    /// (plain letters etc. need at least ⌘, ⌥ or ⌃; function keys may stand alone).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        let name = Self.keyName(for: event.keyCode)
            ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let name, !name.isEmpty else { return nil }
        let isFunctionKey = Self.functionKeyNumbers[event.keyCode] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, display: Self.symbols(for: flags) + name)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isFunctionKey: Bool { Self.functionKeyNumbers[keyCode] != nil }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// For `NSMenuItem.keyEquivalent`, so menus show the shortcut.
    var menuKeyEquivalent: String {
        if let n = Self.functionKeyNumbers[keyCode], let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + n - 1)) {
            return String(Character(scalar))
        }
        if let special = Self.namedKeys[keyCode] { return special.menuKey }
        return display.last.map { String($0).lowercased() } ?? ""
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    private static func keyName(for keyCode: UInt16) -> String? {
        if let n = functionKeyNumbers[keyCode] { return "F\(n)" }
        return namedKeys[keyCode]?.name
    }

    private static let functionKeyNumbers: [UInt16: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt16($0.element), $0.offset + 1) })
    }()

    private static func functionKey(_ value: Int) -> String {
        String(Character(UnicodeScalar(UInt32(value))!))
    }

    private static let namedKeys: [UInt16: (name: String, menuKey: String)] = [
        UInt16(kVK_LeftArrow): ("←", functionKey(NSLeftArrowFunctionKey)),
        UInt16(kVK_RightArrow): ("→", functionKey(NSRightArrowFunctionKey)),
        UInt16(kVK_UpArrow): ("↑", functionKey(NSUpArrowFunctionKey)),
        UInt16(kVK_DownArrow): ("↓", functionKey(NSDownArrowFunctionKey)),
        UInt16(kVK_Space): ("Space", " "),
        UInt16(kVK_Return): ("↩", "\r"),
        UInt16(kVK_Tab): ("⇥", "\t"),
        UInt16(kVK_Delete): ("⌫", "\u{8}"),
        UInt16(kVK_ForwardDelete): ("⌦", "\u{7f}"),
        UInt16(kVK_Home): ("↖", functionKey(NSHomeFunctionKey)),
        UInt16(kVK_End): ("↘", functionKey(NSEndFunctionKey)),
        UInt16(kVK_PageUp): ("⇞", functionKey(NSPageUpFunctionKey)),
        UInt16(kVK_PageDown): ("⇟", functionKey(NSPageDownFunctionKey)),
    ]
}

extension Notification.Name {
    fileprivate static let roostHotKeyPressed = Notification.Name("RoostHotKeyPressed")
    /// Posted by the shortcut recorder (`userInfo["active"]: Bool`) so global hotkeys can step
    /// aside while the user types a new one.
    static let roostShortcutRecording = Notification.Name("RoostShortcutRecording")
}

/// Carbon event handler; runs on the main thread. Bounces through NotificationCenter to reach
/// the main-actor `HotKeyCenter` synchronously.
private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    NotificationCenter.default.post(name: .roostHotKeyPressed, object: nil, userInfo: ["id": hotKeyID.id])
    return noErr
}

/// System-wide shortcuts via `RegisterEventHotKey`, which needs no extra permissions.
@MainActor
final class HotKeyCenter: NSObject {
    static let shared = HotKeyCenter()
    private static let signature: OSType = 0x526F_6F73 // "Roos"

    private var handler: EventHandlerRef?
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(pressed(_:)), name: .roostHotKeyPressed, object: nil)
    }

    /// Returns false if the combo is taken by another app or the system.
    @discardableResult
    func register(id: UInt32, combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &handler)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.system.error("Couldn't register shortcut \(combo.display, privacy: .public) (error \(status))")
            return false
        }
        hotKeys[id] = (ref, action)
        return true
    }

    func unregister(id: UInt32) {
        if let entry = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    @objc private func pressed(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? UInt32 else { return }
        hotKeys[id]?.action()
    }
}
