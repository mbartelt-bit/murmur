import MurmurShared
import SwiftUI

/// The screen Murmur opens on: one big button, the readiness chips, the last three dictations.
///
/// The button is deliberately the largest thing on the phone — the whole product is "press
/// this and talk" — and the chips sit under it rather than above so that a healthy app reads
/// as a button with a receipt, not as a checklist.
struct HomeView: View {
    let app: AppState
    /// Tapping the engine chip switches tabs; RootView owns the selection.
    var onOpenSettings: () -> Void = {}

    @StateObject private var viewModel: HomeViewModel
    /// iOS publishes no link to the Action Button pane, so the "set it up" chip opens a sheet
    /// with the path written out instead of pretending to deep-link there.
    @State private var showsActionButtonGuide = false

    init(app: AppState, onOpenSettings: @escaping () -> Void = {}) {
        self.app = app
        self.onOpenSettings = onOpenSettings
        _viewModel = StateObject(wrappedValue: HomeViewModel(app: app))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    recovery
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
        .sheet(isPresented: $showsActionButtonGuide) { actionButtonGuide }
    }

    // MARK: - Pieces

    /// The one thing on Home that is more urgent than the dictate button, and only ever after
    /// a crash: audio Murmur recorded but never got to transcribe (spec §9). It sits above
    /// everything because the offer expires the moment the user starts a new dictation and
    /// forgets the old one.
    @ViewBuilder
    private var recovery: some View {
        if let pending = viewModel.pendingRecovery {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Copy.recoveryTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(Copy.recoveryBody(Copy.recoveryDuration(pending.duration)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await viewModel.finishPending() }
                        } label: {
                            Group {
                                if viewModel.isFinishingRecovery {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(Copy.recoveryFinish)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.murmurIndigo)

                        Button { viewModel.discardPending() } label: {
                            Text(Copy.recoveryDiscard)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(viewModel.isFinishingRecovery)
                }
            }
        } else if let error = viewModel.recoveryError {
            Card {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                Divider()
                // Both keyboard chips lead to the same place, because iOS has exactly one
                // public link into Settings and the difference is only in what to tap there.
                StatusChip(
                    title: Copy.chipKeyboard,
                    detail: viewModel.keyboardEnabled ? Copy.chipOn : Copy.chipOff,
                    state: viewModel.keyboardEnabled ? .ok : .attention,
                    action: { KeyboardStatus.openKeyboardSettings() }
                )
                Divider()
                StatusChip(
                    title: Copy.chipFullAccess,
                    detail: fullAccessDetail,
                    state: viewModel.fullAccess == true ? .ok : .attention,
                    action: { KeyboardStatus.openKeyboardSettings() }
                )
                if viewModel.hasActionButton {
                    Divider()
                    StatusChip(
                        title: Copy.chipActionButton,
                        detail: Copy.chipSetUp,
                        state: .attention,
                        action: { showsActionButtonGuide = true }
                    )
                }
            }
        }
    }

    private var fullAccessDetail: String {
        switch viewModel.fullAccess {
        case true?: return Copy.chipOn
        case false?: return Copy.chipOff
        default: return Copy.chipUnknown
        }
    }

    /// Three lines and the one button iOS allows: Settings opens at Murmur's own pane, and the
    /// user walks the rest of the way.
    private var actionButtonGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Copy.actionButtonTitle)
                .font(.title3.weight(.semibold))
            Text(Copy.triggersStepBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Copy.actionButtonCopy)
                .font(.subheadline)
            Button {
                showsActionButtonGuide = false
                KeyboardStatus.openKeyboardSettings()
            } label: {
                Text(Copy.openSettings)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.murmurIndigo)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .presentationDetents([.height(280)])
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
