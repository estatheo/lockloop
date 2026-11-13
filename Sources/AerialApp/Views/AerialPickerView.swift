import AerialKit
import AppKit
import SwiftUI

/// S4. No aerial is on this Mac yet: download one from Apple, or pick one in System Settings.
struct AerialPickerView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    var body: some View {
        Text(Copy.needsAerialHeading)
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        BodyText(Copy.needsAerialBody)

        if case .downloading(let name, let done, let total) = model.screen {
            VStack(alignment: .leading, spacing: 8) {
                BodyText(Copy.downloading(name, done: done, total: total))
                if let total, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Button(Copy.cancelDownload) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        } else if model.aerials.isEmpty {
            BodyText(Copy.noDownloadableAerials)
            Button(Copy.openWallpaperSettings) { model.openWallpaperSettings() }
        } else {
            List(model.aerials, id: \.id, selection: Binding(get: { model.selectedAerialID }, set: { model.selectAerial($0) })) { asset in
                AerialRow(asset: asset, thumbnail: thumbnail(asset.id))
            }
            .frame(minHeight: 180, idealHeight: 240)
            .accessibilityLabel(Copy.aerialListLabel)
            if let note = model.downloadNote { BodyText(note) }
            Button(Copy.downloadButton(size: model.selectedAerialSize)) { model.downloadSelected() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedAerialID == nil)
            BodyText(Copy.needsAerialOtherRoute)
            Button(Copy.openWallpaperSettings) { model.openWallpaperSettings() }
        }
    }

    private func thumbnail(_ id: String) -> NSImage? {
        let url = model.env.thumbnailsDir.appendingPathComponent("\(id).png")
        return NSImage(contentsOf: url)
    }
}

private struct AerialRow: View {
    let asset: AerialAsset
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(16.0 / 9.0, contentMode: .fill)
                } else {
                    Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            Text(asset.displayName)
        }
        .accessibilityElement(children: .combine)
    }
}
