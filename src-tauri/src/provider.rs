#[derive(Clone, Copy, PartialEq, Eq, Debug)]
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
}
