import AppKit
import Carbon.HIToolbox
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
    @State private var desktopShortcuts: [Int] = []
    @State private var canMoveLeftRight = true
    @State private var canPostEvents = Permissions.canPostEvents

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
                    .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
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

            Section {
                LabeledContent("Keyboard shortcut") {
                    ShortcutRecorder(combo: $settings.previousSpaceShortcut)
                }
                if !canPostEvents {
                    LabeledContent {
                        Button("Allow…") {
                            Permissions.requestPostEvents()
                            NSWorkspace.shared.open(SystemSettings.accessibilityURL)
                        }
                    } label: {
                        Text("Roost isn’t allowed to send keystrokes, so it can’t use Mission Control’s shortcuts. "
                            + "Turn Roost on in Privacy & Security › Accessibility.")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Mission Control shortcuts") {
                    Text(missionControlSummary).foregroundStyle(.secondary)
                }
                Button("Keyboard Shortcuts…") { NSWorkspace.shared.open(SystemSettings.keyboardURL) }
            } header: {
                Text("Switch Back to Previous Space")
            } footer: {
                Text(previousSpaceFooter)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshSystemState()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshSystemState() {
        desktopShortcuts = MissionControlShortcuts.enabledDesktopNumbers()
        canMoveLeftRight = MissionControlShortcuts.moveLeftASpace != nil && MissionControlShortcuts.moveRightASpace != nil
        canPostEvents = Permissions.canPostEvents
    }

    private var missionControlSummary: String {
        var parts: [String] = []
        if !desktopShortcuts.isEmpty {
            parts.append("Switch to " + desktopShortcuts.map { "Desktop \($0)" }.joined(separator: ", "))
        }
        if canMoveLeftRight { parts.append("Move left/right a space") }
        return parts.isEmpty ? "None turned on" : parts.joined(separator: " · ")
    }

    private var previousSpaceFooter: String {
        var text = "Best effort: macOS has no public way to switch Spaces, so Roost presses Mission Control’s shortcuts for you (System Settings › Keyboard › Keyboard Shortcuts › "
            + "Mission Control): “Switch to Desktop N” when it’s on, otherwise “Move left/right a space” as many times as needed. "
            + "If that doesn’t work, or the Space is on another display, Roost brings forward one of its windows, "
            + "which doesn’t work if the Space is empty."
        if settings.previousSpaceShortcut?.isFunctionKey == true {
            text += " On a Mac keyboard, also hold fn unless “Use F1, F2, etc. keys as standard function keys” is on."
        }
        return text
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

/// Click to record a new shortcut; Esc cancels. The ✕ removes it, ↺ restores the default.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(isRecording ? "Type shortcut…" : (combo?.display ?? "Record Shortcut"))
                    .frame(minWidth: 110)
            }
            if !isRecording {
                if combo != nil {
                    Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove shortcut")
                }
                if combo != .defaultPreviousSpace {
                    Button { combo = .defaultPreviousSpace } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.borderless)
                        .help("Use default (\(KeyCombo.defaultPreviousSpace.display))")
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Let go of the current global shortcut so pressing it again can be recorded.
        NotificationCenter.default.post(name: .roostShortcutRecording, object: nil, userInfo: ["active": true])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let recorded = KeyCombo(event: event) {
                combo = recorded
                stopRecording()
            } else {
                NSSound.beep() // needs ⌘, ⌥ or ⌃ (function keys may be used alone)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            NotificationCenter.default.post(name: .roostShortcutRecording, object: nil, userInfo: ["active": false])
        }
    }
}
