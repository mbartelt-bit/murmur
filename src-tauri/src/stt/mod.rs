use murmur_core::{stt::LocalWhisper, CloudConfig, CoreError};
use std::path::PathBuf;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

pub trait SttEngine {
    /// 16kHz mono f32 in; transcribed text out. `prompt` biases vocabulary.
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String>;
}

impl SttEngine for LocalWhisper {
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String> {
        LocalWhisper::transcribe(self, audio_16k_mono, prompt)
    }
}

/// Desktop adapter over `murmur_core::transcribe_cloud`. The pipeline worker is a
/// plain std thread, so blocking on the async core here is safe.
pub struct CloudStt {
    cfg: CloudConfig,
}

impl CloudStt {
    pub fn new(cfg: CloudConfig) -> Self {
        Self { cfg }
    }
}

impl SttEngine for CloudStt {
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String> {
        let call = murmur_core::transcribe_cloud(
            audio_16k_mono.to_vec(),
            self.cfg.clone(),
            prompt.to_owned(),
        );
        match tauri::async_runtime::block_on(call) {
            Ok(text) => Ok(text),
            // No audio means nothing was said, not a failure: the pipeline emits
            // `dictation-empty` for an empty transcript, as it always has.
            Err(CoreError::Empty) => Ok(String::new()),
            Err(e) => Err(anyhow::anyhow!(e.to_string())),
        }
    }
}

pub fn default_engine(model_path: PathBuf) -> Box<dyn SttEngine + Send + Sync> {
    Box::new(LocalWhisper::new(model_path))
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

    if let Some(provider) = murmur_core::Provider::from_id(choice) {
        let api_key = crate::secrets::get(provider.key_account())
            .ok()
            .flatten()
            .unwrap_or_default();
        Box::new(CloudStt::new(CloudConfig { provider, api_key }))
    } else {
        Box::new(LocalWhisper::new(crate::model::model_path(app)))
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
