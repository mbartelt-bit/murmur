//! Pure sample math shared by every front end. Capture itself (cpal on desktop,
//! AVAudioEngine on iOS, AudioRecord on Android) stays platform-side.

/// Root-mean-square level of a buffer — drives the VU meter.
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() { return 0.0; }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

/// Largest absolute sample in the buffer.
pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0_f32, |m, &s| m.max(s.abs()))
}

/// Average the two channels of an interleaved stereo buffer into mono.
pub fn stereo_to_mono(interleaved: &[f32]) -> Vec<f32> {
    interleaved.chunks_exact(2).map(|f| (f[0] + f[1]) * 0.5).collect()
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
