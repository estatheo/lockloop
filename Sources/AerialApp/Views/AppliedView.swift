import AerialKit
import SwiftUI

/// S6. What is on the lock screen now, Keep it applied, and the way back.
struct AppliedView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let filename: String
    let justApplied: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        ScreenFrame(style: .solid, fill: .black) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
        .task(id: filename) { thumbnail = await model.appliedThumbnail() }

        BodyText(justApplied ? Copy.doneJustApplied : Copy.appliedOnOpen(filename))
            .font(.title3.weight(.semibold))

        VStack(alignment: .leading, spacing: 8) {
            Toggle(Copy.keepApplied, isOn: Binding(get: { model.keepApplied }, set: { model.setKeepApplied($0) }))
                .toggleStyle(.switch)
            BodyText(Copy.keepAppliedHelp)
            if let note = model.keepNote { BodyText(note) }
        }

        HStack(spacing: 8) {
            Button(Copy.chooseAnotherFile) { model.chooseAnother() }
            Button(Copy.restoreApple) { model.restore() }
        }
    }
}
