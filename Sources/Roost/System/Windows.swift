import AppKit
import RoostCore

/// A window that currently exists, as reported by the WindowServer.
struct LiveWindow {
    var id: UInt32
    var pid: pid_t
    var bundleID: String?
    var appName: String
    var frame: CGRect
    var spaces: [CGSSpaceID]
    /// n-th window of its app, front to back.
    var ordinal: Int
}

/// Lists windows across all Spaces and finds their Accessibility elements.
final class WindowCatalog {
    private var elementCache: [UInt32: AXUIElement] = [:]
    private var titleCache: [UInt32: String] = [:]
    /// What Accessibility has told us about each window: true for a regular document window
    /// (AXStandardWindow), false for popups, sheets, palettes etc. Missing means unknown, which is
    /// common for windows on other Spaces that we couldn't reach in time. Unknown is *not* the
    /// same as non-standard: such windows are still saved, and checked again before moving them.
    private var isStandard: [UInt32: Bool] = [:]
    /// How often we failed to reach a window, to avoid re-probing it on every snapshot.
    private var unreachableAttempts: [UInt32: Int] = [:]

    /// Cheap: WindowServer only, no Accessibility round trips. Safe to call right before a
    /// display reconfiguration.
    func liveWindows() -> [LiveWindow] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        var apps: [pid_t: NSRunningApplication?] = [:]
        var ordinals: [pid_t: Int] = [:]
        var result: [LiveWindow] = []

        for entry in info {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 60, frame.height >= 40,
                  isStandard[id] != false
            else { continue }
            if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 { continue }

            let app: NSRunningApplication?
            if let cached = apps[pid] { app = cached } else {
                app = NSRunningApplication(processIdentifier: pid)
                apps[pid] = app
            }
            guard let app, app.activationPolicy == .regular else { continue }

            let spaces = CGS.spaces(forWindow: id)
            guard !spaces.isEmpty else { continue } // minimized, or not a real window

            let ordinal = ordinals[pid, default: 0]
            ordinals[pid] = ordinal + 1
            result.append(LiveWindow(id: id, pid: pid, bundleID: app.bundleIdentifier,
                                     appName: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                                     frame: frame, spaces: spaces, ordinal: ordinal))
        }
        return result
    }

    func cachedTitle(_ id: UInt32) -> String? { titleCache[id] }

    /// True for windows Accessibility has identified as popups, palettes and the like.
    func isKnownNonStandard(_ id: UInt32) -> Bool { isStandard[id] == false }

    private func classify(_ id: UInt32, _ element: AXUIElement) {
        elementCache[id] = element
        if let title = element.title, !title.isEmpty { titleCache[id] = title }
        isStandard[id] = element.isStandardWindow
        unreachableAttempts[id] = nil
    }

    /// Refreshes titles and the standard/non-standard classification. Windows on the current
    /// Space come from each app's window list; the rest are looked up across Spaces (with a
    /// time budget, so some may stay unknown). Never moves anything.
    func refreshMetadata(for windows: [LiveWindow]) {
        guard AXIsProcessTrusted() else { return }
        let liveIDs = Set(windows.map(\.id))
        elementCache = elementCache.filter { liveIDs.contains($0.key) }
        titleCache = titleCache.filter { liveIDs.contains($0.key) }
        isStandard = isStandard.filter { liveIDs.contains($0.key) }
        unreachableAttempts = unreachableAttempts.filter { liveIDs.contains($0.key) }

        for pid in Set(windows.map(\.pid)) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            for element in app.elements("AXWindows") {
                guard let id = AXPrivate.windowID(of: element), liveIDs.contains(id) else { continue }
                classify(id, element)
            }
        }

        // Don't keep probing windows we've failed to reach twice (e.g. Chrome's find bar).
        let unknown = windows.filter { isStandard[$0.id] == nil && unreachableAttempts[$0.id, default: 0] < 2 }
        guard !unknown.isEmpty else { return }
        let found = elements(for: unknown)
        for window in unknown {
            if let element = found[window.id] {
                classify(window.id, element)
            } else {
                unreachableAttempts[window.id, default: 0] += 1
            }
        }
    }

    /// AX elements for the given windows, including ones on other Spaces.
    func elements(for windows: [LiveWindow]) -> [UInt32: AXUIElement] {
        var found: [UInt32: AXUIElement] = [:]
        for (pid, group) in Dictionary(grouping: windows, by: \.pid) {
            var wanted = Set(group.map(\.id))

            for id in wanted {
                if let cached = elementCache[id], AXPrivate.windowID(of: cached) == id {
                    found[id] = cached
                }
            }
            wanted.subtract(found.keys)
            if wanted.isEmpty { continue }

            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            for element in app.elements("AXWindows") {
                if let id = AXPrivate.windowID(of: element), wanted.remove(id) != nil {
                    found[id] = element
                }
            }
            if wanted.isEmpty || !AXPrivate.canEnumerateOtherSpaces { continue }

            // Windows on other Spaces: probe element ids until we've found them all,
            // with a time budget so one misbehaving app can't stall us.
            let deadline = Date().addingTimeInterval(0.4)
            var elementID: UInt64 = 0
            while !wanted.isEmpty, elementID < 0x7FFF, Date() < deadline {
                if let element = AXPrivate.element(pid: pid, elementID: elementID),
                   let id = AXPrivate.windowID(of: element), wanted.remove(id) != nil {
                    found[id] = element
                }
                elementID += 1
            }
        }
        for (id, element) in found { elementCache[id] = element }
        return found
    }
}

enum WindowMover {
    /// Sets a window's frame. Position is applied twice because apps clamp the size against
    /// the display the window is currently on.
    @discardableResult
    static func setFrame(_ element: AXUIElement, to frame: CGRect) -> Bool {
        element.setPosition(frame.origin)
        element.setSize(frame.size)
        element.setPosition(frame.origin)
        guard let actual = element.frame else { return false }
        return abs(actual.minX - frame.minX) < 4 && abs(actual.minY - frame.minY) < 4
    }

    /// Apps with "enhanced user interface" on (set by VoiceOver & some utilities) animate every
    /// AX move, which makes restores slow and unreliable. Turn it off for the duration.
    static func withoutEnhancedUI<T>(pid: pid_t, _ body: () -> T) -> T {
        let app = AXUIElementCreateApplication(pid)
        let wasEnabled = app.bool("AXEnhancedUserInterface") ?? false
        if wasEnabled { app.set("AXEnhancedUserInterface", false) }
        defer { if wasEnabled { app.set("AXEnhancedUserInterface", true) } }
        return body()
    }
}
