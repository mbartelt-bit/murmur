import MurmurShared
import SwiftUI

/// MM0 shell: proves the Swift app can reach the Rust core through UniFFI.
/// The real home screen (recorder, status chips, history) arrives in a later milestone.
struct HomeView: View {
    /// Indigo `#6366f1` — the same accent as the desktop settings window.
    static let accent = Color(red: 0.388, green: 0.4, blue: 0.945)

    @State private var cleaned: String?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Murmur")
                .font(.largeTitle.weight(.semibold))

            Text(CoreClient.groqKeyPage())
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                runCore()
            } label: {
                Text("Run core")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.accent)
            .disabled(isRunning)

            if let cleaned {
                Text("Cleaned: \(cleaned)")
                    .font(.body)
            }
        }
        .padding()
    }

    private func runCore() {
        isRunning = true
        Task {
            let result = await CoreClient.cleanLocally("um hello world")
            cleaned = result.clean
            isRunning = false
        }
    }
}

#Preview {
    HomeView()
}
