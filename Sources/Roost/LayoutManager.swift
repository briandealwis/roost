import AppKit
import RoostCore

extension Notification.Name {
    static let roostLayoutStatusChanged = Notification.Name("RoostLayoutStatusChanged")
    fileprivate static let roostDisplayReconfiguration = Notification.Name("RoostDisplayReconfiguration")
}

/// Runs on the main thread (the CG callback is delivered on the main run loop). We bounce
/// through NotificationCenter so the handler runs synchronously, before WindowServer starts
/// shuffling windows around.
private func displayReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                            _ userInfo: UnsafeMutableRawPointer?) {
    NotificationCenter.default.post(name: .roostDisplayReconfiguration, object: nil,
                                    userInfo: ["flags": flags.rawValue])
}

/// Decides when to snapshot and when to restore.
///
/// Snapshots happen right *before* things go wrong: screen lock, display sleep, system sleep,
/// the start of a display reconfiguration, plus periodically. They are suppressed while
/// asleep/locked and for a short while after any display change or wake, so a half-restored
/// layout can never overwrite a good one.
///
/// Restores happen after the display configuration settles and after wake/unlock, for
/// whatever display configuration is now active.
@MainActor
final class LayoutManager: NSObject {
    let store: LayoutStore
    private let catalog = WindowCatalog()
    private let settings = Settings.shared

    private(set) var lastStatus = "No layout restored yet"
    private(set) var lastSnapshot: Date?

