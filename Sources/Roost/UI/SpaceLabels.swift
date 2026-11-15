import AppKit

/// Shows each Space's name on that Space.
///
/// There's no API to put a window on a specific Space, but a newly ordered-in window lands on
/// the Space currently visible on its display. So we create a label lazily the first time each
/// Space is seen, and from then on it lives on that Space (and slides with it when swiping).
/// Every refresh re-checks where each label actually is, so labels self-correct when Spaces are
/// removed, reordered or moved between displays.
@MainActor
final class SpaceLabelController: NSObject {
    private var labels: [SpaceLabel] = []
    private let settings = Settings.shared
    private let names = SpaceNames.shared

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(refresh), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: .roostSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: .roostSpaceNamesChanged, object: nil)
        refresh()
    }

    @objc private func screensChanged() {
        // Give WindowServer a moment to finish moving Spaces between displays.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.refresh()
        }
    }

    @objc func refresh() {
        guard settings.spaceNamesEnabled, settings.showLabels, CGS.isAvailable else {
            labels.forEach { $0.close() }
            labels = []
            return
        }
        let state = SpacesState.current()
        var covered = Set<CGSSpaceID>()
        var keep: [SpaceLabel] = []

        for label in labels {
            let actual = CGS.spaces(forWindow: label.windowID)
            let space: SpaceInfo?
            if actual.count == 1 {
                space = state.space(id: actual[0])
            } else {
                // Not (yet) attached to a single Space: treat it as showing the current one.
                space = label.displayUUID.flatMap { state.currentSpace(displayUUID: $0) }
            }
            guard let space, !space.isFullscreen, !covered.contains(space.id),
                  let screen = Displays.screen(forDisplayUUID: space.displayUUID) else {
                label.close()
                continue
            }
            covered.insert(space.id)
            label.show(text: text(for: space), on: screen, displayUUID: space.displayUUID,
                       style: settings.labelStyle, position: settings.labelPosition)
            keep.append(label)
        }

        for display in state.displays {
            guard let current = display.currentSpace, !current.isFullscreen, !covered.contains(current.id),
                  let screen = Displays.screen(forDisplayUUID: display.displayUUID) else { continue }
            let label = SpaceLabel()
            label.show(text: text(for: current), on: screen, displayUUID: display.displayUUID,
                       style: settings.labelStyle, position: settings.labelPosition)
            label.orderIn()
            covered.insert(current.id)
            keep.append(label)
        }
        labels = keep
    }

    private func text(for space: SpaceInfo) -> String {
        if let custom = names.customName(for: space) { return custom }
        return settings.labelUnnamedSpaces ? space.defaultName : ""
    }
}

@MainActor
final class SpaceLabel {
    private(set) var displayUUID: String?
    private let panel: NSPanel
    private let field = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    var windowID: UInt32 { UInt32(clamping: panel.windowNumber) }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let panel = self.panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Deliberately *not* .canJoinAllSpaces: each label belongs to one Space.
        panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let container = NSView()
        container.addSubview(background)
        container.addSubview(field)
        panel.contentView = container
    }

    func orderIn() { panel.orderFrontRegardless() }
    func close() { panel.close() }

    func show(text: String, on screen: NSScreen, displayUUID: String, style: LabelStyle, position: LabelPosition) {
        self.displayUUID = displayUUID
        panel.alphaValue = text.isEmpty ? 0 : 1
        field.stringValue = text

        let padding: CGFloat
        switch style {
        case .watermark:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            field.font = .systemFont(ofSize: 44, weight: .bold)
            field.textColor = NSColor.white.withAlphaComponent(0.55)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            field.shadow = shadow
            background.isHidden = true
            padding = 4
        case .badge:
            panel.level = .floating
            field.font = .systemFont(ofSize: 13, weight: .semibold)
            field.textColor = .labelColor
            field.shadow = nil
            background.isHidden = false
            padding = 8
        }

        field.sizeToFit()
        let size = NSSize(width: ceil(field.frame.width) + padding * 2, height: ceil(field.frame.height) + padding)
        field.setFrameOrigin(NSPoint(x: padding, y: padding / 2))
        background.frame = NSRect(origin: .zero, size: size)

        let area = screen.visibleFrame.insetBy(dx: 20, dy: 16)
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topLeft, .bottomLeft: x = area.minX
        case .topRight, .bottomRight: x = area.maxX - size.width
        case .topCenter, .bottomCenter, .center: x = area.midX - size.width / 2
        }
        switch position {
        case .topLeft, .topCenter, .topRight: y = area.maxY - size.height
        case .bottomLeft, .bottomCenter, .bottomRight: y = area.minY
        case .center: y = area.midY - size.height / 2
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
