import XCTest

import SwiftUI

import MurmurKeyboardCore
import MurmurKeyboardUI
import MurmurShared

/// Not a snapshot test — a crash test.
///
/// `KeyboardView` divides the available width and height to size its caps, so a zero-width
/// layout pass, an empty row, or a phase the strip forgot to handle would trap at runtime
/// inside the extension, where there is nothing to catch it. Hosting the view for every page
/// × phase and forcing a layout in the real 390 × 216 pt input view is what makes that a test
/// failure here rather than a keyboard that dismisses itself on someone's phone.
///
/// The typing logic itself is covered by `KeyboardLayoutTests` and `KeyboardControllerTests`.
@MainActor
final class KeyboardViewSmokeTests: XCTestCase {
    /// An iPhone 17's width, and the keyboard heights the input view controller pins.
    private static let portrait = CGSize(width: 390, height: 216)
    private static let landscape = CGSize(width: 844, height: 162)

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Doubles

    private final class SilentOpener: MurmurKeyboardCore.URLOpening {
        func open(_ url: URL) -> Bool { true }
    }

    // Qualified: SwiftUI has a `TextProxy` of its own, and this file imports both.
    private final class SilentProxy: MurmurKeyboardCore.TextProxy {
        var contextBefore: String?
        func insertText(_ s: String) {}
        func deleteBackward() {}
    }

    private func makeController(fullAccess: Bool = true) -> KeyboardController {
        KeyboardController(
            defaults: defaults,
            urlOpener: SilentOpener(),
            hasFullAccess: { fullAccess },
            clock: { self.t0 }
        )
    }

    /// One controller per ``KeyboardPhase`` case, driven there through the real API rather
    /// than by reaching into `phase`, which is `private(set)` for good reason.
    private func controllers(page: KeyboardPage) -> [(String, KeyboardController)] {
        let idle = makeController()

        let needsFullAccess = makeController(fullAccess: false)
        needsFullAccess.tapMic()

        let waiting = makeController()
        waiting.tapMic()

        let preview = makeController()
        Handoff.writeResult(
            DictationResult(
                session: Handoff.intentSession,
                raw: "so can you send me the deck before the meeting tomorrow",
                clean: "Can you send me the deck before the meeting tomorrow?",
                createdAt: t0,
                inserted: false
            ),
            defaults: defaults
        )
        preview.checkForResult()

        let inserted = makeController()
        Handoff.writeResult(
            DictationResult(
                session: Handoff.intentSession,
                raw: "on my way",
                clean: "On my way.",
                createdAt: t0,
                inserted: false
            ),
            defaults: defaults
        )
        inserted.checkForResult()
        inserted.insertPreview(proxy: SilentProxy())

        let all = [
            ("idle", idle),
            ("needsFullAccess", needsFullAccess),
            ("waiting", waiting),
            ("preview", preview),
            ("inserted", inserted),
        ]
        for (_, controller) in all { controller.state.page = page }
        return all
    }

    // MARK: - Tests

    func testLaysOutForEveryPageAndPhase() {
        for page in KeyboardPage.allCases {
            for (name, controller) in controllers(page: page) {
                for showsGlobe in [true, false] {
                    let size = layout(controller: controller, showsGlobe: showsGlobe, in: Self.portrait)
                    XCTAssertEqual(size, Self.portrait, "\(page)/\(name)/globe=\(showsGlobe)")
                }
            }
        }
    }

    /// Landscape is 54 pt shorter with the same four rows — the row that most easily collapses
    /// to a negative height.
    func testLaysOutInLandscape() {
        for page in KeyboardPage.allCases {
            for (name, controller) in controllers(page: page) {
                let size = layout(controller: controller, showsGlobe: true, in: Self.landscape)
                XCTAssertEqual(size, Self.landscape, "\(page)/\(name)")
            }
        }
    }

    /// Every phase actually renders. `UIHostingController` has no UIKit subviews to count —
    /// SwiftUI draws straight into one backing view — so this runs a real render pass, which
    /// is also the only thing that would trip over a bad symbol name or an empty strip branch.
    func testEveryPhaseRenders() {
        for (name, controller) in controllers(page: .letters) {
            let renderer = ImageRenderer(
                content: KeyboardView(controller: controller)
                    .frame(width: Self.portrait.width, height: Self.portrait.height)
            )
            renderer.scale = 1
            let image = renderer.uiImage
            XCTAssertNotNil(image, "\(name) rendered nothing")
            XCTAssertEqual(image?.size, Self.portrait, "\(name)")
        }
    }

    /// Shift and caps lock change the caps, which is the other thing that re-renders every key.
    func testLaysOutForEveryShiftState() {
        for shift in ShiftState.allCases {
            let controller = makeController()
            controller.state.shift = shift
            let size = layout(controller: controller, showsGlobe: true, in: Self.portrait)
            XCTAssertEqual(size, Self.portrait, "\(shift)")
        }
    }

    // MARK: - Hosting

    private func hosted(
        controller: KeyboardController,
        showsGlobe: Bool,
        in size: CGSize
    ) -> UIHostingController<KeyboardView> {
        let host = UIHostingController(
            rootView: KeyboardView(controller: controller, showsGlobe: showsGlobe)
        )
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host
    }

    private func layout(controller: KeyboardController, showsGlobe: Bool, in size: CGSize) -> CGSize {
        let host = hosted(controller: controller, showsGlobe: showsGlobe, in: size)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
        XCTAssertGreaterThan(host.view.bounds.width, 0)
        return host.view.bounds.size
    }
}
