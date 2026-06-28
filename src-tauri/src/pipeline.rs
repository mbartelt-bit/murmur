use crate::{
    audio,
    cleanup,
    hotkey::{self, PttSink},
    insert,
    model,
    resample,
    stt,
    windows,
};
use serde::Serialize;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

#[derive(Serialize, Clone)]
pub struct DictationResult {
    pub raw: String,
    pub clean: String,
    pub app: Option<String>,
}

/// Pure helper: decide whether a result is insertable (non-empty clean text).
pub fn is_insertable(r: &DictationResult) -> bool {
    !r.clean.trim().is_empty()
}

/// A live recording session.
///
/// `Session` is `Send` (it only owns channel endpoints — NOT the cpal `Stream`,
/// which stays parked on the dedicated audio thread). That keeps
/// `Mutex<Option<Session>>`, and therefore `Pipeline`, `Send + Sync`.
struct Session {
    /// Signals the audio thread to finish capturing and return its samples.
    stop_tx: mpsc::Sender<()>,
    /// Receives `(interleaved_samples, sample_rate, channels)` once capture ends.
    samples_rx: mpsc::Receiver<(Vec<f32>, u32, u16)>,
}

pub struct Pipeline {
    /// `None` = idle, `Some` = recording.
    session: Mutex<Option<Session>>,
}

impl Pipeline {
    fn new() -> Self {
        Self {
            session: Mutex::new(None),
        }
    }
}

impl PttSink for Pipeline {
    fn start(&self, app: &AppHandle) {
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (samp_tx, samp_rx) = mpsc::channel::<(Vec<f32>, u32, u16)>();
        let app = app.clone();
        let audio_app = app.clone();

        // Dedicated audio thread. The cpal Stream (`!Send` on macOS) is created,
        // lives, and is dropped entirely on THIS thread — it never crosses a
        // thread boundary.
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        std::thread::spawn(move || {
            let cap = match audio::start_capture() {
                Ok(c) => c,
                Err(e) => {
                    let _ = ready_tx.send(Err(e.to_string()));
                    return;
                }
            };
            let sr = cap.sample_rate;
            let ch = cap.channels;
            let level = cap.level.clone();
            // Signal the start() caller that capture is live.
            let _ = ready_tx.send(Ok(()));

            // Emit level meter until told to stop.
            loop {
                if stop_rx.try_recv().is_ok() {
                    break;
                }
                let l = *level.lock().unwrap();
                let _ = audio_app.emit("vu-level", l as f64);
                std::thread::sleep(std::time::Duration::from_millis(60));
            }

            // Consume the Stream locally and ship the raw samples out.
            let interleaved = cap.stop();
            let _ = samp_tx.send((interleaved, sr, ch));
        });

        // Wait for the audio thread to confirm capture started (or failed).
        match ready_rx.recv() {
            Ok(Ok(())) => {
                windows::show_hud(&app);
                *self.session.lock().unwrap() = Some(Session {
                    stop_tx,
                    samples_rx: samp_rx,
                });
            }
            Ok(Err(e)) => {
                let _ = app.emit("dictation-error", e);
            }
            Err(_) => {
                let _ = app.emit("dictation-error", "audio thread terminated unexpectedly".to_string());
            }
        }
    }

    fn stop(&self, app: &AppHandle) {
        let session = self.session.lock().unwrap().take();
        let Some(session) = session else {
            return;
        };
        // Tell the audio thread to finish and hand back its samples.
        let _ = session.stop_tx.send(());
        let samples_rx = session.samples_rx;
        let app = app.clone();

        // Heavy work (transcribe/cleanup/insert) runs OFF the hotkey event thread.
        std::thread::spawn(move || {
            let (interleaved, sr, ch) = match samples_rx.recv() {
                Ok(v) => v,
                Err(_) => {
                    let _ = app.emit("dictation-error", "audio capture produced no samples".to_string());
                    let _ = app.emit("hud-state", "idle");
                    windows::hide_hud(&app);
                    return;
                }
            };

            let _ = app.emit("hud-state", "transcribing");

            let mono = if ch >= 2 {
                audio::stereo_to_mono(&interleaved)
            } else {
                interleaved
            };
            let audio16k = resample::resample_linear(&mono, sr, 16000);

            let engine = stt::default_engine(model::model_path(&app));
            let raw = match engine.transcribe(&audio16k, "") {
                Ok(t) => t,
                Err(e) => {
                    let _ = app.emit("dictation-error", e.to_string());
                    let _ = app.emit("hud-state", "idle");
                    windows::hide_hud(&app);
                    return;
                }
            };

            let clean = cleanup::default_cleanup().clean(&raw);
            let result = DictationResult {
                raw,
                clean: clean.clone(),
                app: None,
            };

            // Always surface/persist the result, even when nothing is inserted.
            let _ = app.emit("dictation-complete", result.clone());

            if is_insertable(&result) {
                if let Err(e) = insert::insert_text(&clean) {
                    let _ = app.emit("dictation-error", e);
                }
            } else {
                let _ = app.emit("dictation-empty", ());
            }

            let _ = app.emit("hud-state", "idle");
            windows::hide_hud(&app);
        });
    }
}

pub fn init(app: &AppHandle) {
    let pipeline: Arc<dyn PttSink> = Arc::new(Pipeline::new());
    if let Err(e) = hotkey::register(app, pipeline) {
        eprintln!("hotkey registration failed: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Compile-time proof that the !Send cpal Stream never lives inside Pipeline:
    // Pipeline is required to be Send + Sync (it's shared as Arc<dyn PttSink>).
    const _: fn() = || {
        fn assert_send_sync<T: Send + Sync>() {}
        fn assert_send<T: Send>() {}
        // Pipeline is shared as Arc<dyn PttSink + Send + Sync>.
        assert_send_sync::<Pipeline>();
        // Session need only be Send (it holds a !Sync mpsc::Receiver). Mutex<Option<Session>>
        // is Sync because Session: Send — and crucially it owns NO cpal Stream.
        assert_send::<Session>();
    };

    #[test]
    fn empty_clean_is_not_insertable() {
        assert!(!is_insertable(&DictationResult {
            raw: "um".into(),
            clean: "".into(),
            app: None,
        }));
    }

    #[test]
    fn real_text_is_insertable() {
        assert!(is_insertable(&DictationResult {
            raw: "hi".into(),
            clean: "Hi.".into(),
            app: None,
        }));
    }
}
