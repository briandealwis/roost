import AppKit

@main
enum RoostMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var layout: LayoutManager?
    private var labels: SpaceLabelController?
    private var menu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CGS.isAvailable {
            Log.system.error("Spaces API unavailable; Space features are disabled")
        }
        Permissions.requestAccessibility()

        let layout = LayoutManager()
        layout.start()
        self.layout = layout

        let labels = SpaceLabelController()
        labels.start()
        self.labels = labels

        menu = StatusMenuController(layout: layout)
    }

    func applicationWillTerminate(_ notification: Notification) {
        layout?.stop()
    }
}
