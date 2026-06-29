use super::SttEngine;

#[derive(serde::Deserialize)]
struct TranscriptionResponse {
    text: String,
}

pub struct CloudStt {
    base_url: String,
    model: String,
    api_key: String,
}

impl CloudStt {
    pub fn new(
        base_url: impl Into<String>,
        model: impl Into<String>,
        api_key: impl Into<String>,
    ) -> Self {
        Self {
            base_url: base_url.into(),
            model: model.into(),
            api_key: api_key.into(),
        }
    }
}

impl SttEngine for CloudStt {
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String> {
        if audio_16k_mono.is_empty() {
            return Ok(String::new());
        }

        let wav_bytes = crate::wav::wav_from_f32_mono(audio_16k_mono, 16000);

        let file_part = reqwest::blocking::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;

        let mut form = reqwest::blocking::multipart::Form::new()
            .part("file", file_part)
            .text("model", self.model.clone())
            .text("response_format", "json");

        if !prompt.is_empty() {
            form = form.text("prompt", prompt.to_string());
        }

        let url = format!("{}/audio/transcriptions", self.base_url);
        let client = reqwest::blocking::Client::new();
        let response = client
            .post(&url)
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            anyhow::bail!("STT request failed with status {}: {}", status, body);
        }

        let parsed: TranscriptionResponse = response.json()?;
        Ok(parsed.text.trim().to_string())
    }
}
