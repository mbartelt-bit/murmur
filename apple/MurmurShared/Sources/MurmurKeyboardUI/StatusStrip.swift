import MurmurKeyboardCore
import MurmurSharedBase
import SwiftUI

/// Every word the keyboard says, in one place — the same reason the app has `Copy.swift`.
/// These lines are fixed by the design spec (§6.1) and the MM2 plan; do not reword one side
/// of the product without the other.
public enum KeyboardCopy {
    public static let idle = "Tap the mic to dictate"
    public static let waiting = "Listening in Murmur…"
    public static let needsFullAccess = "Turn on Full Access in Settings"
    public static let inserted = "Inserted"
    public static let insert = "Insert"
    public static let discard = "Discard"
    public static let settings = "Settings"
}

/// The strip where a system keyboard puts predictions. Murmur puts the state of the round
/// trip there instead: what to do, that Murmur is listening, the text that came back, or why
/// the mic will not work.
public struct StatusStrip: View {
    private let phase: KeyboardPhase
    private let onInsert: () -> Void
    private let onDiscard: () -> Void
    private let onSettings: () -> Void

    public init(
        phase: KeyboardPhase,
        onInsert: @escaping () -> Void = {},
        onDiscard: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {}
    ) {
        self.phase = phase
        self.onInsert = onInsert
        self.onDiscard = onDiscard
        self.onSettings = onSettings
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .idle:
                message(KeyboardCopy.idle)

            case .needsFullAccess:
                message(KeyboardCopy.needsFullAccess)
                action(KeyboardCopy.settings, prominent: true, run: onSettings)

            case .waiting:
                ProgressView()
                    .controlSize(.small)
                message(KeyboardCopy.waiting)

            case let .preview(result):
                // The transcript itself. One line, truncated: the strip is a confirmation,
                // not a text editor, and the full text is already in the app's history.
                Text(result.clean)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                action(KeyboardCopy.discard, prominent: false, run: onDiscard)
                action(KeyboardCopy.insert, prominent: true, run: onInsert)

            case .inserted:
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KeyboardPalette.indigo)
                message(KeyboardCopy.inserted)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, prominent: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color(.label))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(prominent ? KeyboardPalette.indigo : Color(.systemGray4))
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
