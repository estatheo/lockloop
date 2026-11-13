import SwiftUI

/// The 16:9 frame drawn as a screen. The drop zone, the preview and the done screen
/// all use it, so the person always sees "this is your lock screen".
struct ScreenFrame<Content: View>: View {
    enum Style { case dashed, solid, targeted }
    var style: Style = .solid
    var fill: Color = Color(nsColor: .controlBackgroundColor)
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            content()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: style == .targeted ? .controlAccentColor : (style == .dashed ? .secondaryLabelColor : .separatorColor)),
                              style: StrokeStyle(lineWidth: style == .targeted ? 2 : 1, dash: style == .dashed ? [6, 4] : []))
        }
    }
}

/// Text that informs: always the primary label colour, so it passes contrast in light, dark and Increase Contrast.
struct BodyText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
