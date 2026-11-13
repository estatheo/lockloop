import AerialKit
import AppKit
import SwiftUI

/// S3. The preview, the fit choice and the one primary button.
struct ReadyView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let file: LoadedFile
    @State private var playing = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ScreenFrame(style: .solid, fill: Color(cgColor: file.background.cgColor)) {
            LoopPreviewView(file: file, playing: playing)
        }
        .accessibilityElement()
        .accessibilityLabel(Copy.previewLabel(file.media.filename, fit: file.fit == .fit ? Copy.fitOption : Copy.fillOption))
        .accessibilityAddTraits(.isImage)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            BodyText(fileLine)
            Spacer(minLength: 8)
            Button(playing ? Copy.pausePreview : Copy.playPreview) { playing.toggle() }
        }

        VStack(alignment: .leading, spacing: 8) {
            Picker(Copy.fitControlLabel, selection: Binding(get: { file.fit }, set: { model.setFit($0) })) {
                Text(Copy.fitOption).tag(FitMode.fit)
                Text(Copy.fillOption).tag(FitMode.fill)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            BodyText(file.fitEqualsFill ? Copy.sameShapeHelp : (file.fit == .fit ? Copy.fitHelp : Copy.fillHelp))
        }

        ForEach(file.notes, id: \.self) { BodyText($0) }

        VStack(alignment: .leading, spacing: 8) {
            Button(Copy.useOnLockScreen) { model.apply() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if let note = model.readyNote { BodyText(note).font(.body.weight(.semibold)) }
            BodyText(file.alreadyApplied ? Copy.noteAlreadyApplied
                     : file.targetName.map(Copy.noteFirstApply) ?? Copy.noteFirstApplyUnknown)
        }

        Button(Copy.chooseAnotherFile) { model.chooseAnother() }
    }

    private var fileLine: String {
        let m = file.media
        let duration = Copy.duration(m.duration)
        let w = Int(m.displaySize.width), h = Int(m.displaySize.height)
        return m.kind == .gif
            ? Copy.fileLineGIF(m.filename, duration: duration, width: w, height: h, frames: m.frameCount)
            : Copy.fileLineVideo(m.filename, duration: duration, width: w, height: h)
    }
}

/// S5. The frame keeps the paused preview; progress and Cancel sit under it.
struct WorkingView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let text: String
    let fraction: Double?
    let canCancel: Bool

    var body: some View {
        if let file = model.lastLoaded {
            ScreenFrame(style: .solid, fill: Color(cgColor: file.background.cgColor)) {
                LoopPreviewView(file: file, playing: false)
            }
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 8) {
            BodyText(text)
            if let fraction {
                ProgressView(value: fraction).accessibilityLabel(text)
            } else {
                ProgressView().progressViewStyle(.linear).accessibilityLabel(text)
            }
        }
        Button(Copy.cancel) { model.cancel() }
            .keyboardShortcut(.cancelAction)
            .disabled(!canCancel)
            .help(canCancel ? "" : Copy.installingHelp)
        if !canCancel { BodyText(Copy.installingHelp) }
    }
}
