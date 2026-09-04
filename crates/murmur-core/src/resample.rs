/// Linear-interpolation resampler (mono f32). Adequate for speech → Whisper.
pub fn resample_linear(input: &[f32], in_rate: u32, out_rate: u32) -> Vec<f32> {
    if input.is_empty() || in_rate == out_rate {
        return input.to_vec();
    }
    let ratio = in_rate as f64 / out_rate as f64;
    let out_len = ((input.len() as f64) / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let i0 = src.floor() as usize;
        let i1 = (i0 + 1).min(input.len() - 1);
        let frac = (src - i0 as f64) as f32;
        out.push(input[i0] * (1.0 - frac) + input[i1] * frac);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passthrough_when_rates_match() {
        let v = vec![0.1, 0.2, 0.3];
        assert_eq!(resample_linear(&v, 16000, 16000), v);
    }
    #[test]
    fn downsample_48k_to_16k_thirds_length() {
        let input = vec![0.0_f32; 4800]; // 0.1s @ 48k
        let out = resample_linear(&input, 48000, 16000);
        assert!((out.len() as i32 - 1600).abs() <= 1); // ~0.1s @ 16k
    }
    #[test]
    fn empty_input_yields_empty() {
        assert!(resample_linear(&[], 48000, 16000).is_empty());
    }
}
