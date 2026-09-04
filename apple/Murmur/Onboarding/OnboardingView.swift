import MurmurShared
import SwiftUI

/// First run. One step per screen, one primary button per step, in the spec's order: the
/// microphone, speech recognition, the engine, and one real dictation.
///
/// Everything that decides *whether* a step is done lives in ``OnboardingViewModel``; this
/// file only decides what it looks like.
struct OnboardingView: View {
    let app: AppState

    @StateObject private var viewModel: OnboardingViewModel
    @StateObject private var engine: EngineSettingsViewModel

    init(app: AppState) {
        self.app = app
        let history = app.history
        _viewModel = StateObject(
            wrappedValue: OnboardingViewModel(
                settings: app.settings,
                hasTestTranscript: {
                    let rows = (try? history.recent(HomeViewModel.recentCount)) ?? []
                    return rows.contains { $0.source == .inApp }
                }
            )
        )
        _engine = StateObject(
            wrappedValue: EngineSettingsViewModel(settings: app.settings, secrets: app.secrets)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    step
                }
                .padding(20)
            }
            footer
        }
        .murmurScreenBackground()
        .task { await viewModel.refresh() }
        // The test step's Finish unlocks the moment the recorder closes and a row exists.
        .onChange(of: app.activeDictation) { _, request in
            if request == nil { Task { await viewModel.refresh() } }
        }
        // Reaching the engine step with Local selected starts the model download, if any.
        .task(id: viewModel.step) {
            if viewModel.step == .engine, viewModel.stt == .local { await viewModel.prepareLocal() }
        }
        .onChange(of: engine.verifyState) { _, states in
            viewModel.cloudVerified = viewModel.stt.provider.map { states[$0] == .connected } ?? false
        }
    }

    // MARK: - Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingViewModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == viewModel.step ? Color.murmurIndigo : Color(.tertiaryLabel))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.step == .microphone {
                Text(Copy.welcomeTitle)
                    .font(.largeTitle.weight(.bold))
                Text(Copy.welcomeSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            Text(stepTitle)
                .font(.title2.weight(.semibold))
            Text(stepBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.murmurIndigo)
            .disabled(primaryDisabled)

            if viewModel.step == .test, !viewModel.didTest {
                Button(Copy.skipForNow) { viewModel.finish() }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Steps

    private var stepTitle: String {
        switch viewModel.step {
        case .microphone: return Copy.micStepTitle
        case .speech: return Copy.speechStepTitle
        case .engine: return Copy.engineStepTitle
        case .test: return Copy.testStepTitle
        }
    }

    private var stepBody: String {
        switch viewModel.step {
        case .microphone: return Copy.micStepBody
        case .speech: return Copy.speechStepBody
        case .engine: return Copy.engineStepBody
        case .test: return Copy.testStepBody
        }
    }

    @ViewBuilder
    private var step: some View {
        switch viewModel.step {
        case .microphone:
            permissionCard(status: viewModel.mic, granted: Copy.micGranted, denied: Copy.micDenied)
        case .speech:
            permissionCard(status: viewModel.speech, granted: Copy.speechGranted, denied: Copy.speechDenied)
        case .engine:
            engineStep
        case .test:
            testStep
        }
    }

    private func permissionCard(status: PermissionStatus, granted: String, denied: String) -> some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status == .granted ? Color.green : Color.secondary)
                Text(status == .granted ? granted : (status == .denied ? denied : Copy.permissionPending))
                    .font(.subheadline)
                    .foregroundStyle(status == .denied ? .primary : .secondary)
            }
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(Copy.transcriptionSection, selection: sttBinding) {
                ForEach(SttEngine.allCases, id: \.self) { engine in
                    Text(Copy.sttLabel(engine)).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.stt == .local {
                Card {
                    HStack(spacing: 10) {
                        if viewModel.preparingLocal {
                            ProgressView()
                            Text(Copy.preparingLocal)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: viewModel.localReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(viewModel.localReady ? Color.green : Color.orange)
                            Text(viewModel.localReady ? Copy.localReady : Copy.localUnavailable)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let provider = viewModel.stt.provider {
                ProviderKeyView(provider: provider, engine: engine)
            }
        }
    }

    private var testStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    app.startInAppDictation()
                } label: {
                    Label(Copy.tryDictation, systemImage: "mic.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(Color.murmurIndigo)

                if viewModel.didTest {
                    Label(Copy.testStepDone, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.green)
                }
            }
        }
    }

    // MARK: - Primary button

    /// The single thing to do on this step. On a permission step it is the system prompt until
    /// the answer is "no", after which the only way forward is Settings.
    private var primaryTitle: String {
        switch viewModel.step {
        case .microphone:
            if viewModel.mic == .granted { return Copy.continueLabel }
            return viewModel.mic == .denied ? Copy.openSettings : Copy.micAllow
        case .speech:
            if viewModel.speech == .granted || viewModel.stt != .local { return Copy.continueLabel }
            return viewModel.speech == .denied ? Copy.openSettings : Copy.speechAllow
        case .engine:
            return Copy.continueLabel
        case .test:
            return Copy.finish
        }
    }

    private var primaryDisabled: Bool {
        switch viewModel.step {
        // A permission step's button is never dead: it is either the prompt, the way to
        // Settings, or Continue.
        case .microphone, .speech: return false
        case .engine, .test: return !viewModel.canAdvance
        }
    }

    private func primaryAction() {
        switch viewModel.step {
        case .microphone:
            if viewModel.mic == .granted { viewModel.advance() }
            else if viewModel.mic == .denied { Permissions.openSettings() }
            else { Task { await viewModel.requestMic(); if viewModel.canAdvance { viewModel.advance() } } }
        case .speech:
            if viewModel.canAdvance { viewModel.advance() }
            else if viewModel.speech == .denied { Permissions.openSettings() }
            else { Task { await viewModel.requestSpeech(); if viewModel.canAdvance { viewModel.advance() } } }
        case .engine:
            viewModel.advance()
        case .test:
            viewModel.finish()
        }
    }

    private var sttBinding: Binding<SttEngine> {
        Binding(get: { viewModel.stt }, set: { viewModel.choose(stt: $0); engine.set(stt: $0) })
    }
}
