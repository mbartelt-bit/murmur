import SwiftUI

@main
struct MurmurApp: App {
    /// Built once, at launch: the settings store, the Keychain, the history database and the
    /// dictation pipeline. Everything the recorder needs is already warm by the time a
    /// `murmur://dictate` URL arrives, which is what keeps the microphone under the spec's
    /// ~300 ms budget (§6.2).
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .onOpenURL { app.handle($0) }
                .fullScreenCover(item: $app.activeDictation) { request in
                    RecorderView(request: request, app: app)
                }
        }
    }
}
