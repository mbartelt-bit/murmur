/// The one error type every front end sees. The `Display` strings are the exact
/// user-facing messages the desktop app has shown since M2 (`src-tauri/src/engines.rs`),
/// so macOS, iOS and Android all say the same thing.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("Couldn't reach {provider} — check your connection.")]
    Network { provider: String },
    #[error("That key was rejected — double-check it and try again.")]
    Rejected,
    #[error("Couldn't verify the key (HTTP {status}).")]
    Http { status: u16 },
    #[error("Nothing to transcribe.")]
    Empty,
}

impl CoreError {
    /// Map an HTTP status onto the shared vocabulary. `None` for 2xx.
    pub(crate) fn from_status(status: u16) -> Option<Self> {
        match status {
            200..=299 => None,
            401 | 403 => Some(Self::Rejected),
            s => Some(Self::Http { status: s }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_match_the_desktop_strings() {
        assert_eq!(
            CoreError::Network { provider: "groq".into() }.to_string(),
            "Couldn't reach groq — check your connection."
        );
        assert_eq!(
            CoreError::Rejected.to_string(),
            "That key was rejected — double-check it and try again."
        );
        assert_eq!(
            CoreError::Http { status: 500 }.to_string(),
            "Couldn't verify the key (HTTP 500)."
        );
    }

    #[test]
    fn status_mapping() {
        assert!(CoreError::from_status(200).is_none());
        assert!(matches!(CoreError::from_status(401), Some(CoreError::Rejected)));
        assert!(matches!(CoreError::from_status(403), Some(CoreError::Rejected)));
        assert!(matches!(CoreError::from_status(500), Some(CoreError::Http { status: 500 })));
    }
}
