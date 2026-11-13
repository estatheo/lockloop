import AerialKit
import SwiftUI
import UniformTypeIdentifiers

/// S1. The whole frame takes drops; Choose File is the keyboard route.
struct DropZoneView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        ScreenFrame(style: targeted ? .targeted : .dashed) {
            VStack(spacing: 12) {
                Text(targeted ? Copy.dropHeadingTargeted : Copy.dropHeading)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(Copy.dropHelp)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.chooseFile) { model.chooseFile() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Copy.dropAccessibilityHint)
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.dropAccessibilityLabel)
        .accessibilityHint(Copy.dropAccessibilityHint)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let collector = URLCollector()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collector.add(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.load(collector.urls) }
            return !providers.isEmpty
        }
    }
}

/// Gathers URLs from item providers that call back on any thread.
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
}
