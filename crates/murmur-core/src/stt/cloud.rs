use crate::{wav, CloudConfig, CoreError, Provider};
use std::time::Duration;
use zeroize::Zeroizing;

/// Matches the blocking client's default that the desktop app relied on before
/// this code became async.
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(serde::Deserialize)]
struct TranscriptionResponse {
    text: String,
}

/// OpenAI-compatible `/audio/transcriptions` client (OpenAI and Groq both speak it).
pub struct CloudStt {
    provider: Provider,
    base_url: String,
    model: String,
    api_key: Zeroizing<String>,
}

impl CloudStt {
    pub fn new(cfg: &CloudConfig) -> Self {
        Self::with_base_url(cfg, cfg.provider.base_url())
    }

    /// Same as `new`, with the endpoint overridden (tests point this at a local socket).
    pub fn with_base_url(cfg: &CloudConfig, base_url: &str) -> Self {
        Self {
            provider: cfg.provider,
            base_url: base_url.to_owned(),
            model: cfg.provider.stt_model().to_owned(),
            api_key: Zeroizing::new(cfg.api_key.clone()),
        }
    }

    /// 16 kHz mono f32 in, transcript out. `prompt` biases vocabulary.
    pub async fn transcribe(
        &self,
        audio_16k_mono: &[f32],
        prompt: &str,
    ) -> Result<String, CoreError> {
        if audio_16k_mono.is_empty() {
            return Err(CoreError::Empty);
        }

        let unreachable = || CoreError::Network { provider: self.provider.id().to_owned() };

        let wav_bytes = wav::wav_from_f32_mono(audio_16k_mono, 16000);
        let file_part = reqwest::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|_| unreachable())?;

        let mut form = reqwest::multipart::Form::new()
            .part("file", file_part)
            .text("model", self.model.clone())
            .text("response_format", "json");

        if !prompt.is_empty() {
            form = form.text("prompt", prompt.to_string());
        }

        let client = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .build()
            .map_err(|_| unreachable())?;

        let response = client
            .post(format!("{}/audio/transcriptions", self.base_url))
            .bearer_auth(self.api_key.as_str())
            .multipart(form)
            .send()
            .await
            .map_err(|_| unreachable())?;

        if let Some(e) = CoreError::from_status(response.status().as_u16()) {
            return Err(e);
        }

        let parsed: TranscriptionResponse = response.json().await.map_err(|_| unreachable())?;
        Ok(parsed.text.trim().to_string())
    }
}
