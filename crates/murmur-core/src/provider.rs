#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Provider {
    OpenAI,
    Groq,
}

impl Provider {
    pub fn from_id(s: &str) -> Option<Provider> {
        match s {
            "openai" => Some(Self::OpenAI),
            "groq" => Some(Self::Groq),
            _ => None,
        }
    }

    pub fn base_url(&self) -> &'static str {
        match self {
            Self::OpenAI => "https://api.openai.com/v1",
            Self::Groq => "https://api.groq.com/openai/v1",
        }
    }

    pub fn stt_model(&self) -> &'static str {
        match self {
            Self::OpenAI => "whisper-1",
            Self::Groq => "whisper-large-v3",
        }
    }

    pub fn chat_model(&self) -> &'static str {
        match self {
            Self::OpenAI => "gpt-4o-mini",
            Self::Groq => "llama-3.3-70b-versatile",
        }
    }

    /// Keychain account name for this provider's API key.
    pub fn key_account(&self) -> &'static str {
        match self {
            Self::OpenAI => "openai_api_key",
            Self::Groq => "groq_api_key",
        }
    }

    /// The id used in settings, IPC and user-facing error messages.
    pub fn id(&self) -> &'static str {
        match self {
            Self::OpenAI => "openai",
            Self::Groq => "groq",
        }
    }

    /// Where the user creates an API key. Mirrors `PROVIDER_INFO` in
    /// `src/components/EngineSettings.tsx`.
    pub fn key_page_url(&self) -> &'static str {
        match self {
            Self::OpenAI => "https://platform.openai.com/api-keys",
            Self::Groq => "https://console.groq.com/keys",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_round_trip() {
        assert_eq!(Provider::from_id(Provider::OpenAI.id()), Some(Provider::OpenAI));
        assert_eq!(Provider::from_id(Provider::Groq.id()), Some(Provider::Groq));
        assert_eq!(Provider::from_id("nope"), None);
    }

    #[test]
    fn key_pages_match_the_ui() {
        assert_eq!(Provider::Groq.key_page_url(), "https://console.groq.com/keys");
        assert_eq!(Provider::OpenAI.key_page_url(), "https://platform.openai.com/api-keys");
    }
}
