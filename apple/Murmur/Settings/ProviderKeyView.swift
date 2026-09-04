import MurmurShared
import SwiftUI

/// The guided "connect a provider" block, shared by Settings and onboarding's engine step —
/// the phone's version of the desktop's `ConnectBlock`.
///
/// The typed key lives in exactly one `@State String`, which is cleared the moment
/// ``EngineSettingsViewModel/saveKey(_:for:)`` has put it in the Keychain. It is never
/// rendered back, never held by the view model, and never leaves this file.
struct ProviderKeyView: View {
    let provider: ProviderId
    @ObservedObject var engine: EngineSettingsViewModel

    @State private var key = ""

    private var state: EngineSettingsViewModel.VerifyState {
        engine.verifyState[provider] ?? .idle
    }

    private var keyPresent: Bool {
        engine.keyPresent[provider] ?? false
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                steps
                if keyPresent { savedKeyRow } else { entryRow }
                statusLine
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Copy.connectProvider(provider))
                .font(.subheadline.weight(.semibold))
            Text(provider.costLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer(minLength: 8)
            Button(Copy.getApiKey) { engine.openKeyPage(provider) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.murmurIndigo)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(provider.signupSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entryRow: some View {
        HStack(spacing: 8) {
            SecureField(Copy.keyFieldPlaceholder(provider), text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)

            Button(engine.saving == provider ? Copy.connecting : Copy.connect) {
                let pasted = key
                // Cleared before the await, not after: the field must not hold a key for the
                // length of a network round trip.
                key = ""
                Task { await engine.saveKey(pasted, for: provider) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.murmurIndigo)
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.saving == provider)
        }
    }

    private var savedKeyRow: some View {
        HStack(spacing: 12) {
            Label(Copy.keySaved, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(Copy.verify) { Task { await engine.verify(provider) } }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.murmurIndigo)
                .disabled(state == .verifying)
            Button(Copy.removeKey) { engine.removeKey(for: provider) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .idle:
            EmptyView()
        case .verifying:
            Text(Copy.verifying)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected:
            Text(Copy.connected)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
