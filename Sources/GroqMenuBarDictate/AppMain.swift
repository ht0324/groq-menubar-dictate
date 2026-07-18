import AppKit
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
    }
}

@main
struct BoltApp {
    @MainActor
    static func main() async {
        if TriggerReplayCommand.shouldRun(arguments: CommandLine.arguments) {
            exit(TriggerReplayCommand.run(arguments: CommandLine.arguments))
        }

        if LatencyProbeCommand.shouldRun(arguments: CommandLine.arguments) {
            exit(await LatencyProbeCommand.run(arguments: CommandLine.arguments))
        }

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
