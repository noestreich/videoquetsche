import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single source of truth for the job list. Owned by the delegate so that
    /// files opened via the Dock icon / Finder are added exactly once,
    /// independent of how many views exist.
    let processor = VideoProcessor()

    func application(_ application: NSApplication, open urls: [URL]) {
        processor.addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { $0.isVisible && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        processor.stopAll()
    }
}

@main
struct VideoCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // `Window` (instead of `WindowGroup`) guarantees a single window:
        // opening files via the Dock no longer spawns an additional window.
        Window("Videoquetsche", id: "main") {
            ContentView()
                .environmentObject(appDelegate.processor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
