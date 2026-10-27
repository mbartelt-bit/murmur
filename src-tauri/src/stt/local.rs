use super::SttEngine;
use std::path::PathBuf;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

#[derive(Default)]
pub struct LocalCache(pub std::sync::Arc<std::sync::Mutex<Option<(PathBuf, WhisperContext)>>>);
impl LocalCache {
    pub fn clear(&self) {
        if let Ok(mut cached) = self.0.lock() {
            *cached = None;
        }
    }
}

pub struct LocalWhisper {
    model_path: PathBuf,
    cache: std::sync::Arc<std::sync::Mutex<Option<(PathBuf, WhisperContext)>>>,
}

impl LocalWhisper {
    pub fn new(model_path: PathBuf) -> Self {
        Self {
            model_path,
            cache: LocalCache::default().0,
        }
    }
    pub fn with_cache(model_path: PathBuf, cache: &LocalCache) -> Self {
        Self {
            model_path,
            cache: cache.0.clone(),
        }
    }
}

impl SttEngine for LocalWhisper {
    fn transcribe(&self, audio: &[f32], prompt: &str) -> anyhow::Result<String> {
        if audio.is_empty() {
            return Ok(String::new());
        }

        // Native debug logs can contain recognized words. Keep them out of logs.
        whisper_rs::install_logging_hooks();

        // NOTE: `use_gpu` is a builder method (returns &mut Self) in 0.16 —
        // honored only when the `metal` feature is enabled (_gpu is set).
        let mut cparams = WhisperContextParameters::default();
        cparams.use_gpu(cfg!(target_os = "macos"));

        // new_with_params takes &Path (not &str) in 0.16
        // The model is expensive to load. Reuse it, but keep each inference state
        // isolated and serialize access through the cache lock.
        let mut cached = self
            .cache
            .lock()
            .map_err(|_| anyhow::anyhow!("Local speech engine needs a restart"))?;
        if cached.as_ref().map(|(path, _)| path) != Some(&self.model_path) {
            *cached = Some((
                self.model_path.clone(),
                WhisperContext::new_with_params(&self.model_path, cparams)?,
            ));
        }
        let ctx = &cached.as_ref().expect("initialized context").1;
        let mut state = ctx.create_state()?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(4);
        params.set_language(Some("en"));
        if !prompt.is_empty() {
            params.set_initial_prompt(prompt);
        }
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);

        // state.full returns Result<(), WhisperError> in 0.16 (not Result<c_int,_>)
        state.full(params, audio)?;

        // full_n_segments() returns c_int directly (not Result) in 0.16
        let n = state.full_n_segments();

        // Segments are accessed via get_segment(i) -> Option<WhisperSegment> in 0.16;
        // full_get_segment_text(i) no longer exists as a direct method.
        let mut text = String::new();
        for i in 0..n {
            if let Some(seg) = state.get_segment(i) {
                text.push_str(seg.to_str()?);
            }
        }

        Ok(text.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "Requires MURMUR_TEST_MODEL and MURMUR_TEST_AUDIO (16kHz mono f32le JFK sample)"]
    fn transcribes_real_sample_locally() {
        let model = std::env::var_os("MURMUR_TEST_MODEL").expect("model path");
        let bytes =
            std::fs::read(std::env::var_os("MURMUR_TEST_AUDIO").expect("audio path")).unwrap();
        let audio: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect();
        let cache = LocalCache::default();
        let engine = LocalWhisper::with_cache(model.into(), &cache);
        for _ in 0..2 {
            let text = engine.transcribe(&audio, "").unwrap();
            assert!(
                text.to_lowercase().contains("ask not"),
                "Unexpected transcript: {text}"
            );
        }
        // Same lifetime path as app shutdown; prevents lingering Metal resources.
        cache.clear();
    }
}
