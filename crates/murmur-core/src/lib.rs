//! Murmur's provider-agnostic dictation pipeline.
//!
//! No Tauri, store or keychain dependency: callers pass configuration in and the
//! crate holds no state. The desktop app (`src-tauri`) drives it from a worker
//! thread with `block_on`; iOS and Android drive the same functions through the
//! UniFFI bindings generated from the `#[uniffi::export]`s below.

uniffi::setup_scaffolding!();

pub mod audio_math;
pub mod cleanup;
pub mod error;
pub mod provider;
pub mod resample;
pub mod stt;
pub mod verify;
pub mod wav;

pub use error::CoreError;
pub use provider::Provider;

use cleanup::{CloudCleanup, RuleCleanup};
use stt::CloudStt;

/// Everything a cloud call needs: which provider, and the caller's key. The key
/// comes from the Keychain (macOS/iOS) or EncryptedSharedPreferences (Android) —
/// the core never reads or stores it.
#[derive(uniffi::Record, Clone)]
pub struct CloudConfig {
    pub provider: Provider,
    pub api_key: String,
}

/// The outcome of a cleanup pass. `used_cloud` is false whenever the rules
/// engine produced the text, including every cloud failure.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CleanResult {
    pub raw: String,
    pub clean: String,
    pub used_cloud: bool,
}

/// Where the user creates an API key for `provider`.
#[uniffi::export]
pub fn key_page_url(provider: Provider) -> String {
    provider.key_page_url().to_owned()
}

/// Downmix (when the buffer is interleaved multi-channel) and resample to the
/// 16 kHz mono f32 every STT engine expects.
#[uniffi::export]
pub fn resample_to_16k(samples: Vec<f32>, in_rate: u32, channels: u16) -> Vec<f32> {
    let mono = if channels >= 2 {
        audio_math::stereo_to_mono(&samples)
    } else {
        samples
    };
    resample::resample_linear(&mono, in_rate, 16_000)
}

/// Transcribe with the provider's OpenAI-compatible `/audio/transcriptions`.
/// `Err(CoreError::Empty)` when there is no audio — nothing is sent.
#[uniffi::export(async_runtime = "tokio")]
pub async fn transcribe_cloud(
    audio_16k_mono: Vec<f32>,
    cfg: CloudConfig,
    prompt: String,
) -> Result<String, CoreError> {
    CloudStt::new(&cfg)
        .transcribe(&audio_16k_mono, &prompt)
        .await
}

/// Clean a transcript. Never fails: a missing, unreachable or unhappy cloud
/// falls back to the rules engine, so dictated words are never lost.
#[uniffi::export(async_runtime = "tokio")]
pub async fn clean_text(raw: String, cloud: Option<CloudConfig>) -> CleanResult {
    clean_text_at(raw, cloud, None).await
}

/// `clean_text` with the cloud endpoint overridable, so tests can aim it at a
/// dead port instead of the real provider.
async fn clean_text_at(
    raw: String,
    cloud: Option<CloudConfig>,
    base_url: Option<&str>,
) -> CleanResult {
    if let Some(cfg) = cloud {
        if !raw.trim().is_empty() {
            let engine = match base_url {
                Some(b) => CloudCleanup::with_base_url(&cfg, b),
                None => CloudCleanup::new(&cfg),
            };
            if let Ok(clean) = engine.clean(&raw).await {
                if !clean.is_empty() {
                    return CleanResult { raw, clean, used_cloud: true };
                }
            }
        }
    }
    let clean = RuleCleanup.clean(&raw);
    CleanResult { raw, clean, used_cloud: false }
}

/// Ping the provider's `/models` endpoint with the caller's key.
#[uniffi::export(async_runtime = "tokio")]
pub async fn verify_provider(cfg: CloudConfig) -> Result<(), CoreError> {
    let base_url = cfg.provider.base_url();
    verify::verify_at(&cfg, base_url).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn groq(key: &str) -> CloudConfig {
        CloudConfig { provider: Provider::Groq, api_key: key.to_owned() }
    }

    /// A port nothing listens on: connections are refused immediately.
    const DEAD: &str = "http://127.0.0.1:9";

    #[test]
    fn key_page_urls_are_the_provider_consoles() {
        assert_eq!(key_page_url(Provider::Groq), "https://console.groq.com/keys");
        assert_eq!(key_page_url(Provider::OpenAI), "https://platform.openai.com/api-keys");
    }

    #[test]
    fn resample_to_16k_downmixes_stereo_then_resamples() {
        // 4 interleaved stereo samples (2 frames) at 32 kHz → 1 mono sample at 16 kHz.
        let out = resample_to_16k(vec![1.0, 0.0, 0.0, 1.0], 32_000, 2);
        assert_eq!(out, vec![0.5]);
    }

    #[test]
    fn resample_to_16k_leaves_mono_at_rate_alone() {
        let out = resample_to_16k(vec![0.1, 0.2, 0.3], 16_000, 1);
        assert_eq!(out, vec![0.1, 0.2, 0.3]);
    }

    #[tokio::test]
    async fn clean_text_without_cloud_uses_rules() {
        assert_eq!(
            clean_text("um hello world".to_owned(), None).await,
            CleanResult {
                raw: "um hello world".to_owned(),
                clean: "Hello world.".to_owned(),
                used_cloud: false,
            }
        );
    }

    #[tokio::test]
    async fn clean_text_falls_back_when_cloud_unreachable() {
        let r = clean_text_at("um hello world".to_owned(), Some(groq("x")), Some(DEAD)).await;
        assert!(!r.used_cloud);
        assert_eq!(r.clean, RuleCleanup.clean("um hello world"));
    }

    #[tokio::test]
    async fn transcribe_cloud_empty_is_error() {
        let err = transcribe_cloud(vec![], groq("x"), String::new()).await.unwrap_err();
        assert!(matches!(err, CoreError::Empty));
    }

    #[tokio::test]
    async fn verify_maps_401_to_rejected() {
        // One-shot HTTP responder on an ephemeral port — no mock crate needed.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            if let Ok((mut sock, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = sock.read(&mut buf);
                let _ = sock.write_all(
                    b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                );
                let _ = sock.flush();
            }
        });

        let err = verify::verify_at(&groq("bad-key"), &base).await.unwrap_err();
        server.join().unwrap();
        assert!(matches!(err, CoreError::Rejected));
        assert_eq!(err.to_string(), "That key was rejected — double-check it and try again.");
    }

    #[tokio::test]
    async fn verify_unreachable_is_network_error() {
        let err = verify::verify_at(&groq("x"), DEAD).await.unwrap_err();
        assert!(matches!(err, CoreError::Network { ref provider } if provider == "groq"));
    }
}
