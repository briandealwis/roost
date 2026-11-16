import AppKit
import ServiceManagement
import SwiftUI

/// Owns the single settings window and brings it to the front when asked.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Roost Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("RoostSettings")
            if !window.setFrameUsingName("RoostSettings") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Restore layout automatically when displays change", isOn: $settings.autoRestore)
                Toggle("Move windows back to their Spaces", isOn: $settings.moveAcrossSpaces)
                Picker("Save layout in the background", selection: $settings.snapshotInterval) {
                    Text("Never").tag(0)
                    Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                    Text("Every 5 minutes").tag(300)
                    Text("Every 15 minutes").tag(900)
                }
                Picker("Forget unused display setups after", selection: $settings.retentionDays) {
                    Text("1 week").tag(7)
                    Text("2 weeks").tag(14)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("Never").tag(0)
                }
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Window Layouts")
            } footer: {
                Text("Layouts are also saved when you lock the screen, when the Mac or displays sleep, and just before a display is connected or disconnected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Name Spaces", isOn: $settings.spaceNamesEnabled)
                Toggle("Show the current Space’s name in the menu bar", isOn: $settings.showNameInMenuBar)
                    .disabled(!settings.spaceNamesEnabled)
            } header: {
                Text("Space Names")
            } footer: {
                Text("Rename a Space from the Roost menu while you’re on it, or pick any Space from the Spaces submenu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show a label on each Space", isOn: $settings.showLabels)
                Group {
                    Toggle("Show labels for Spaces without a name", isOn: $settings.labelUnnamedSpaces)
                    Picker("Label style", selection: $settings.labelStyle) {
                        ForEach(LabelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Label position", selection: $settings.labelPosition) {
                        ForEach(LabelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                .padding(.leading, 20)
                .disabled(!settings.showLabels)
            } header: {
                Text("Space Labels")
            }
            .disabled(!settings.spaceNamesEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = "Couldn’t change Launch at Login: \(error.localizedDescription)"
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }
}
