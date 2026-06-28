mod local;
use std::path::PathBuf;

pub trait SttEngine {
    /// 16kHz mono f32 in; transcribed text out. `prompt` biases vocabulary.
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String>;
}

pub fn default_engine(model_path: PathBuf) -> Box<dyn SttEngine + Send + Sync> {
    Box::new(local::LocalWhisper::new(model_path))
}
