import MurmurShared
import SwiftUI

/// The three tabs, in the order the spec lists them.
enum MurmurTab: Hashable { case home, history, settings }

/// The app's one navigation decision: onboarding, or the three tabs.
///
/// `AppState` is not what changes when onboarding finishes — ``SettingsStore`` is — so the
/// body that reads `onboardingComplete` has to observe the store itself. That is the whole
/// reason for the inner `Shell`: `@EnvironmentObject` can hand over the state, but only a real
/// `@ObservedObject` property re-renders when a nested store publishes.
struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Shell(app: app, settings: app.settings)
    }
}

private struct Shell: View {
    let app: AppState
    @ObservedObject var settings: SettingsStore

    @State private var tab: MurmurTab

    init(app: AppState, settings: SettingsStore) {
        self.app = app
        self.settings = settings
        _tab = State(initialValue: ScreenshotMode.tab ?? .home)
        ScreenshotMode.seedHistoryIfRequested(app)
    }

    var body: some View {
        Group {
            if showsOnboarding {
                OnboardingView(app: app)
            } else {
                tabs
            }
        }
        .tint(Color.murmurIndigo)
    }

    /// Onboarding runs until it is finished — or whenever a debug launch asks for it by name.
    private var showsOnboarding: Bool {
        if ScreenshotMode.forcesOnboarding { return true }
        if ScreenshotMode.tab != nil { return false }
        return !settings.settings.onboardingComplete
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            HomeView(app: app, onOpenSettings: { tab = .settings })
                .tabItem { Label(Copy.homeTab, systemImage: "mic.circle.fill") }
                .tag(MurmurTab.home)

            HistoryView(app: app)
                .tabItem { Label(Copy.historyTab, systemImage: "clock") }
                .tag(MurmurTab.history)

            SettingsView(app: app)
                .tabItem { Label(Copy.settingsTab, systemImage: "gearshape") }
                .tag(MurmurTab.settings)
        }
    }
}

// MARK: - Deterministic screenshots (debug builds only)

/// `-murmurScreen home|history|settings|onboarding`, passed to `simctl launch`.
///
/// It exists so a screenshot pass can land on a known screen without driving the UI, and so
/// History and Home are not photographed empty. Every branch is inside `#if DEBUG`: a release
/// build reports no screen, seeds nothing, and cannot be talked into either.
private enum ScreenshotMode {
    static var requested: String? {
        #if DEBUG
        // Launch arguments of the form `-key value` land in the standard defaults, so there
        // is nothing to parse.
        return UserDefaults.standard.string(forKey: "murmurScreen")
        #else
        return nil
        #endif
    }

    static var forcesOnboarding: Bool { requested == "onboarding" }

    static var tab: MurmurTab? {
        switch requested {
        case "home": return .home
        case "history": return .history
        case "settings": return .settings
        default: return nil
        }
    }

    private static var seeded = false

    /// Two rows so the History and Home screenshots show a real list. Runs only in a debug
    /// build launched with `-murmurScreen`, only once, and only when the database is empty, so
    /// a developer's own dictations are never mixed in with these.
    static func seedHistoryIfRequested(_ app: AppState) {
        #if DEBUG
        guard requested != nil, !seeded else { return }
        seeded = true
        guard let existing = try? app.history.recent(1), existing.isEmpty else { return }

        let now = Date()
        let samples: [(raw: String, clean: String, source: TranscriptSource, ago: TimeInterval)] = [
            (
                "um so can you send me the deck before the meeting tomorrow",
                "Can you send me the deck before the meeting tomorrow?",
                .inApp,
                240
            ),
            (
                "picking up milk and uh coffee on the way home",
                "Picking up milk and coffee on the way home.",
                .keyboard,
                5400
            ),
        ]
        for sample in samples {
            _ = try? app.history.insert(
                Transcript(
                    rawText: sample.raw,
                    cleanText: sample.clean,
                    source: sample.source,
                    createdAt: now.addingTimeInterval(-sample.ago)
                )
            )
        }
        #endif
    }
}
