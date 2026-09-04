import MurmurShared
import SwiftUI

/// Engines, keys, the two behaviour toggles, and the version.
///
/// Everything saves the instant it is touched — there is no Save button, because the keyboard
/// extension reads the App Group defaults directly and a half-applied setting would mean the
/// keyboard and the app disagreeing about which engine is running.
struct SettingsView: View {
    @StateObject private var engine: EngineSettingsViewModel
    @ObservedObject private var settings: SettingsStore

    init(app: AppState) {
        settings = app.settings
        _engine = StateObject(
            wrappedValue: EngineSettingsViewModel(settings: app.settings, secrets: app.secrets)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Copy.transcriptionSection, selection: sttBinding) {
                        ForEach(SttEngine.allCases, id: \.self) { option in
                            Text(Copy.sttLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text(Copy.transcriptionSection)
                } footer: {
                    Text(Copy.engineStepBody)
                }

                Section(Copy.cleanupSection) {
                    Picker(Copy.cleanupSection, selection: cleanupBinding) {
                        ForEach(CleanupEngine.allCases, id: \.self) { option in
                            Text(Copy.cleanupLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // One block per provider actually in use — Local speech with OpenAI cleanup
                // still needs the OpenAI key, which is the rule the desktop learned the hard way.
                ForEach(engine.providersInUse, id: \.self) { provider in
                    Section {
                        ProviderKeyView(provider: provider, engine: engine)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    Toggle(Copy.autoStopToggle, isOn: autoStopBinding)
                    Toggle(Copy.clipboardToggle, isOn: clipboardBinding)
                } footer: {
                    Text(Copy.clipboardFooter)
                }

                Section(Copy.aboutSection) {
                    LabeledContent(Copy.versionRow, value: Self.version)
                }
            }
            .tint(Color.murmurIndigo)
            .navigationTitle(Copy.settingsTab)
        }
    }

    // MARK: - Bindings

    // Written through the view models so the persist-and-publish path is the same one the
    // tests exercise; a `Binding` straight to the stored property would bypass both.
    private var sttBinding: Binding<SttEngine> {
        Binding(get: { engine.stt }, set: { engine.set(stt: $0) })
    }

    private var cleanupBinding: Binding<CleanupEngine> {
        Binding(get: { engine.cleanup }, set: { engine.set(cleanup: $0) })
    }

    private var autoStopBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.autoStopOnSilence },
            set: { value in settings.update { $0.autoStopOnSilence = value } }
        )
    }

    private var clipboardBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.copyToClipboard },
            set: { value in settings.update { $0.copyToClipboard = value } }
        )
    }

    /// "0.1.0 (1)" — the marketing version and the build, which is what a TestFlight report
    /// needs to be actionable.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