    private var isAsleep = false
    private var isLocked = false
    private var isReconfiguring = false
    private var suppressSnapshotsUntil = Date.distantPast
    private var restoreTask: Task<Void, Never>?
    private var snapshotTimer: Timer?
    private var lastPrune = Date.distantPast

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        store = LayoutStore(fileURL: support.appendingPathComponent("Roost/layouts.json"))
        super.init()
    }

    func start() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(displayReconfigured(_:)), name: .roostDisplayReconfiguration, object: nil)
        center.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsChanged), name: .roostSettingsChanged, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(goingAway(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(goingAway(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(goingAway(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(goingAway(_:)), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(cameBack(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        configureTimer()
        prune()
        snapshot(reason: "launch", thorough: true)
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
        snapshot(reason: "quit", thorough: false)
    }

    var currentConfiguration: DisplayConfiguration { Displays.currentConfiguration() }

    // MARK: Events

    @objc private func displayReconfigured(_ note: Notification) {
        let raw = note.userInfo?["flags"] as? UInt32 ?? 0
        let flags = CGDisplayChangeSummaryFlags(rawValue: raw)
        if flags.contains(.beginConfigurationFlag) {
            // Called once per display; only the first one matters. Windows are still where the
            // user left them, so this is the most valuable snapshot of all.
            if !isReconfiguring {
                snapshot(reason: "display change", thorough: false)
                isReconfiguring = true
            }
        } else {
            isReconfiguring = false
            suppressSnapshots(for: 15)
            scheduleRestore(after: 1.5, reason: "display change")
        }
    }

    @objc private func screenParametersChanged() {
        // Backup signal in case the CG callback was coalesced.
        suppressSnapshots(for: 15)
        scheduleRestore(after: 2.0, reason: "display change")
    }

    @objc private func goingAway(_ note: Notification) {
        snapshot(reason: Self.describe(note.name), thorough: false)
        if note.name.rawValue == "com.apple.screenIsLocked" {
            isLocked = true
        } else {
            isAsleep = true
            restoreTask?.cancel()
        }
    }

    @objc private func cameBack(_ note: Notification) {
        // Restoring while the lock screen is still up is fine (the user sees the right layout
        // on unlock); snapshotting is not allowed until unlock.
        if note.name.rawValue == "com.apple.screenIsUnlocked" { isLocked = false } else { isAsleep = false }
        suppressSnapshots(for: 15)
        // Displays often reconnect a few seconds after wake; a later display change reschedules this.
        scheduleRestore(after: 2.5, reason: Self.describe(note.name))
    }

    @objc private func settingsChanged() {
        configureTimer()
        prune()
    }

    @objc private func timerFired() {
        snapshot(reason: "periodic", thorough: true)
        if Date().timeIntervalSince(lastPrune) > 3600 { prune() }
    }

    private static func describe(_ name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.willSleepNotification: return "sleep"
        case NSWorkspace.screensDidSleepNotification: return "display sleep"
        case NSWorkspace.sessionDidResignActiveNotification: return "user switch"
        case NSWorkspace.didWakeNotification: return "wake"
        case NSWorkspace.screensDidWakeNotification: return "display wake"
        case NSWorkspace.sessionDidBecomeActiveNotification: return "user switch"
        case Notification.Name("com.apple.screenIsLocked"): return "lock"
        case Notification.Name("com.apple.screenIsUnlocked"): return "unlock"
        default: return name.rawValue
        }
    }

    // MARK: Snapshot

    private var canSnapshot: Bool {
        !isAsleep && !isLocked && !isReconfiguring && Date() >= suppressSnapshotsUntil
    }

    private func suppressSnapshots(for seconds: TimeInterval) {
        suppressSnapshotsUntil = max(suppressSnapshotsUntil, Date().addingTimeInterval(seconds))
    }

    /// `thorough` also refreshes window titles via Accessibility (slower; skipped right before
    /// a display change where speed matters).
    func snapshot(reason: String, thorough: Bool, force: Bool = false) {
        guard force || canSnapshot else {
            Log.layout.debug("Skipping \(reason, privacy: .public) snapshot (suppressed)")
            return
        }
        let config = currentConfiguration
        guard !config.displays.isEmpty else { return }
        let spaces = SpacesState.current()
        let live = catalog.liveWindows()
        if thorough { catalog.refreshMetadata(for: live) }

        let records: [WindowRecord] = live.compactMap { window in
            let space = window.spaces.count == 1 ? spaces.space(id: window.spaces[0]) : nil
            guard let display = Geometry.bestDisplay(for: window.frame, among: config.displays)
                ?? space.flatMap({ config.display(uuid: $0.displayUUID) }) else { return nil }
            return WindowRecord(windowID: window.id, pid: window.pid, bundleID: window.bundleID,
                                appName: window.appName, title: catalog.cachedTitle(window.id),
                                frame: window.frame, displayUUID: display.uuid,
                                frameInDisplay: Geometry.relative(window.frame, to: display),
                                spaceUUID: space?.uuid, spaceID: space?.id,
                                spaceIndex: space.map(\.indexOnDisplay), ordinal: window.ordinal)
        }
        store.save(LayoutSnapshot(createdAt: Date(), reason: reason, windows: records), for: config)
        lastSnapshot = Date()
        Log.layout.info("Snapshot (\(reason, privacy: .public)): \(records.count) windows for \(config.summary, privacy: .public)")
        NotificationCenter.default.post(name: .roostLayoutStatusChanged, object: nil)
    }

    // MARK: Restore

    func scheduleRestore(after delay: TimeInterval, reason: String) {
        guard settings.autoRestore, !isAsleep else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.restore(reason: reason)
            // macOS sometimes moves windows again shortly after; a second pass is cheap
            // because already-correct windows are skipped.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self.restore(reason: reason, isFollowUp: true)
        }
    }

    /// Restores the layout saved for the current display setup, or, with `source`, a layout
    /// saved for a different setup (displays are matched up by `DisplayMapper`).
    func restore(reason: String, isFollowUp: Bool = false, from source: SavedLayout? = nil) {
        defer {
            suppressSnapshots(for: 5)
            NotificationCenter.default.post(name: .roostLayoutStatusChanged, object: nil)
        }
        guard AXIsProcessTrusted() else {
            lastStatus = "Can't restore: Accessibility access not granted"
            return
        }
        let config = currentConfiguration
        let saved: SavedLayout
        let displayMap: [String: DisplayInfo]
        if let source, source.key != config.key {
            saved = source
            displayMap = DisplayMapper.map(from: source.configuration, to: config)
        } else {
            guard let own = store.layout(for: config.key) else {
                if !isFollowUp { lastStatus = "No saved layout yet for \(config.summary)" }
                return
            }
            saved = own
            displayMap = Dictionary(config.displays.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
            store.markSeen(config.key)
        }
        let isFromOtherSetup = saved.key != config.key

        let live = catalog.liveWindows()
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = live.map {
            WindowCandidate(windowID: $0.id, pid: $0.pid, bundleID: $0.bundleID,
                            title: catalog.cachedTitle($0.id), ordinal: $0.ordinal)
        }
        let matches = WindowMatcher.match(records: saved.snapshot.windows, candidates: candidates)
        let spaces = SpacesState.current()

        struct Plan {
            var window: LiveWindow
            var target: CGRect
            var targetSpace: SpaceInfo?
        }
        var plans: [Plan] = []
        for match in matches {
            guard let window = liveByID[match.candidate.windowID],
                  let display = displayMap[match.record.displayUUID] else { continue }
            let target = Geometry.targetFrame(for: match.record, on: display,
                                              from: saved.configuration.display(uuid: match.record.displayUUID))
            var targetSpace: SpaceInfo?
            if settings.moveAcrossSpaces, window.spaces.count == 1,
               let space = resolveSpace(for: match.record, on: display.uuid, in: spaces), space.id != window.spaces[0] {
                targetSpace = space
            }
            if targetSpace != nil || !Geometry.approximatelyEqual(window.frame, target) {
                plans.append(Plan(window: window, target: target, targetSpace: targetSpace))
            }
        }

        guard !plans.isEmpty else {
            if !isFollowUp { lastStatus = "Layout already in place (\(config.summary))" }
            Log.layout.info("Restore (\(reason, privacy: .public)): nothing to do")
            return
        }

        let elements = catalog.elements(for: plans.map(\.window))
        var moved = 0, spaceFailures = 0, unreachable = 0

        // Spaces first: a window's frame is interpreted relative to the Space/display it's on.
        let spaceMoves = Dictionary(grouping: plans.filter { $0.targetSpace != nil && elements[$0.window.id] != nil },
                                    by: { $0.targetSpace!.id })
        for (spaceID, group) in spaceMoves {
            let ids = group.compactMap { plan -> UInt32? in
                guard let el = elements[plan.window.id], el.isStandardWindow, !el.isFullScreen else { return nil }
                return plan.window.id
            }
            if !CGS.moveWindows(ids, to: spaceID) {
                spaceFailures += ids.count
                Log.spaces.notice("Couldn't move \(ids.count) windows to Space \(spaceID)")
            }
        }

        for (pid, group) in Dictionary(grouping: plans, by: \.window.pid) {
            WindowMover.withoutEnhancedUI(pid: pid) {
                for plan in group {
                    guard let element = elements[plan.window.id] else { unreachable += 1; continue }
                    guard !element.isMinimized, !element.isFullScreen else { continue }
                    if WindowMover.setFrame(element, to: plan.target) { moved += 1 }
                }
            }
        }

        var status = "Restored \(moved) window\(moved == 1 ? "" : "s") on \(config.summary)"
        if isFromOtherSetup { status += " from \(saved.configuration.summary)" }
        if spaceFailures > 0 { status += " · \(spaceFailures) couldn't change Space" }
        if unreachable > 0 { status += " · \(unreachable) unreachable" }
        if !isFollowUp || moved > 0 { lastStatus = status }
        Log.layout.info("Restore (\(reason, privacy: .public)\(isFollowUp ? " follow-up" : "", privacy: .public)): \(status, privacy: .public)")
    }

    /// The saved Space, if it can be identified confidently and is on the window's target display:
    /// the same Space if it's there, otherwise the same desktop number on that display.
    private func resolveSpace(for record: WindowRecord, on displayUUID: String, in spaces: SpacesState) -> SpaceInfo? {
        if let uuid = record.spaceUUID, let space = spaces.space(uuid: uuid),
           space.displayUUID == displayUUID, !space.isFullscreen {
            return space
        }
        if let index = record.spaceIndex, index >= 0 {
            return spaces.space(displayUUID: displayUUID, index: index)
        }
        return nil
    }

    /// Applies another setup's layout here, then saves the result as this setup's own layout so
    /// automatic restores work from now on.
    func restore(fromSetup key: String) {
        guard let source = store.layout(for: key) else { return }
        restore(reason: "from \(source.configuration.summary)", from: source)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.currentConfiguration.key != key else { return }
            self.snapshot(reason: "restored from \(source.configuration.summary)", thorough: true, force: true)
        }
    }

    /// Other saved setups, most similar to the current displays first.
    func otherSetups() -> [SavedLayout] {
        let config = currentConfiguration
        return store.sortedLayouts
            .filter { $0.key != config.key }
            .sorted {
                let a = DisplayMapper.similarity(config, $0.configuration)
                let b = DisplayMapper.similarity(config, $1.configuration)
                return a != b ? a > b : $0.lastSeen > $1.lastSeen
            }
    }

    // MARK: Housekeeping

    private func configureTimer() {
        let interval = settings.snapshotInterval
        if let timer = snapshotTimer, interval > 0, Int(timer.timeInterval) == interval { return }
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(interval), target: self, selector: #selector(timerFired),
                          userInfo: nil, repeats: true)
        timer.tolerance = TimeInterval(interval) * 0.2
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    func prune() {
        lastPrune = Date()
        let removed = store.prune(retention: settings.retention, keeping: currentConfiguration.key)
        if !removed.isEmpty {
            Log.layout.info("Forgot \(removed.count) display setups not seen recently")
            NotificationCenter.default.post(name: .roostLayoutStatusChanged, object: nil)
        }
    }

    func forget(key: String) {
        store.remove(key: key)
        NotificationCenter.default.post(name: .roostLayoutStatusChanged, object: nil)
    }
}
