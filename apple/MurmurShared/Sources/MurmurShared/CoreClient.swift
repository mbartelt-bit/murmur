import MurmurCore

/// The app's only door into the Rust core.
///
/// Everything below is a one-line pass-through to a `#[uniffi::export]` function in
/// `crates/murmur-core`; the indirection exists so views and view models never import
/// the generated bindings directly and so the FFI can be exercised from unit tests.
public enum CoreClient {
    /// Where a user goes to mint a Groq API key.
    public static func groqKeyPage() -> String {
        keyPageUrl(provider: .groq)
    }

    /// Rules-only cleanup: no network, no key, and it never fails.
    public static func cleanLocally(_ raw: String) async -> CleanResult {
        await cleanText(raw: raw, cloud: nil)
    }
}
