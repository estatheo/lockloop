import AerialKit
import SwiftUI

/// A heading or message, then the buttons that make sense for it.
private struct Message<Buttons: View>: View {
    var heading: String?
    var body_: String
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let heading {
                Text(heading)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            BodyText(body_)
            HStack(spacing: 8) { buttons() }
        }
    }
}

/// S0.
struct UnsupportedView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let kind: AerialLayoutKind

    var body: some View {
        Message(body_: Copy.message(for: .unsupportedLayout(kind))) {
            if kind == .none {
                Button(Copy.openWallpaperSettings) { model.openWallpaperSettings() }
            }
        }
    }
}

/// S7.
struct AttentionView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let kind: AttentionKind

    var body: some View {
        switch kind {
        case .reverted(true):
            Message(heading: Copy.revertedHeading, body_: Copy.revertedBody) {
                Button(Copy.useMyVideoAgain) { model.useMyVideoAgain() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(Copy.leaveApple) { model.restore() }
            }
        case .reverted(false):
            Message(heading: Copy.revertedHeading, body_: Copy.revertedCopyGone) {
                Button(Copy.chooseFile) { model.chooseAnother() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(Copy.leaveApple) { model.restore() }
            }
        case .otherWallpaper(let name):
            Message(heading: Copy.otherWallpaperHeading, body_: Copy.otherWallpaperBody(name)) {
                Button(Copy.useMyVideoAgain) { model.useMyVideoAgain() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(Copy.restoreApple) { model.restore() }
            }
        }
    }
}

/// S8b.
struct RestoredView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let nothingToRestore: Bool

    var body: some View {
        Message(body_: nothingToRestore ? Copy.nothingToRestoreApp : Copy.restored) {
            Button(Copy.chooseAFile) { model.backToEmpty() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// S9. What happened, what state the Mac is in, and what can be done.
struct FailedView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let error: LoopError

    var body: some View {
        Message(body_: error.message) {
            switch error {
            case .unsupportedLayout(.none), .choiceNotAccepted:
                Button(Copy.openWallpaperSettings) { model.openWallpaperSettings() }
            case .catalogueUnreadable, .indexUnreadable, .noDesktopEntries:
                Button(Copy.openWallpaperSettings) { model.openWallpaperSettings() }
                Button(Copy.tryAgain) { model.tryAgain() }
            case .unsupportedFile, .unreadableFile, .noPicture, .protectedFile:
                Button(Copy.chooseAnotherFile) { model.chooseAnother() }
                    .keyboardShortcut(.defaultAction)
            case .conversionFailed:
                Button(Copy.tryAgain) { model.tryAgain() }
                    .keyboardShortcut(.defaultAction)
                Button(Copy.chooseAnotherFile) { model.chooseAnother() }
            case .rollbackFailed:
                Button(Copy.restoreApple) { model.restore() }
                    .keyboardShortcut(.defaultAction)
            case .originalMissing:
                Button(Copy.downloadAndRestore) { model.downloadAndRestore() }
                    .keyboardShortcut(.defaultAction)
            case .unsupportedLayout(.legacy):
                EmptyView()
            default:
                Button(Copy.tryAgain) { model.tryAgain() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
