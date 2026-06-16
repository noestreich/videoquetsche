import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var filesToOpen: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        filesToOpen = urls
    }
}

@main
struct VideoCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var processor = VideoProcessor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(processor)
                .onReceive(appDelegate.$filesToOpen) { urls in
                    guard !urls.isEmpty else { return }
                    processor.addFiles(urls)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
