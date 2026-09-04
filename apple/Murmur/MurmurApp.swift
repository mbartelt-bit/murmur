import MurmurIntents
import MurmurShared
import SwiftUI

@main
struct MurmurApp: App {
    /// Built once, at launch: the settings store, the Keychain, the history database and the
    /// dictation pipeline. Everything the recorder needs is already warm by the time a
    /// `murmur://dictate` URL arrives, which is what keeps the microphone under the spec's
    /// ~300 ms budget (§6.2).
    @StateObject private var app = AppState()

    /// The Action Button, a Shortcut, Siri and the Control Center button all launch Murmur
    /// without a URL, so the activation itself is the signal — see
    /// ``AppState/consumeLaunchFlag(defaults:)``.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Re-donates "Dictate with Murmur" whenever the app's shortcuts could have changed.
        // Touching the type here is also what makes sure it is linked into the app binary at
        // all; App Shortcuts are otherwise dead code the optimiser is free to drop.
        MurmurShortcuts.updateAppShortcutParameters()

        #if DEBUG
        seedLaunchFlagIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                // Two consume points, because a launch flag arrives in two shapes. A *cold*
                // launch from the Action Button, a Shortcut or the Control Center button has
                // the scene already `.active` by the time this scene body exists, so no
                // `scenePhase` transition is ever delivered and only this first-appearance
                // pass sees the flag (verified on the simulator: with `onChange` alone the
                // recorder never came up). A *warm* one — Murmur already running in the
                // background — is the opposite, and `onChange` is the only thing that fires.
                // Consuming is idempotent, so having both costs nothing.
                .task { app.consumeLaunchFlag() }
                .onOpenURL { app.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    app.consumeLaunchFlag()
                }
                .fullScreenCover(item: $app.activeDictation) { request in
                    RecorderView(request: request, app: app)
                }
        }
    }

    #if DEBUG
    /// `-murmurLaunchFlag 1`, passed to `simctl launch`.
    ///
    /// There is no simulator equivalent of pressing a Control Center button, so this writes
    /// the same App Group flag ``DictateIntent`` would have written and lets the normal
    /// activation path take it from there. It exercises
    /// ``AppState/consumeLaunchFlag(defaults:)`` and the recorder presentation — not the App
    /// Intents runtime, which only a device can prove. Release builds have no such argument.
    private func seedLaunchFlagIfRequested() {
        // Launch arguments of the form `-key value` land in the standard defaults.
        guard UserDefaults.standard.bool(forKey: "murmurLaunchFlag") else { return }
        AppGroup.defaults.set("action-button", forKey: DictateIntent.launchFlagKey)
    }
    #endif
}
