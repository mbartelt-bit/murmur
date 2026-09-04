import XCTest

import MurmurShared
@testable import Murmur

/// `murmur://dictate` is written by machines — the MM2 keyboard, the Action Button intent —
/// and typed by Matt during device QA. These tests pin down exactly which of those URLs open
/// the recorder, which session ids survive the trip, and that everything else is dropped in
/// silence rather than putting an error on screen.
final class AppStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var state: AppState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let secrets = InMemorySecretStore()
        let history = try HistoryStore.inMemory()
        state = AppState(
            settings: settings,
            secrets: secrets,
            history: history,
            pipeline: DictationPipeline(settings: settings, secrets: secrets, history: history)
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        state = nil
        try super.tearDownWithError()
    }

    private func open(_ string: String) {
        state.handle(URL(string: string)!)
    }

    // MARK: - Valid

    func testASessionUrlOpensAKeyboardDictation() {
        let session = UUID(uuidString: "00000000-0000-4000-8000-000000000123")!
        open("murmur://dictate?session=\(session.uuidString)")

        XCTAssertEqual(state.activeDictation?.session, session)
        XCTAssertEqual(state.activeDictation?.source, .keyboard)
    }

    func testALowercaseSessionIdIsStillAUuid() {
        let session = UUID(uuidString: "00000000-0000-4000-8000-000000000123")!
        open("murmur://dictate?session=00000000-0000-4000-8000-000000000123")
        XCTAssertEqual(state.activeDictation?.session, session)
    }

    func testAUrlWithNoSessionOpensAnInAppDictation() {
        open("murmur://dictate")

        XCTAssertNotNil(state.activeDictation)
        XCTAssertNil(state.activeDictation?.session)
        XCTAssertEqual(state.activeDictation?.source, .inApp)
    }

    func testAnEmptyQueryIsStillAnInAppDictation() {
        open("murmur://dictate?")
        XCTAssertEqual(state.activeDictation?.source, .inApp)
        XCTAssertNil(state.activeDictation?.session)
    }

    func testTheSchemeAndHostAreCaseInsensitive() {
        open("MURMUR://DICTATE")
        XCTAssertEqual(state.activeDictation?.source, .inApp)
    }

    func testThePathFormIsAccepted() {
        // Some launchers hand over `murmur:dictate` with no authority component.
        open("murmur:dictate")
        XCTAssertEqual(state.activeDictation?.source, .inApp)
    }

    // MARK: - Ignored

    func testAnotherSchemeIsIgnored() {
        open("https://murmur.app/dictate?session=\(UUID().uuidString)")
        XCTAssertNil(state.activeDictation)
    }

    func testAnotherHostIsIgnored() {
        open("murmur://settings")
        XCTAssertNil(state.activeDictation)
    }

    func testAGarbageSessionIsIgnored() {
        open("murmur://dictate?session=not-a-uuid")
        XCTAssertNil(state.activeDictation, "a keyboard waiting on a broken id gets nothing back")
    }

    func testAnEmptySessionValueIsIgnored() {
        open("murmur://dictate?session=")
        XCTAssertNil(state.activeDictation)
    }

    func testAnIgnoredUrlLeavesAnActiveDictationAlone() {
        open("murmur://dictate")
        let first = state.activeDictation
        open("murmur://dictate?session=nonsense")
        XCTAssertEqual(state.activeDictation, first)
    }

    // MARK: - Replacement

    func testASecondUrlReplacesTheActiveDictation() {
        let first = UUID()
        let second = UUID()
        open("murmur://dictate?session=\(first.uuidString)")
        let before = state.activeDictation
        open("murmur://dictate?session=\(second.uuidString)")

        XCTAssertEqual(state.activeDictation?.session, second)
        // A new identity, so SwiftUI tears the old recorder down instead of reusing it.
        XCTAssertNotEqual(state.activeDictation?.id, before?.id)
    }

    // MARK: - In-app

    func testStartInAppDictationNeedsNoSession() {
        state.startInAppDictation()
        XCTAssertNil(state.activeDictation?.session)
        XCTAssertEqual(state.activeDictation?.source, .inApp)
    }
}
