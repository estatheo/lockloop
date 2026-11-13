import AerialKit
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a normal app with a Dock icon and menu bar, also when started from Terminal.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in self.model?.load(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LoopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(Copy.windowTitle, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 560)
                .navigationTitle(model.windowTitle)
                .onAppear {
                    delegate.model = model
                    model.refreshStatus()
                    // Test mode only: open a file at launch, for checking screens by hand.
                    if model.testModePath != nil, let path = ProcessInfo.processInfo.environment["LOCKLOOP_OPEN"] {
                        model.load([URL(fileURLWithPath: path)])
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshIfWaiting()
                }
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.displayName)") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: Copy.aboutText, attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.labelColor,
                        ]),
                        .applicationVersion: Brand.version,
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(Copy.menuOpen) { model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(!model.canAcceptFile)
                Divider()
                Button(Copy.menuRestore) { model.restore() }
                    .disabled(!model.canRestore)
            }
        }
    }
}
