mod cloud;
mod local;
use std::path::PathBuf;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

pub use cloud::CloudStt;

pub trait SttEngine {
    /// 16kHz mono f32 in; transcribed text out. `prompt` biases vocabulary.
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String>;
}

pub fn default_engine(model_path: PathBuf) -> Box<dyn SttEngine + Send + Sync> {
    Box::new(local::LocalWhisper::new(model_path))
}

/// Resolve the stored "stt_engine" setting to a canonical choice string.
/// Returns "openai", "groq", or "local" (default for any unrecognised/absent value).
pub(crate) fn stt_choice(stored: Option<&str>) -> &'static str {
    match stored {
        Some("openai") => "openai",
        Some("groq") => "groq",
        _ => "local",
    }
}

/// Build the STT engine the user has selected (reads store + Keychain).
/// Falls through to local if the store is absent or holds an unknown value.
pub fn make_engine(app: &AppHandle) -> Box<dyn SttEngine + Send + Sync> {
    let stored = app
        .store("settings.json")
        .ok()
        .and_then(|s| s.get("stt_engine"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()));

    let choice = stt_choice(stored.as_deref());

    if let Some(provider) = crate::provider::Provider::from_id(choice) {
        let key = crate::secrets::get(provider.key_account())
            .ok()
            .flatten()
            .unwrap_or_default();
        Box::new(cloud::CloudStt::new(provider.base_url(), provider.stt_model(), key))
    } else {
        Box::new(local::LocalWhisper::new(crate::model::model_path(app)))
    }
}

#[cfg(test)]
mod tests {
    use super::stt_choice;

    #[test]
    fn choice_openai() {
        assert_eq!(stt_choice(Some("openai")), "openai");
    }

    #[test]
    fn choice_groq() {
        assert_eq!(stt_choice(Some("groq")), "groq");
    }

    #[test]
    fn choice_local_explicit() {
        assert_eq!(stt_choice(Some("local")), "local");
    }

    #[test]
    fn choice_missing_defaults_local() {
        assert_eq!(stt_choice(None), "local");
    }

    #[test]
    fn choice_garbage_defaults_local() {
        assert_eq!(stt_choice(Some("gpt99")), "local");
    }
}
