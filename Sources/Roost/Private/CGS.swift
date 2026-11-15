import AppKit

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

/// Resolves private symbols at runtime so a missing one degrades a feature instead of
/// preventing the app from launching on a future macOS.
enum PrivateSymbols {
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(defaultHandle, name) else {
            Log.system.notice("Private symbol \(name, privacy: .public) is unavailable on this macOS version")
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }
}

/// Thin wrapper around the private SkyLight / CoreGraphics Services API that Mission Control uses.
/// There is no public API for Spaces.
enum CGS {
    private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> UnsafeRawPointer?
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> UnsafeRawPointer?
    private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID
    private typealias MoveWindowsToManagedSpaceFn = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
    private typealias SpaceSetCompatIDFn = @convention(c) (CGSConnectionID, CGSSpaceID, Int32) -> Int32
    private typealias SetWindowListWorkspaceFn = @convention(c) (CGSConnectionID, UnsafePointer<UInt32>, Int32, Int32) -> Int32

    private static let mainConnection = PrivateSymbols.load("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copyManagedDisplaySpaces = PrivateSymbols.load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindows = PrivateSymbols.load("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let getActiveSpace = PrivateSymbols.load("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let moveWindowsToManagedSpace = PrivateSymbols.load("CGSMoveWindowsToManagedSpace", as: MoveWindowsToManagedSpaceFn.self)
    private static let spaceSetCompatID = PrivateSymbols.load("CGSSpaceSetCompatID", as: SpaceSetCompatIDFn.self)
    private static let setWindowListWorkspace = PrivateSymbols.load("CGSSetWindowListWorkspace", as: SetWindowListWorkspaceFn.self)

    static let connection: CGSConnectionID = mainConnection?() ?? 0

    static var isAvailable: Bool { copyManagedDisplaySpaces != nil && copySpacesForWindows != nil }

    /// Raw description of every display's Spaces, in Mission Control order.
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let fn = copyManagedDisplaySpaces, let raw = fn(connection) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        return (array as NSArray) as? [[String: Any]] ?? []
    }

    /// Spaces a window belongs to (several for "all desktops" windows, none for minimized ones).
    static func spaces(forWindow id: UInt32) -> [CGSSpaceID] {
        guard let fn = copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: id)] as CFArray
        guard let raw = fn(connection, 0x7 /* all spaces */, ids) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        return ((array as NSArray) as? [NSNumber] ?? []).map(\.uint64Value)
    }

    /// The Space shown on the display that currently has the menu bar / keyboard focus.
    static func activeSpaceID() -> CGSSpaceID? {
        guard let fn = getActiveSpace else { return nil }
        let id = fn(connection)
        return id == 0 ? nil : id
    }

    /// Moves windows owned by other apps to `space`. Returns whether it worked.
    ///
    /// `CGSMoveWindowsToManagedSpace` works up to macOS 14.4. From 14.5 Apple restricted it to
    /// the Dock, so we fall back to the "compat id" workspace trick used by several window
    /// managers. Either may stop working in a future release; the caller then just places the
    /// window on the right display.
    static func moveWindows(_ ids: [UInt32], to space: CGSSpaceID) -> Bool {
        guard !ids.isEmpty else { return true }
        func landed() -> Bool { ids.allSatisfy { spaces(forWindow: $0).contains(space) } }

        if let move = moveWindowsToManagedSpace {
            move(connection, ids.map { NSNumber(value: $0) } as CFArray, space)
            if landed() { return true }
        }
        if let setCompat = spaceSetCompatID, let setWorkspace = setWindowListWorkspace {
            let compatID: Int32 = 0x726F_6F73 // "roos"
            _ = setCompat(connection, space, compatID)
            ids.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    _ = setWorkspace(connection, base, Int32(buffer.count), compatID)
                }
            }
            _ = setCompat(connection, space, 0)
            if landed() { return true }
        }
        return false
    }
}
