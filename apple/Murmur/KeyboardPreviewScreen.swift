#if DEBUG
import MurmurKeyboardCore
import MurmurKeyboardUI
import MurmurShared
import SwiftUI

/// `-murmurScreen keyboardPreview`, debug builds only.
///
/// A real keyboard can only be photographed on a device or after a human enables it in
/// Settings, which a simulator run cannot do. This screen draws the same `KeyboardView` the
/// extension hosts, in the states worth looking at, so the layout can be reviewed from a
/// simulator screenshot. It is not shipped: `ScreenshotMode.requested` is `nil` in a release
/// build, so nothing can route here.
struct KeyboardPreviewScreen: View {
    @State private var model: Model?

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.height - 96) / (4 * Model.keyboardHeight))
            VStack(spacing: 6) {
                ForEach(model?.samples ?? [], id: \.title) { sample in
                    VStack(spacing: 3) {
                        Text(sample.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        KeyboardView(controller: sample.controller)
                            .frame(width: geo.size.width, height: Model.keyboardHeight)
                            .scaleEffect(scale, anchor: .top)
                            // `.top`, to match the scale anchor: `scaleEffect` leaves the
                            // layout frame at full size, and centring it here would push the
                            // status strip above the clip.
                            .frame(
                                width: geo.size.width * scale,
                                height: Model.keyboardHeight * scale,
                                alignment: .top
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .murmurScreenBackground()
        .onAppear { if model == nil { model = Model() } }
    }

    /// Built in `onAppear` rather than in `init` so the `@MainActor` controllers are made on
    /// the main actor without an escaping autoclosure.
    @MainActor
    final class Model {
        static let keyboardHeight: CGFloat = 216

        struct Sample {
            let title: String
            let controller: KeyboardController
        }

        let samples: [Sample]

        init() {
            // A throwaway suite: the preview must not write a pending request or claim a real
            // result out of the App Group the app and the keyboard actually share.
            let suite = "murmur.keyboard.preview"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)

            func controller() -> KeyboardController {
                KeyboardController(
                    defaults: defaults,
                    urlOpener: NoOpOpener(),
                    hasFullAccess: { true }
                )
            }

            let letters = controller()

            let numbers = controller()
            numbers.state.page = .numbers

            let symbols = controller()
            symbols.state.page = .symbols

            let preview = controller()
            Handoff.writeResult(
                DictationResult(
                    session: Handoff.intentSession,
                    raw: "um can you send me the deck before the meeting tomorrow",
                    clean: "Can you send me the deck before the meeting tomorrow?",
                    createdAt: Date(),
                    inserted: false
                ),
                defaults: defaults
            )
            preview.checkForResult()

            samples = [
                Sample(title: "Letters · idle", controller: letters),
                Sample(title: "Numbers", controller: numbers),
                Sample(title: "Symbols", controller: symbols),
                Sample(title: "Preview · Insert / Discard", controller: preview),
            ]
        }
    }

    private final class NoOpOpener: URLOpening {
        func open(_ url: URL) -> Bool { true }
    }
}
#endif
