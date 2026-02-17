import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
    }
}

@main
struct GroqMenuBarDictateApp {
    static func main() {
        let singleInstanceGuard = SingleInstanceGuard(lockName: "com.huntae.groq-menubar-dictate")
        guard singleInstanceGuard.acquireLock() else {
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        _ = delegate
        _ = singleInstanceGuard
    }
}
