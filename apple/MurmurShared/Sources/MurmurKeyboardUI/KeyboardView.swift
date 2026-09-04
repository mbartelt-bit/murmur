import MurmurKeyboardCore
import MurmurSharedBase
import SwiftUI

/// The whole keyboard: the status strip, then the four rows of
/// ``KeyboardLayout/rows(for:)`` laid out with the system keyboard's proportions.
///
/// It owns no state of its own beyond which key is under a finger. Every tap goes back out
/// through ``onKey``, because two of the keys — globe and mic — can only be handled by the
/// `UIInputViewController` that hosts this view, and the rest have to be typed into a text
/// document proxy the view is not allowed to know about.
///
/// It lives in `MurmurKeyboardUI` rather than in the extension target so the app-hosted tests
/// can instantiate it; nothing here imports UIKit, AVFoundation, Speech, or the Rust core.
public struct KeyboardView: View {
    /// Row geometry, in points, at the layout width. The character key width is derived from
    /// the top row (ten keys, nine gaps, an edge inset each side) and every other key is a
    /// multiple of it, exactly as the system keyboard is built.
    private static let edgeInset: CGFloat = 3
    private static let keyGap: CGFloat = 6
    private static let stripHeight: CGFloat = 30

    @ObservedObject private var controller: KeyboardController
    private let showsGlobe: Bool
    private let onKey: (Key) -> Void
    private let onInsert: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// - Parameters:
    ///   - showsGlobe: `UIInputViewController.needsInputModeSwitchKey`. When the globe is the
    ///     only other keyboard iOS hides it, and so do we — the cap is dropped and the space
    ///     bar takes the room.
    ///   - onKey: every tap, including `.globe` and `.mic`; the host decides.
    ///   - onInsert: **Insert** in the preview strip. It needs the text document proxy, which
    ///     is why it is not just ``KeyboardController/insertPreview(proxy:)`` called here.
    public init(
        controller: KeyboardController,
        showsGlobe: Bool = true,
        onKey: @escaping (Key) -> Void = { _ in },
        onInsert: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.showsGlobe = showsGlobe
        self.onKey = onKey
        self.onInsert = onInsert
    }

    public var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                StatusStrip(
                    phase: controller.phase,
                    onInsert: onInsert,
                    onDiscard: { controller.discardPreview() },
                    onSettings: { controller.openSettings() }
                )
                .frame(height: Self.stripHeight)

                rows(in: geo.size)
            }
        }
        .background(KeyboardPalette.deck(scheme))
    }

    // MARK: - Rows

    private func rows(in size: CGSize) -> some View {
        let rows = layoutRows
        let unit = max(1, (size.width - 2 * Self.edgeInset - 9 * Self.keyGap) / 10)
        let deck = max(1, size.height - Self.stripHeight)
        // Five vertical gaps for four rows: one above, one below, three between. Landscape is
        // 162 pt tall against portrait's 216, so the gap shrinks before the keys do.
        let rowGap: CGFloat = deck < 150 ? 4 : 6
        let rowHeight = max(1, (deck - rowGap * CGFloat(rows.count + 1)) / CGFloat(rows.count))

        let available = size.width - 2 * Self.edgeInset

        return VStack(spacing: rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let widths = Self.widths(for: row, unit: unit, available: available)
                HStack(spacing: Self.keyGap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, key in
                        cap(for: key)
                            .modifier(KeyWidth(width: widths[index]))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
            }
        }
        .padding(.horizontal, Self.edgeInset)
        .padding(.vertical, rowGap)
    }

    /// The layout, minus the globe when iOS says there is nothing to switch to.
    private var layoutRows: [[Key]] {
        KeyboardLayout.rows(for: controller.state.page).map { row in
            showsGlobe ? row : row.filter { $0 != .globe }
        }
    }

    private func cap(for key: Key) -> some View {
        KeyCap(
            content: content(for: key),
            role: role(for: key),
            fontSize: fontSize(for: key),
            repeats: key == .delete,
            action: { onKey(key) }
        )
    }

    // MARK: - Cap contents

    private func content(for key: Key) -> KeyCap.Content {
        switch key {
        case let .char(cap):
            return .text(KeyboardLayout.text(for: key, shift: controller.state.shift) ?? cap)
        case .shift:
            switch controller.state.shift {
            case .off: return .symbol("shift")
            case .on: return .symbol("shift.fill")
            case .capsLock: return .symbol("capslock.fill")
            }
        case .delete: return .symbol("delete.left")
        case .numbers: return .text("123")
        case .symbols: return .text("#+=")
        case .letters: return .text("ABC")
        case .globe: return .symbol("globe")
        case .mic: return .symbol("mic.fill")
        case .space: return .text("space")
        case .return: return .text("return")
        }
    }

    private func role(for key: Key) -> KeyCap.Role {
        switch key {
        case .char, .space: return .primary
        case .mic: return .accent
        // An engaged shift goes light, the way the system keyboard shows it is armed.
        case .shift: return controller.state.shift == .off ? .modifier : .primary
        default: return .modifier
        }
    }

    private func fontSize(for key: Key) -> CGFloat {
        switch key {
        case .char: return 22
        case .shift, .delete, .globe, .mic: return 19
        case .numbers, .symbols, .letters, .space, .return: return 15
        }
    }

    /// The width of every cap in a row, or `nil` for one that takes what is left.
    ///
    /// A row of ten character keys fills the deck exactly, and so does `shift` + seven letters
    /// + `delete`. The punctuation row on the number and symbol pages does not — five caps
    /// between the page toggle and delete leave slack — and the system keyboard spends that
    /// slack on the two outer keys rather than on margins, which is why `#+=` and `⌫` are
    /// noticeably wider there. Rows whose outer keys are characters (the `asdfghjkl` row) stay
    /// centred instead.
    private static func widths(for row: [Key], unit: CGFloat, available: CGFloat) -> [CGFloat?] {
        var widths = row.map { units($0).map { $0 * unit } }
        guard !widths.contains(where: { $0 == nil }),
              let first = row.first, let last = row.last, row.count >= 2,
              !isCharacter(first), !isCharacter(last)
        else { return widths }

        let natural = widths.compactMap { $0 }.reduce(0, +) + CGFloat(row.count - 1) * keyGap
        let slack = available - natural
        guard slack > 0.5 else { return widths }

        widths[0] = (widths[0] ?? 0) + slack / 2
        widths[widths.count - 1] = (widths[widths.count - 1] ?? 0) + slack / 2
        return widths
    }

    private static func isCharacter(_ key: Key) -> Bool {
        if case .char = key { return true }
        return false
    }

    /// How many character-key widths a cap is worth. `nil` means "take what is left", which
    /// only the space bar does.
    private static func units(_ key: Key) -> CGFloat? {
        switch key {
        case .char: return 1
        case .shift, .delete, .numbers, .symbols, .letters: return 1.5
        case .globe, .mic: return 1.15
        case .return: return 2.2
        case .space: return nil
        }
    }
}

/// Fixed width for a weighted cap, flexible for the space bar. A `ViewModifier` so the
/// `if`/`else` does not split the row's `ForEach` into two branches with different types.
private struct KeyWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}
