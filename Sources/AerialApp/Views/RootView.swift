import AerialKit
import SwiftUI
import UniformTypeIdentifiers

/// One window. The 16:9 screen frame sits at the top of every screen; the controls for
/// the current step sit under it.
struct RootView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onPasteCommand(of: [.fileURL]) { providers in
            loadFileURLs(from: providers)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .launching:
            ScreenFrame(style: .solid) { ProgressView().controlSize(.small) }
        case .unsupported(let kind):
            UnsupportedView(kind: kind)
        case .empty:
            DropZoneView()
        case .loadingFile(let name):
            ScreenFrame(style: .solid) {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.reading(name)).multilineTextAlignment(.center)
                }
                .padding()
                .accessibilityElement(children: .combine)
            }
        case .ready(let file):
            ReadyView(file: file)
        case .needsAerial, .downloading:
            AerialPickerView()
        case .working(let text, let fraction, let canCancel):
            WorkingView(text: text, fraction: fraction, canCancel: canCancel)
        case .applied(let filename, let justApplied):
            AppliedView(filename: filename, justApplied: justApplied)
        case .attention(let kind):
            AttentionView(kind: kind)
        case .restoring:
            ScreenFrame(style: .solid) {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.restoring)
                }
                .accessibilityElement(children: .combine)
            }
        case .restored(let nothing):
            RestoredView(nothingToRestore: nothing)
        case .failed(let error):
            FailedView(error: error)
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider]) {
        for provider in providers.prefix(1) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.load([url]) } }
            }
        }
    }
}
