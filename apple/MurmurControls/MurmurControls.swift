import MurmurIntents
import SwiftUI
import WidgetKit

/// Murmur's widget extension. It contains exactly one thing: the Control Center / Lock Screen
/// button that starts a dictation (spec §6.3). No timeline widgets, no provider, no state —
/// and, like the keyboard, no microphone and no Rust core: it links MurmurIntents and
/// MurmurSharedBase only (see MurmurShared/Package.swift, LINK GRAPH RULE).
///
/// The bundle's deployment target is the app's (iOS 17) so the same `Murmur.app` installs
/// everywhere; controls themselves are iOS 18, so the body is behind an availability check and
/// the extension simply contains no widgets on iOS 17.
@main
struct MurmurControlsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 18, *) {
            DictateControl()
        }
    }
}

/// A one-press dictation for every iPhone, including the ones with no Action Button.
///
/// `ControlWidgetButton` runs ``DictateIntent`` in the app's process because the intent sets
/// `openAppWhenRun`; the recorder then comes up from the launch flag. That is the whole
/// mechanism — the control holds no state of its own, so there is nothing to refresh and no
/// timeline to keep alive.
@available(iOS 18, *)
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.murmur.app.controls.dictate") {
            ControlWidgetButton(action: DictateIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("Murmur Dictate")
        .description("Start a dictation")
    }
}
