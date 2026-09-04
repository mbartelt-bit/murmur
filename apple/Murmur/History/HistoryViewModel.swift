import Foundation
import MurmurShared
import UIKit

/// The History screen's list, search and row actions.
///
/// Reads are synchronous on purpose: SQLite on the local file system answers a fifty-row query
/// in microseconds, and the alternative — an async reload per keystroke — buys nothing but a
/// chance for results to arrive out of order.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = ""
    @Published var items: [Transcript] = []
    /// The row whose "Copied" check is showing, if any.
    @Published var copiedID: Int64?

    /// How many rows the screen keeps in memory. Search runs in SQLite, so this is a display
    /// cap, not a search cap.
    static let pageSize = 200

    private let history: HistoryStore
    private let pasteboard: (String) -> Void
    private var copyResetTask: Task<Void, Never>?

    init(
        history: HistoryStore,
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) {
        self.history = history
        pasteboard = copy
    }

    /// Re-reads the list for the current ``query``. A database failure leaves the previous
    /// rows on screen rather than blanking the list under the user.
    func reload() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rows = try? history.list(limit: Self.pageSize, matching: trimmed.isEmpty ? nil : trimmed) else { return }
        items = rows
    }

    func delete(_ transcript: Transcript) {
        guard let id = transcript.id else { return }
        try? history.delete(id: id)
        reload()
    }

    /// Copies the cleaned text and shows a check on that row for a moment. The raw text is
    /// never what gets copied — the cleaned line is what the user asked Murmur for.
    func copy(_ transcript: Transcript) {
        pasteboard(transcript.cleanText)
        copiedID = transcript.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.copiedID == transcript.id else { return }
                self.copiedID = nil
            }
        }
    }
}
