import SwiftUI

/// One line of "is this ready?" on the Home screen, and the button that fixes it.
///
/// The whole chip is the fix button rather than a label with a small button beside it: on a
/// phone the thing a user wants to tap is the problem itself, and a chip that is already fine
/// simply has nothing to do (it stays a plain label, not a dead-looking disabled control).
struct StatusChip: View {
    enum State {
        /// Nothing to do.
        case ok
        /// Needs a tap: a permission to ask for, a Settings trip, or a missing key.
        case attention
    }

    let title: String
    let detail: String
    let state: State
    /// `nil` for a chip that cannot be acted on.
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(state == .ok ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if action != nil, state == .attention {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusChip(title: "Microphone", detail: "Allowed", state: .ok)
        StatusChip(title: "Speech", detail: "Tap to allow", state: .attention, action: {})
    }
    .padding()
}
