import XCTest

import MurmurShared
@testable import Murmur

/// The History list against a real (in-memory) SQLite database, so search and delete are
/// exercised through the same SQL the app runs.
@MainActor
final class HistoryViewModelTests: XCTestCase {
    private var history: HistoryStore!
    private var copied: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        history = try HistoryStore.inMemory()
        copied = []
    }

    override func tearDown() {
        history = nil
        super.tearDown()
    }

    private func makeViewModel() -> HistoryViewModel {
        HistoryViewModel(history: history, copy: { [weak self] in self?.copied.append($0) })
    }

    @discardableResult
    private func insert(raw: String, clean: String, source: TranscriptSource = .inApp) throws -> Transcript {
        try history.insert(Transcript(rawText: raw, cleanText: clean, source: source))
    }

    func testListIsNewestFirst() throws {
        try insert(raw: "one", clean: "One.")
        try insert(raw: "two", clean: "Two.")

        let viewModel = makeViewModel()
        viewModel.reload()

        XCTAssertEqual(viewModel.items.map(\.cleanText), ["Two.", "One."])
    }

    func testSearchFiltersOnCleanAndRawText() throws {
        try insert(raw: "um send the deck", clean: "Send the deck.")
        try insert(raw: "buy milk", clean: "Buy milk.")

        let viewModel = makeViewModel()

        viewModel.query = "milk"
        viewModel.reload()
        XCTAssertEqual(viewModel.items.map(\.cleanText), ["Buy milk."])

        // Raw text matches too, so a search for a filler word the cleanup removed still finds
        // the dictation it came from.
        viewModel.query = "um"
        viewModel.reload()
        XCTAssertEqual(viewModel.items.map(\.cleanText), ["Send the deck."])

        viewModel.query = "  "
        viewModel.reload()
        XCTAssertEqual(viewModel.items.count, 2)
    }

    func testDeleteRemovesTheRowAndReloads() throws {
        let doomed = try insert(raw: "one", clean: "One.")
        try insert(raw: "two", clean: "Two.")

        let viewModel = makeViewModel()
        viewModel.reload()
        XCTAssertEqual(viewModel.items.count, 2)

        viewModel.delete(doomed)

        XCTAssertEqual(viewModel.items.map(\.cleanText), ["Two."])
        XCTAssertEqual(try history.list().count, 1)
    }

    func testDeleteRespectsTheActiveSearch() throws {
        try insert(raw: "buy milk", clean: "Buy milk.")
        let doomed = try insert(raw: "send the deck", clean: "Send the deck.")

        let viewModel = makeViewModel()
        viewModel.query = "deck"
        viewModel.reload()
        XCTAssertEqual(viewModel.items.count, 1)

        viewModel.delete(doomed)

        // The reload after a delete keeps the query, rather than dumping the user back into
        // the full list.
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(try history.list().count, 1)
    }

    func testCopyPutsTheCleanTextOnThePasteboardAndMarksTheRow() throws {
        let row = try insert(raw: "um hello world", clean: "Hello world.")
        let viewModel = makeViewModel()
        viewModel.reload()

        viewModel.copy(row)

        XCTAssertEqual(copied, ["Hello world."])
        XCTAssertEqual(viewModel.copiedID, row.id)
    }
}
