import XCTest

import MurmurKeyboardCore
import MurmurShared

/// The keyboard half of the hand-off. `HandoffTests` proves the codec; this proves the
/// controller uses it the way guideline 4.4.1 and design spec §6.1 require: nothing opens
/// without Full Access, only Murmur and Settings are ever opened, and a result is typed once.
@MainActor
final class KeyboardControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var opener: FakeOpener!
    private var proxy: FakeProxy!

    /// Exactly representable as a Double, so the JSON round trip is bit-for-bit.
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        opener = FakeOpener()
        proxy = FakeProxy()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        opener = nil
        proxy = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Doubles

    private final class FakeOpener: URLOpening {
        private(set) var opened: [URL] = []
        var succeeds = true

        func open(_ url: URL) -> Bool {
            opened.append(url)
            return succeeds
        }
    }

    private final class FakeProxy: TextProxy {
        private(set) var inserted: [String] = []
        private(set) var deletes = 0
        var contextBefore: String?

        func insertText(_ s: String) {
            inserted.append(s)
            contextBefore = (contextBefore ?? "") + s
        }

        func deleteBackward() {
            deletes += 1
            if contextBefore?.isEmpty == false { contextBefore?.removeLast() }
        }

        var typed: String { inserted.joined() }
    }

    private func makeController(
        fullAccess: Bool = true,
        now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) },
        pollInterval: TimeInterval = 0.5,
        waitTimeout: TimeInterval = 60
    ) -> KeyboardController {
        KeyboardController(
            defaults: defaults,
            urlOpener: opener,
            hasFullAccess: { fullAccess },
            clock: now,
            pollInterval: pollInterval,
            waitTimeout: waitTimeout,
            // Yields instead of sleeping, so the poll loop runs at full speed.
            sleeper: { _ in await Task.yield() }
        )
    }

    private func result(_ session: UUID, at date: Date? = nil, clean: String = "Hello world.") -> DictationResult {
        DictationResult(
            session: session,
            raw: "um hello world",
            clean: clean,
            createdAt: date ?? t0,
            inserted: false
        )
    }

    // MARK: - Heartbeat

    func testViewWillAppearWritesTheFullAccessHeartbeat() {
        let controller = makeController(fullAccess: true)
        controller.viewWillAppear()

        XCTAssertEqual(defaults.bool(forKey: KeyboardStatus.fullAccessKey), true)
        XCTAssertEqual(defaults.object(forKey: KeyboardStatus.lastSeenKey) as? Date, t0)
    }

    func testViewWillAppearRecordsFullAccessOff() {
        let controller = makeController(fullAccess: false)
        controller.viewWillAppear()

        XCTAssertEqual(defaults.object(forKey: KeyboardStatus.fullAccessKey) as? Bool, false)
    }

    // MARK: - Mic

    func testMicWithoutFullAccessOpensNothing() {
        let controller = makeController(fullAccess: false)
        controller.tapMic()

        XCTAssertEqual(controller.phase, .needsFullAccess)
        XCTAssertEqual(opener.opened, [])
        XCTAssertNil(Handoff.readPending(now: t0, defaults: defaults))
    }

    func testMicWithFullAccessWritesPendingAndOpensMurmur() {
        let controller = makeController(fullAccess: true)
        controller.tapMic()

        guard case let .waiting(session, since) = controller.phase else {
            return XCTFail("expected .waiting, got \(controller.phase)")
        }
        XCTAssertEqual(since, t0)
        XCTAssertEqual(Handoff.readPending(now: t0, defaults: defaults)?.session, session)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["murmur://dictate?session=\(session.uuidString)"]
        )
    }

    func testSettingsIsTheOnlyOtherURLTheKeyboardOpens() {
        let controller = makeController(fullAccess: false)
        controller.tapMic()
        controller.openSettings()

        XCTAssertEqual(opener.opened.map(\.absoluteString), ["app-settings:"])
    }

    // MARK: - Picking the result up

    func testResultForThePendingSessionIsPickedUpAndTypedOnce() {
        let controller = makeController()
        controller.tapMic()
        guard case let .waiting(session, _) = controller.phase else {
            return XCTFail("expected .waiting")
        }

        Handoff.writeResult(result(session), defaults: defaults)
        controller.checkForResult()

        XCTAssertEqual(controller.phase, .preview(result(session)))
        XCTAssertEqual(controller.pendingInsert?.clean, "Hello world.")

        controller.insertPreview(proxy: proxy)
        XCTAssertEqual(proxy.typed, "Hello world.")
        XCTAssertEqual(controller.phase, .inserted)

        // Draining twice must not type it twice, and neither must a second poll.
        controller.insertPreview(proxy: proxy)
        controller.checkForResult()
        controller.insertPreview(proxy: proxy)
        XCTAssertEqual(proxy.inserted, ["Hello world."])
    }

    func testResultForAnotherSessionIsIgnored() {
        let controller = makeController()
        controller.tapMic()
        guard case .waiting = controller.phase else { return XCTFail("expected .waiting") }

        Handoff.writeResult(result(UUID()), defaults: defaults)
        controller.checkForResult()
        controller.insertPreview(proxy: proxy)

        guard case .waiting = controller.phase else {
            return XCTFail("expected to still be waiting, got \(controller.phase)")
        }
        XCTAssertEqual(proxy.inserted, [])
    }

    /// An Action Button / Control Center dictation carries no session of its own, so both sides
    /// agree on `Handoff.intentSession`. It is only claimed when nothing else is outstanding.
    func testIntentSessionResultIsPickedUpWhenNothingIsPending() {
        let controller = makeController()
        Handoff.writeResult(result(Handoff.intentSession, clean: "From the Action Button."), defaults: defaults)

        controller.viewWillAppear()
        controller.insertPreview(proxy: proxy)

        XCTAssertEqual(proxy.typed, "From the Action Button.")
    }

    func testAPendingKeyboardSessionOutranksAnIntentResult() {
        let controller = makeController()
        controller.tapMic()
        Handoff.writeResult(result(Handoff.intentSession), defaults: defaults)

        controller.checkForResult()

        guard case .waiting = controller.phase else {
            return XCTFail("expected to still be waiting, got \(controller.phase)")
        }
        XCTAssertEqual(proxy.inserted, [])
    }

    func testDiscardDropsTheResultWithoutTyping() {
        let controller = makeController()
        controller.tapMic()
        guard case let .waiting(session, _) = controller.phase else {
            return XCTFail("expected .waiting")
        }
        Handoff.writeResult(result(session), defaults: defaults)
        controller.checkForResult()

        controller.discardPreview()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.pendingInsert)
        controller.insertPreview(proxy: proxy)
        XCTAssertEqual(proxy.inserted, [])
    }

    // MARK: - Polling

    func testPollingPicksUpAResultWrittenWhileWaiting() async {
        let controller = makeController(pollInterval: 0.5, waitTimeout: 60)
        controller.tapMic()
        guard case let .waiting(session, _) = controller.phase else {
            return XCTFail("expected .waiting")
        }

        Handoff.writeResult(result(session), defaults: defaults)
        await settle(until: { controller.phase == .preview(self.result(session)) })

        XCTAssertEqual(controller.phase, .preview(result(session)))
    }

    func testPollingGivesUpAfterTheTimeout() async {
        let controller = makeController(pollInterval: 0.5, waitTimeout: 1)
        controller.tapMic()
        guard case .waiting = controller.phase else { return XCTFail("expected .waiting") }

        await settle(until: { controller.phase == .idle })

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(Handoff.readPending(now: t0, defaults: defaults))
    }

    /// The poll loop yields instead of sleeping, so handing it the main actor repeatedly is
    /// all it needs to run — no real time passes and nothing here waits on a wall clock.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Typing

    func testCharacterKeysTypeThroughTheProxy() {
        let controller = makeController()
        controller.tap(.char("h"), proxy: proxy)
        controller.tap(.char("i"), proxy: proxy)
        controller.tap(.space, proxy: proxy)
        controller.tap(.return, proxy: proxy)

        XCTAssertEqual(proxy.typed, "hi \n")
    }

    func testShiftUppercasesExactlyOneCharacter() {
        let controller = makeController()
        controller.tap(.shift, proxy: proxy)
        controller.tap(.char("h"), proxy: proxy)
        controller.tap(.char("i"), proxy: proxy)

        XCTAssertEqual(proxy.typed, "Hi")
        XCTAssertEqual(controller.state.shift, .off)
    }

    func testDeleteGoesStraightToTheProxy() {
        let controller = makeController()
        controller.tap(.char("a"), proxy: proxy)
        controller.tap(.delete, proxy: proxy)

        XCTAssertEqual(proxy.deletes, 1)
        XCTAssertEqual(proxy.inserted, ["a"])
    }

    func testPageKeysSwitchPages() {
        let controller = makeController()
        XCTAssertEqual(controller.state.page, .letters)
        controller.tap(.numbers, proxy: proxy)
        XCTAssertEqual(controller.state.page, .numbers)
        controller.tap(.symbols, proxy: proxy)
        XCTAssertEqual(controller.state.page, .symbols)
        controller.tap(.letters, proxy: proxy)
        XCTAssertEqual(controller.state.page, .letters)
        XCTAssertEqual(proxy.inserted, [])
    }

    /// The view controller owns these two — only it can advance the input mode, and it routes
    /// the mic cap to `tapMic()`.
    func testGlobeAndMicDoNothingThroughTap() {
        let controller = makeController()
        controller.tap(.globe, proxy: proxy)
        controller.tap(.mic, proxy: proxy)

        XCTAssertEqual(proxy.inserted, [])
        XCTAssertEqual(opener.opened, [])
        XCTAssertEqual(controller.phase, .idle)
    }
}
