use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use std::sync::{Arc, Mutex};

pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() { return 0.0; }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0_f32, |m, &s| m.max(s.abs()))
}

pub fn stereo_to_mono(interleaved: &[f32]) -> Vec<f32> {
    interleaved.chunks_exact(2).map(|f| (f[0] + f[1]) * 0.5).collect()
}

pub struct Capture {
    stream: cpal::Stream,
    buffer: Arc<Mutex<Vec<f32>>>,
    pub level: Arc<Mutex<f32>>,
    pub sample_rate: u32,
    pub channels: u16,
}

pub fn start_capture() -> anyhow::Result<Capture> {
    let host = cpal::default_host();
    let device = host.default_input_device()
        .ok_or_else(|| anyhow::anyhow!("no default input device"))?;
    let supported = device.default_input_config()?;
    let sample_rate = supported.sample_rate();
    let channels = supported.channels();
    let fmt = supported.sample_format();
    let config: StreamConfig = supported.into();

    let buffer = Arc::new(Mutex::new(Vec::<f32>::new()));
    let level = Arc::new(Mutex::new(0.0_f32));
    let (buf_cb, lvl_cb) = (buffer.clone(), level.clone());
    let err_fn = |e| eprintln!("cpal error: {e}");

    let stream = match fmt {
        SampleFormat::F32 => device.build_input_stream(
            config.clone(),
            move |data: &[f32], _: &_| {
                if let Ok(mut l) = lvl_cb.lock() { *l = rms(data); }
                if let Ok(mut b) = buf_cb.lock() { b.extend_from_slice(data); }
            }, err_fn, None)?,
        SampleFormat::I16 => device.build_input_stream(
            config.clone(),
            move |data: &[i16], _: &_| {
                let f: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                if let Ok(mut l) = lvl_cb.lock() { *l = rms(&f); }
                if let Ok(mut b) = buf_cb.lock() { b.extend_from_slice(&f); }
            }, err_fn, None)?,
        other => anyhow::bail!("unsupported sample format: {other:?}"),
    };
    stream.play()?;
    Ok(Capture { stream, buffer, level, sample_rate, channels })
}

impl Capture {
    /// Stop capture and return accumulated interleaved samples.
    pub fn stop(self) -> Vec<f32> {
        let _ = self.stream.pause();
        let out = self.buffer.lock().map(|b| b.clone()).unwrap_or_default();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rms_of_silence_is_zero() { assert_eq!(rms(&[0.0; 16]), 0.0); }
    #[test]
    fn rms_of_constant_is_magnitude() {
        let v = vec![0.5_f32; 100];
        assert!((rms(&v) - 0.5).abs() < 1e-6);
    }
    #[test]
    fn peak_returns_max_abs() { assert!((peak(&[0.1, -0.9, 0.3]) - 0.9).abs() < 1e-6); }
    #[test]
    fn stereo_downmix_averages_frames() {
        assert_eq!(stereo_to_mono(&[1.0, 0.0, 0.0, 1.0]), vec![0.5, 0.5]);
    }
}
