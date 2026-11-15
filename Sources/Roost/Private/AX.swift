import AppKit
import ApplicationServices

/// Private Accessibility helpers.
enum AXPrivate {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> UnsafeRawPointer?

    private static let getWindow = PrivateSymbols.load("_AXUIElementGetWindow", as: GetWindowFn.self)
    private static let createWithRemoteToken = PrivateSymbols.load("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteTokenFn.self)

    /// The WindowServer id behind an AX window element.
    static func windowID(of element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: UInt32 = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// `kAXWindowsAttribute` only lists windows on the *current* Space for many apps. Building
    /// elements from a remote token lets us reach windows on other Spaces too.
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let createWithRemoteToken else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(0x636F_636F), toByteOffset: 8, as: UInt32.self) // "coco"
            raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
        }
        guard let raw = createWithRemoteToken(token as CFData) else { return nil }
        return Unmanaged<AXUIElement>.fromOpaque(raw).takeRetainedValue()
    }

    static var canEnumerateOtherSpaces: Bool { createWithRemoteToken != nil && getWindow != nil }
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let array = value(attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    var role: String? { string("AXRole") }
    var subrole: String? { string("AXSubrole") }
    var title: String? { string("AXTitle") }
    var isMinimized: Bool { bool("AXMinimized") ?? false }
    var isFullScreen: Bool { bool("AXFullScreen") ?? false }
    var isStandardWindow: Bool { role == "AXWindow" && subrole == "AXStandardWindow" }

    var frame: CGRect? {
        guard let p = value("AXPosition"), let s = value("AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(self, "AXPosition" as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(self, "AXSize" as CFString, value) == .success
    }

    @discardableResult
    func set(_ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    @discardableResult
    func press() -> Bool {
        AXUIElementPerformAction(self, "AXPress" as CFString) == .success
    }
}
