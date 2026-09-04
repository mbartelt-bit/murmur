import MurmurShared
import SwiftUI

/// Every dictation Murmur has made on this phone, newest first.
///
/// Tap copies — that is the action people actually want from a list of things they said, and
/// it is one gesture rather than a row of icon buttons squeezed onto a phone. Delete is the
/// standard swipe, and the raw transcript is one context-menu tap away for anyone who wants to
/// see what the cleanup pass changed.
struct HistoryView: View {
    let historyUnavailable: Bool

    @StateObject private var viewModel: HistoryViewModel
    @State private var showingRawID: Int64?

    init(app: AppState) {
        historyUnavailable = app.historyUnavailable
        _viewModel = StateObject(wrappedValue: HistoryViewModel(history: app.history))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty {
                    ContentUnavailableView(
                        viewModel.query.isEmpty ? Copy.historyEmpty : Copy.historyNoMatches,
                        systemImage: "waveform"
                    )
                } else {
                    list
                }
            }
            .navigationTitle(Copy.historyTab)
            .searchable(text: $viewModel.query, prompt: Copy.searchPlaceholder)
        }
        .onAppear { viewModel.reload() }
        .onChange(of: viewModel.query) { _, _ in viewModel.reload() }
    }

    private var list: some View {
        List {
            if historyUnavailable {
                Text(Copy.historyUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.items) { transcript in
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptRow(transcript: transcript, copied: viewModel.copiedID == transcript.id)

                    if showingRawID == transcript.id {
                        Text(transcript.rawText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { viewModel.copy(transcript) }
                .contextMenu {
                    Button(showingRawID == transcript.id ? Copy.hideRaw : Copy.showRaw, systemImage: "text.alignleft") {
                        showingRawID = showingRawID == transcript.id ? nil : transcript.id
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(Copy.delete, systemImage: "trash", role: .destructive) {
                        viewModel.delete(transcript)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
