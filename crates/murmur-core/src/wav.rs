/// Encode `samples` (f32 mono, any sample rate) into a canonical 44-byte-header WAV
/// (PCM 16-bit, 1 channel).  Each f32 is clamped to [-1.0, 1.0] then scaled to i16.
pub fn wav_from_f32_mono(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let num_samples = samples.len();
    let pcm_bytes = num_samples * 2; // 16-bit = 2 bytes per sample
    let byte_rate = sample_rate * 2; // channels=1, bits_per_sample=16 → sample_rate * 1 * 2
    let data_chunk_size = pcm_bytes as u32;
    let riff_chunk_size = 36 + data_chunk_size; // 4("WAVE") + 24(fmt) + 8(data hdr) + data

    let mut out = Vec::with_capacity(44 + pcm_bytes);

    // RIFF chunk descriptor
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&riff_chunk_size.to_le_bytes());
    out.extend_from_slice(b"WAVE");

    // fmt sub-chunk
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // sub-chunk size (16 for PCM)
    out.extend_from_slice(&1u16.to_le_bytes());  // AudioFormat: PCM = 1
    out.extend_from_slice(&1u16.to_le_bytes());  // NumChannels: 1
    out.extend_from_slice(&sample_rate.to_le_bytes()); // SampleRate
    out.extend_from_slice(&byte_rate.to_le_bytes());   // ByteRate
    out.extend_from_slice(&2u16.to_le_bytes());  // BlockAlign: 1 ch * 2 bytes
    out.extend_from_slice(&16u16.to_le_bytes()); // BitsPerSample

    // data sub-chunk header
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_chunk_size.to_le_bytes()); // bytes 40..44

    // PCM samples
    for &s in samples {
        let clamped = s.clamp(-1.0, 1.0);
        let pcm: i16 = (clamped * 32767.0) as i16;
        out.extend_from_slice(&pcm.to_le_bytes());
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn riff_wave_magic() {
        let wav = wav_from_f32_mono(&[0.0f32; 100], 16000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
    }

    #[test]
    fn total_length() {
        let samples = vec![0.0f32; 200];
        let wav = wav_from_f32_mono(&samples, 16000);
        assert_eq!(wav.len(), 44 + samples.len() * 2);
    }

    #[test]
    fn data_chunk_size_field() {
        let samples = vec![0.5f32; 300];
        let wav = wav_from_f32_mono(&samples, 16000);
        let data_size = u32::from_le_bytes(wav[40..44].try_into().unwrap());
        assert_eq!(data_size, (samples.len() * 2) as u32);
    }

    #[test]
    fn sample_rate_field() {
        let rate = 44100u32;
        let wav = wav_from_f32_mono(&[0.0f32; 10], rate);
        let stored_rate = u32::from_le_bytes(wav[24..28].try_into().unwrap());
        assert_eq!(stored_rate, rate);
    }

    #[test]
    fn sample_encoding() {
        // 1.0 → 32767 (0x7FFF)
        let wav = wav_from_f32_mono(&[1.0f32, 0.0f32, -1.0f32], 16000);
        let s0 = i16::from_le_bytes(wav[44..46].try_into().unwrap());
        let s1 = i16::from_le_bytes(wav[46..48].try_into().unwrap());
        let s2 = i16::from_le_bytes(wav[48..50].try_into().unwrap());
        assert_eq!(s0, 32767);
        assert_eq!(s1, 0);
        // -1.0 * 32767.0 cast to i16 is -32767
        assert_eq!(s2, -32767);
    }

    #[test]
    fn empty_samples() {
        let wav = wav_from_f32_mono(&[], 16000);
        assert_eq!(wav.len(), 44);
        let data_size = u32::from_le_bytes(wav[40..44].try_into().unwrap());
        assert_eq!(data_size, 0);
    }
}
