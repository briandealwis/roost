import AppKit
import RoostCore

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
        }
        menu.addItem(switchBackItem())
        if settings.spaceNamesEnabled {
            menu.addItem(submenu("Spaces", spacesMenu(spaces)))
        }
        menu.addItem(.separator())

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

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Roost", #selector(quit), key: "q"))
    }

    private func switchBackItem() -> NSMenuItem {
        guard let previous = SpaceSwitcher.shared.previousSpace else {
            return disabled("Switch Back to Previous Space")
        }
        let name = settings.spaceNamesEnabled ? names.displayName(for: previous) : previous.defaultName
        let entry = item("Switch Back to \(name)", #selector(switchBack))
        if let combo = settings.previousSpaceShortcut {
            entry.keyEquivalent = combo.menuKeyEquivalent
            entry.keyEquivalentModifierMask = combo.modifierFlags
        }
        return entry
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

    @objc private func switchBack() { SpaceSwitcher.shared.switchToPreviousSpace() }
    @objc private func restoreNow() { layout.restore(reason: "manual") }
    @objc private func snapshotNow() { layout.snapshot(reason: "manual", thorough: true, force: true) }

    @objc private func forgetLayout(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        layout.forget(key: key)
    }

    @objc private func openArrangement() { SystemSettings.openDisplayArrangement() }
    @objc private func openDisplays() { SystemSettings.openDisplays() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
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
