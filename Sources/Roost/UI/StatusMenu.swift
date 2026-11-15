import AppKit
import RoostCore
import ServiceManagement

/// The menu bar item. Left- or right-clicking opens the same menu.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let layout: LayoutManager
    private let settings = Settings.shared
    private let names = SpaceNames.shared

    init(layout: LayoutManager) {
        self.layout = layout
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(updateTitle), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(updateTitle), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateTitle), name: .roostSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(updateTitle), name: .roostSpaceNamesChanged, object: nil)
        center.addObserver(self, selector: #selector(updateTitle), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        updateTitle()
    }

    @objc func updateTitle() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Roost")
        image?.isTemplate = true
        button.image = image
        if settings.spaceNamesEnabled, settings.showNameInMenuBar, let space = SpacesState.current().activeSpace {
            button.title = " " + names.displayName(for: space)
        } else {
            button.title = ""
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let spaces = SpacesState.current()
        let config = layout.currentConfiguration

        if !Permissions.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(grantAccess)))
            menu.addItem(disabled("Needed to move windows"))
            menu.addItem(.separator())
        }

        if settings.spaceNamesEnabled {
            if let active = spaces.activeSpace {
                menu.addItem(disabled(names.displayName(for: active)))
                if !active.isFullscreen {
                    let rename = item("Rename This Space…", #selector(renameActiveSpace))
                    rename.keyEquivalent = "r"
                    menu.addItem(rename)
                }
            }
            menu.addItem(submenu("Spaces", spacesMenu(spaces)))
            menu.addItem(.separator())
        }

        menu.addItem(disabled(config.summary.isEmpty ? "No displays" : config.summary))
        menu.addItem(disabled(layout.lastStatus))
        if let saved = layout.store.layout(for: config.key) {
            menu.addItem(disabled("Saved \(relative(saved.snapshot.createdAt)) (\(saved.snapshot.reason)) · \(saved.snapshot.windows.count) windows"))
        }
        menu.addItem(item("Restore Layout Now", #selector(restoreNow)))
        menu.addItem(item("Save Layout Now", #selector(snapshotNow)))
        menu.addItem(submenu("Saved Display Setups", savedLayoutsMenu(currentKey: config.key)))
        menu.addItem(.separator())

        menu.addItem(item("Change Display Arrangement…", #selector(openArrangement)))
        menu.addItem(item("Displays Settings…", #selector(openDisplays)))
        menu.addItem(.separator())

        menu.addItem(submenu("Preferences", preferencesMenu()))
        menu.addItem(item("Quit Roost", #selector(quit), key: "q"))
    }

    private func spacesMenu(_ spaces: SpacesState) -> NSMenu {
        let sub = NSMenu()
        let multipleDisplays = spaces.displays.count > 1
        for display in spaces.displays {
            if multipleDisplays {
                let name = Displays.screen(forDisplayUUID: display.displayUUID)?.localizedName ?? "Display"
                sub.addItem(disabled(name))
            }
            for space in display.spaces where !space.isFullscreen {
                let custom = names.customName(for: space)
                let title = custom.map { "\(space.defaultName) — \($0)" } ?? space.defaultName
                let entry = item((multipleDisplays ? "  " : "") + title + "…", #selector(renameSpace(_:)))
                entry.representedObject = space.nameKey
                entry.state = space.id == display.currentSpaceID ? .on : .off
                sub.addItem(entry)
            }
        }
        if sub.items.isEmpty { sub.addItem(disabled("Spaces unavailable")) }
        return sub
    }

    private func savedLayoutsMenu(currentKey: String) -> NSMenu {
        let sub = NSMenu()
        let layouts = layout.store.sortedLayouts
        if layouts.isEmpty { sub.addItem(disabled("None yet")) }
        for saved in layouts {
            let current = saved.key == currentKey
            let title = "\(saved.configuration.summary) — \(saved.snapshot.windows.count) windows, " +
                (current ? "current" : "seen \(relative(saved.lastSeen))")
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.state = current ? .on : .off
            let actions = NSMenu()
            let forget = item("Forget This Setup", #selector(forgetLayout(_:)))
            forget.representedObject = saved.key
            actions.addItem(forget)
            entry.submenu = actions
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let days = settings.retentionDays
        sub.addItem(disabled(days > 0 ? "Setups unused for \(days) days are forgotten" : "Setups are kept forever"))
        return sub
    }

    private func preferencesMenu() -> NSMenu {
        let sub = NSMenu()
        sub.addItem(toggle("Restore Automatically on Display Change", settings.autoRestore, #selector(toggleAutoRestore)))
        sub.addItem(toggle("Move Windows Back to Their Spaces", settings.moveAcrossSpaces, #selector(toggleMoveAcrossSpaces)))

        let interval = NSMenu()
        for (label, seconds) in [("Off", 0), ("Every Minute", 60), ("Every 2 Minutes", 120), ("Every 5 Minutes", 300), ("Every 15 Minutes", 900)] {
            let entry = item(label, #selector(setSnapshotInterval(_:)))
            entry.tag = seconds
            entry.state = settings.snapshotInterval == seconds ? .on : .off
            interval.addItem(entry)
        }
        sub.addItem(submenu("Background Saves", interval))

        let retention = NSMenu()
        for (label, days) in [("1 Week", 7), ("2 Weeks", 14), ("1 Month", 30), ("3 Months", 90), ("Never", 0)] {
            let entry = item(label, #selector(setRetention(_:)))
            entry.tag = days
            entry.state = settings.retentionDays == days ? .on : .off
            retention.addItem(entry)
        }
        sub.addItem(submenu("Forget Unused Display Setups After", retention))

        sub.addItem(.separator())
        sub.addItem(toggle("Space Names", settings.spaceNamesEnabled, #selector(toggleSpaceNames)))
        if settings.spaceNamesEnabled {
            sub.addItem(toggle("Show Space Name in Menu Bar", settings.showNameInMenuBar, #selector(toggleMenuBarName)))
            sub.addItem(toggle("Show Label on Each Space", settings.showLabels, #selector(toggleLabels)))
            if settings.showLabels {
                sub.addItem(toggle("Label Unnamed Spaces", settings.labelUnnamedSpaces, #selector(toggleLabelUnnamed)))
                let style = NSMenu()
                for value in LabelStyle.allCases {
                    let entry = item(value.title, #selector(setLabelStyle(_:)))
                    entry.representedObject = value.rawValue
                    entry.state = settings.labelStyle == value ? .on : .off
                    style.addItem(entry)
                }
                sub.addItem(submenu("Label Style", style))
                let position = NSMenu()
                for value in LabelPosition.allCases {
                    let entry = item(value.title, #selector(setLabelPosition(_:)))
                    entry.representedObject = value.rawValue
                    entry.state = settings.labelPosition == value ? .on : .off
                    position.addItem(entry)
                }
                sub.addItem(submenu("Label Position", position))
            }
        }

        sub.addItem(.separator())
        sub.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        return sub
    }

    // MARK: Actions

    @objc private func grantAccess() {
        Permissions.requestAccessibility()
        NSWorkspace.shared.open(SystemSettings.accessibilityURL)
    }

    @objc private func renameActiveSpace() {
        guard let space = SpacesState.current().activeSpace else { return }
        promptRename(space)
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let space = SpacesState.current().all.first(where: { $0.nameKey == key }) else { return }
        promptRename(space)
    }

    private func promptRename(_ space: SpaceInfo) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name \(space.defaultName)"
        alert.informativeText = "Leave empty to remove the name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = names.customName(for: space) ?? ""
        field.placeholderString = space.defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            names.setName(field.stringValue, for: space)
        }
    }

    @objc private func restoreNow() { layout.restore(reason: "manual") }
    @objc private func snapshotNow() { layout.snapshot(reason: "manual", thorough: true, force: true) }

    @objc private func forgetLayout(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        layout.forget(key: key)
    }

    @objc private func openArrangement() { SystemSettings.openDisplayArrangement() }
    @objc private func openDisplays() { SystemSettings.openDisplays() }

    @objc private func toggleAutoRestore() { settings.autoRestore.toggle() }
    @objc private func toggleMoveAcrossSpaces() { settings.moveAcrossSpaces.toggle() }
    @objc private func setSnapshotInterval(_ sender: NSMenuItem) { settings.snapshotInterval = sender.tag }
    @objc private func setRetention(_ sender: NSMenuItem) { settings.retentionDays = sender.tag }
    @objc private func toggleSpaceNames() { settings.spaceNamesEnabled.toggle() }
    @objc private func toggleMenuBarName() { settings.showNameInMenuBar.toggle() }
    @objc private func toggleLabels() { settings.showLabels.toggle() }
    @objc private func toggleLabelUnnamed() { settings.labelUnnamedSpaces.toggle() }

    @objc private func setLabelStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = LabelStyle(rawValue: raw) { settings.labelStyle = value }
    }

    @objc private func setLabelPosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = LabelPosition(rawValue: raw) { settings.labelPosition = value }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let entry = item(title, action)
        entry.state = on ? .on : .off
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = submenu
        return entry
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
