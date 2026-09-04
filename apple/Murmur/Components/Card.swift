import SwiftUI

/// The rounded panel every screen is built out of — the phone's answer to the desktop's
/// `.card` class (`src/index.css`): a slightly raised surface, 14 pt corners, no border.
///
/// It uses `secondarySystemGroupedBackground` rather than a fixed colour so it sits correctly
/// on the grouped background in both light and dark mode without a second palette.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// The screen background behind cards: the same grouped grey `List` uses, so a screen
    /// built from cards and a screen built from a `Form` look like one app.
    func murmurScreenBackground() -> some View {
        background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// A small all-caps label above a group, matching the desktop's `.section-label`.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
