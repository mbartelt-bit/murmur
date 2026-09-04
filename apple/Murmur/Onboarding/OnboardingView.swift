import MurmurShared
import SwiftUI

/// First run. One step per screen, one primary button per step, in the spec's order: the
/// microphone, speech recognition, the engine, the keyboard, the other ways to start a
/// dictation, and one real one.
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
        let model = OnboardingViewModel(
            settings: app.settings,
            hasTestTranscript: {
                let rows = (try? history.recent(HomeViewModel.recentCount)) ?? []
                return rows.contains { $0.source == .inApp }
            }
        )
        // "Test it" on the triggers step runs exactly what the Action Button runs, down to the
        // session id, so what the user sees here is what they will see from the hardware.
        model.onTestTrigger = { [weak app] in
            app?.activeDictation = DictationRequest(session: Handoff.intentSession, source: .actionButton)
        }
        #if DEBUG
        if let step = ScreenshotMode.onboardingStep { model.step = step }
        #endif
        _viewModel = StateObject(wrappedValue: model)
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
        // The keyboard step is the one the user leaves mid-way, so it watches for the answer
        // instead of waiting to be told. Cancelled by SwiftUI when the step changes.
        .task(id: viewModel.step) {
            if viewModel.step == .keyboard { await viewModel.pollKeyboardStatus() }
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
        case .keyboard: return Copy.keyboardStepTitle
        case .triggers: return Copy.triggersStepTitle
        case .test: return Copy.testStepTitle
        }
    }

    private var stepBody: String {
        switch viewModel.step {
        case .microphone: return Copy.micStepBody
        case .speech: return Copy.speechStepBody
        case .engine: return Copy.engineStepBody
        case .keyboard: return Copy.keyboardStepBody
        case .triggers: return Copy.triggersStepBody
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
        case .keyboard:
            keyboardStep
        case .triggers:
            triggersStep
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

    /// The path, the Full Access line, and the way to check — plus the live answer, which the
    /// step polls for while the user is away in Settings.
    private var keyboardStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    instruction(number: 1, text: Copy.keyboardStepPath)
                    instruction(number: 2, text: Copy.keyboardFullAccessLine)
                    instruction(number: 3, text: Copy.keyboardCheckLine)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    statusLine(
                        ok: viewModel.keyboardEnabled,
                        text: viewModel.keyboardEnabled ? Copy.keyboardStepDone : Copy.keyboardStepWaiting
                    )

                    if !viewModel.fullAccessDeferred {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            statusLine(ok: viewModel.fullAccess == true, text: fullAccessText)
                            if viewModel.fullAccess != true {
                                Spacer(minLength: 0)
                                Button(Copy.later) { viewModel.deferFullAccess() }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var fullAccessText: String {
        switch viewModel.fullAccess {
        case true?: return Copy.fullAccessOn
        case false?: return Copy.fullAccessOff
        default: return Copy.fullAccessUnknown
        }
    }

    /// Control Center on every iPhone (iOS 18+), the Action Button only where there is one.
    private var triggersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Copy.controlCenterTitle, systemImage: "switch.2")
                        .font(.subheadline.weight(.semibold))
                    Text(Copy.controlCenterCopy)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.hasActionButton {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(Copy.actionButtonTitle, systemImage: "button.horizontal.top.press")
                            .font(.subheadline.weight(.semibold))
                        Text(Copy.actionButtonCopy)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                viewModel.testTrigger()
            } label: {
                Label(Copy.testIt, systemImage: "mic.fill")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Color.murmurIndigo)
        }
    }

    private func instruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.murmurIndigo, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(ok: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        case .engine, .triggers:
            return Copy.continueLabel
        case .keyboard:
            // Same shape as a permission step: the way to do the one job until it is done,
            // then the way onward. Nothing else on this screen can add the keyboard.
            return viewModel.keyboardEnabled ? Copy.continueLabel : Copy.openSettings
        case .test:
            return Copy.finish
        }
    }

    private var primaryDisabled: Bool {
        switch viewModel.step {
        // A permission step's button is never dead: it is either the prompt, the way to
        // Settings, or Continue.
        case .microphone, .speech, .keyboard: return false
        case .engine, .triggers, .test: return !viewModel.canAdvance
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
        case .engine, .triggers:
            viewModel.advance()
        case .keyboard:
            if viewModel.keyboardEnabled { viewModel.advance() } else { KeyboardStatus.openKeyboardSettings() }
        case .test:
            viewModel.finish()
        }
    }

    private var sttBinding: Binding<SttEngine> {
        Binding(get: { viewModel.stt }, set: { viewModel.choose(stt: $0); engine.set(stt: $0) })
    }
}
