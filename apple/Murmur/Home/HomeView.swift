import MurmurShared
import SwiftUI

/// The screen Murmur opens on: one big button, three status chips, the last three dictations.
///
/// The button is deliberately the largest thing on the phone — the whole product is "press
/// this and talk" — and the chips sit under it rather than above so that a healthy app reads
/// as a button with a receipt, not as a checklist.
struct HomeView: View {
    let app: AppState
    /// Tapping the engine chip switches tabs; RootView owns the selection.
    var onOpenSettings: () -> Void = {}

    @StateObject private var viewModel: HomeViewModel

    init(app: AppState, onOpenSettings: @escaping () -> Void = {}) {
        self.app = app
        self.onOpenSettings = onOpenSettings
        _viewModel = StateObject(wrappedValue: HomeViewModel(app: app))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    dictateButton
                    chips
                    recent
                }
                .padding(20)
                // Clearance for the floating tab bar, which the scroll view's own inset does
                // not account for once the content is short enough not to scroll.
                .padding(.bottom, 24)
            }
            .murmurScreenBackground()
            .navigationTitle(Copy.appName)
        }
        .onAppear { viewModel.reload() }
        // A dictation just finished: the recorder has closed and the row is already written.
        .onChange(of: app.activeDictation) { _, request in
            if request == nil { viewModel.reload() }
        }
    }

    // MARK: - Pieces

    private var dictateButton: some View {
        Button {
            viewModel.startDictation()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .medium))
                Text(Copy.tryDictation)
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(Color.murmurIndigo, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var chips: some View {
        Card(padding: 14) {
            VStack(spacing: 14) {
                StatusChip(
                    title: Copy.chipMic,
                    detail: detail(for: viewModel.mic),
                    state: viewModel.mic == .granted ? .ok : .attention,
                    action: viewModel.mic == .granted ? nil : { Task { await viewModel.fixMic() } }
                )
                if viewModel.showsSpeechChip {
                    Divider()
                    StatusChip(
                        title: Copy.chipSpeech,
                        detail: detail(for: viewModel.speech),
                        state: viewModel.speech == .granted ? .ok : .attention,
                        action: viewModel.speech == .granted ? nil : { Task { await viewModel.fixSpeech() } }
                    )
                }
                Divider()
                StatusChip(
                    title: Copy.chipEngine,
                    detail: viewModel.engineSummary,
                    state: viewModel.engineNeedsAttention ? .attention : .ok,
                    action: onOpenSettings
                )
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(Copy.recentTitle)

            if app.historyUnavailable {
                Text(Copy.historyUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.recent.isEmpty {
                Card {
                    Text(Copy.noDictationsYet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.recent) { transcript in
                            Button { viewModel.copy(transcript) } label: {
                                TranscriptRow(
                                    transcript: transcript,
                                    copied: viewModel.copiedID == transcript.id
                                )
                                .padding(14)
                            }
                            .buttonStyle(.plain)

                            if transcript.id != viewModel.recent.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                Text(Copy.tapToCopy)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detail(for status: PermissionStatus) -> String {
        switch status {
        case .granted: return Copy.chipAllowed
        case .notDetermined: return Copy.chipTapToAllow
        case .denied: return Copy.chipTapToFix
        }
    }
}

/// One dictation, as Home and History both draw it: the cleaned line, when it happened, and
/// where it came from.
struct TranscriptRow: View {
    let transcript: Transcript
    var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(transcript.cleanText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(transcript.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Copy.sourceLabel(transcript.source))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .accessibilityLabel(copied ? Copy.copied : Copy.tapToCopy)
        }
        .contentShape(Rectangle())
    }
}
