import MurmurShared
import SwiftUI

/// The full-screen recorder: the only screen in Murmur that a user can reach without opening
/// the app, since `murmur://dictate` presents it over whatever was on screen.
///
/// The view is deliberately thin — every decision lives in ``RecorderViewModel`` — and every
/// phase is one glance: a dot while it listens, a squiggle while it thinks, a card when it is
/// done. Tapping anywhere ends the recording, because the user's hands are usually nowhere
/// near a button when they stop talking.
struct RecorderView: View {
    @StateObject private var viewModel: RecorderViewModel
    @Environment(\.dismiss) private var dismiss

    init(request: DictationRequest, app: AppState) {
        _viewModel = StateObject(
            wrappedValue: RecorderViewModel(
                request: request,
                pipeline: app.pipeline,
                settings: app.settings
            )
        )
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            content
                .padding(.horizontal, 28)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Only while the microphone is open; a tap on the finished card should not do
            // anything surprising.
            if isStoppable { viewModel.stop() }
        }
        .task {
            viewModel.onDismiss = { dismiss() }
            await viewModel.start()
        }
        .onDisappear { viewModel.stop() }
    }

    private var isStoppable: Bool {
        switch viewModel.phase {
        case .starting, .recording: return true
        case .transcribing, .done, .failed: return false
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .starting:
            VStack(spacing: 24) {
                RecordingIndicator(level: 0)
                Text("Listening…")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

        case let .recording(level, elapsed):
            VStack(spacing: 24) {
                RecordingIndicator(level: level)
                Text(Self.timestamp(elapsed))
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("Tap anywhere to stop")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case let .transcribing(partial):
            VStack(spacing: 24) {
                TranscribingSquiggle()
                if partial.isEmpty {
                    Text("Transcribing…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(partial)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }

        case let .done(clean, copied):
            VStack(spacing: 20) {
                ScrollView {
                    Text(clean)
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .frame(maxHeight: 320)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )

                if copied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }

                if viewModel.showsSwipeBackHint {
                    Text("Swipe back to your app — the text will be inserted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: 220)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.murmurIndigo)
            }

        case let .failed(message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)

                if viewModel.failedNeedsSettings {
                    Button {
                        Permissions.openSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: 220)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.murmurIndigo)
                } else {
                    Button {
                        Task { await viewModel.start() }
                    } label: {
                        Text("Try again")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: 220)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.murmurIndigo)
                }

                Button("Close") { dismiss() }
                    .font(.footnote)
                    .tint(.secondary)
            }
        }
    }

    /// `m:ss`, the shape of every recording timer.
    private static func timestamp(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
