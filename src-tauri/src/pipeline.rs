#[cfg(not(target_os = "linux"))]
use crate::hotkey;
use crate::{audio, cleanup, hotkey::PttSink, insert, resample, stt, windows};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

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
    /// In-app recordings save a draft; shortcut recordings insert into the target.
    insert: bool,
    /// Signals the audio thread to finish capturing and return its samples.
    stop_tx: mpsc::Sender<()>,
    /// Receives `(interleaved_samples, sample_rate, channels)` once capture ends.
    samples_rx: mpsc::Receiver<(Vec<f32>, u32, u16)>,
}

pub struct Pipeline {
    /// `None` = idle, `Some` = recording.
    session: Mutex<Option<Session>>,
    busy: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    committed: Arc<AtomicBool>,
    commit_gate: Arc<Mutex<()>>,
}

impl Pipeline {
    fn new() -> Self {
        Self {
            session: Mutex::new(None),
            busy: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            committed: Arc::new(AtomicBool::new(false)),
            commit_gate: Arc::new(Mutex::new(())),
        }
    }
}

impl Pipeline {
    fn start_capture(&self, app: &AppHandle, insert: bool) {
        if self.busy.swap(true, Ordering::SeqCst) {
            let _ = app.emit("dictation-error", "Murmur is finishing your previous dictation. Wait until it is ready, then record again.");
            return;
        }
        self.cancelled.store(false, Ordering::SeqCst);
        self.committed.store(false, Ordering::SeqCst);
        // Belt-and-suspenders: if a prior session is somehow still live (double
        // start), stop it first so only one mic/Stream is ever active. Sending
        // its stop signal terminates that audio thread immediately.
        if let Some(old) = self.session.lock().unwrap().take() {
            let _ = old.stop_tx.send(());
        }

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

            // Emit level meter until told to stop. Treat a disconnected sender
            // (stop_tx dropped without a send — double-start overwrite or app
            // shutdown) as a stop too, so we never spin forever holding the Stream.
            loop {
                match stop_rx.try_recv() {
                    Ok(()) | Err(mpsc::TryRecvError::Disconnected) => break,
                    Err(mpsc::TryRecvError::Empty) => {}
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
        // Bounded so a hung mic init can't freeze the hotkey caller forever.
        match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(Ok(())) => {
                eprintln!("Murmur: recording started");
                windows::show_hud(&app);
                let _ = app.emit("hud-state", "recording");
                *self.session.lock().unwrap() = Some(Session {
                    insert,
                    stop_tx,
                    samples_rx: samp_rx,
                });
            }
            Ok(Err(e)) => {
                eprintln!("Murmur: microphone failed: {e}");
                let _ = app.emit("dictation-error", e);
                let _ = app.emit("hud-state", "idle");
                self.busy.store(false, Ordering::SeqCst);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let _ = app.emit("dictation-error", "The microphone is taking too long to start. Wait for it to stop, or restart Murmur.".to_string());
                let busy = self.busy.clone();
                // Disconnect the stop sender before waiting for slow native init.
                drop(stop_tx);
                std::thread::spawn(move || {
                    let _finish = Finish { app, busy };
                    let _ = samp_rx.recv();
                });
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                self.busy.store(false, Ordering::SeqCst);
                let _ = app.emit("hud-state", "idle");
                let _ = app.emit(
                    "dictation-error",
                    "audio thread terminated unexpectedly".to_string(),
                );
            }
        }
    }
}

impl PttSink for Pipeline {
    fn start(&self, app: &AppHandle) {
        self.start_capture(app, true);
    }
    fn toggle(&self, app: &AppHandle) {
        let recording = self.session.lock().unwrap().is_some();
        if recording {
            self.stop(app);
        } else {
            self.start(app);
        }
    }
    fn stop(&self, app: &AppHandle) {
        let session = self.session.lock().unwrap().take();
        let Some(session) = session else {
            return;
        };
        eprintln!("Murmur: recording stopped; transcribing");
        let stopped_at = std::time::Instant::now();
        // Tell the audio thread to finish and hand back its samples.
        let _ = session.stop_tx.send(());
        let should_insert = session.insert;
        let samples_rx = session.samples_rx;
        let busy = self.busy.clone();
        let cancelled = self.cancelled.clone();
        let committed = self.committed.clone();
        let commit_gate = self.commit_gate.clone();
        let app = app.clone();

        // Heavy work (transcribe/cleanup/insert) runs OFF the hotkey event thread.
        std::thread::spawn(move || {
            let _finish = Finish {
                app: app.clone(),
                busy,
            };
            let (interleaved, sr, ch) =
                match samples_rx.recv_timeout(std::time::Duration::from_secs(5)) {
                    Ok(v) => v,
                    Err(_) => {
                        let _ = app.emit(
                            "dictation-error",
                            "audio capture produced no samples".to_string(),
                        );
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
            // A quick latch tap or silence is not speech. Avoid Whisper hallucinations.
            if audio16k.len() < 4800 || audio::rms(&audio16k) < 0.0001 {
                let _ = app.emit("dictation-empty", ());
                return;
            }

            let engine = stt::make_engine(&app);
            let transcription_started = std::time::Instant::now();
            let raw = match engine.transcribe(&audio16k, &crate::personalization::prompt(&app)) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("Murmur: transcription failed: {e}");
                    let _ = app.emit("dictation-error", e.to_string());
                    return;
                }
            };
            eprintln!(
                "Murmur timing: transcription={}ms audio={}ms",
                transcription_started.elapsed().as_millis(),
                audio16k.len() / 16
            );

            if cancelled.load(Ordering::SeqCst) {
                return;
            }
            let cleanup_started = std::time::Instant::now();
            let clean = cleanup::make_engine(&app).clean(&raw);
            eprintln!(
                "Murmur timing: cleanup={}ms",
                cleanup_started.elapsed().as_millis()
            );
            let result = DictationResult {
                raw,
                clean: clean.clone(),
                app: None,
            };

            let _commit = commit_gate.lock().unwrap();
            if cancelled.load(Ordering::SeqCst) {
                return;
            }
            committed.store(true, Ordering::SeqCst);
            drop(_commit);
            // Always surface/persist the result, even when nothing is inserted.
            let _ = app.emit("dictation-complete", result.clone());

            if should_insert && is_insertable(&result) {
                let insertion_started = std::time::Instant::now();
                if let Err(e) = insert::insert_text(&clean) {
                    eprintln!("Murmur: insertion failed: {e}");
                    let _ = app.emit("dictation-error", e);
                }
                eprintln!(
                    "Murmur timing: insertion={}ms",
                    insertion_started.elapsed().as_millis()
                );
            } else if !is_insertable(&result) {
                let _ = app.emit("dictation-empty", ());
            }

            eprintln!(
                "Murmur: dictation complete; stop-to-complete={}ms",
                stopped_at.elapsed().as_millis()
            );
        });
    }
}

pub fn init(app: &AppHandle) -> Arc<dyn PttSink> {
    let pipeline = Arc::new(Pipeline::new());
    app.manage(pipeline.clone());
    let pipeline: Arc<dyn PttSink> = pipeline;
    // fn-key (globe) push-to-talk listener, alongside the ⌃⌥D global shortcut.
    crate::ptt_key::start(app.clone(), pipeline.clone());
    #[cfg(not(target_os = "linux"))]
    if let Err(e) = hotkey::register(app, pipeline.clone()) {
        eprintln!("hotkey registration failed: {e}");
    }
    pipeline
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

struct Finish {
    app: AppHandle,
    busy: Arc<AtomicBool>,
}
impl Drop for Finish {
    fn drop(&mut self) {
        let _ = self.app.emit("hud-state", "idle");
        windows::hide_hud(&self.app);
        self.busy.store(false, Ordering::SeqCst);
    }
}
#[tauri::command]
pub fn recording_state(app: AppHandle) -> String {
    let p = app.state::<Arc<Pipeline>>();
    if p.session.lock().unwrap().is_some() {
        "recording"
    } else if p.busy.load(Ordering::SeqCst) {
        "transcribing"
    } else {
        "idle"
    }
    .into()
}
#[tauri::command]
pub fn start_recording(app: AppHandle) -> Result<(), String> {
    let p = app.state::<Arc<Pipeline>>();
    if p.busy.load(Ordering::SeqCst) {
        return Err("Finish the current dictation first.".into());
    }
    // In-app recordings become drafts; hotkey recordings paste into the target app.
    p.start_capture(&app, false);
    Ok(())
}
#[tauri::command]
pub fn stop_recording(app: AppHandle) {
    app.state::<Arc<Pipeline>>().stop(&app);
}
#[tauri::command]
pub fn cancel_recording(app: AppHandle) -> Result<(), String> {
    let p = app.state::<Arc<Pipeline>>();
    let _gate = p
        .commit_gate
        .lock()
        .map_err(|_| "Could not cancel dictation")?;
    if p.committed.load(Ordering::SeqCst) {
        return Err(
            "This dictation has already finished. You can edit or delete it in History.".into(),
        );
    }
    p.cancelled.store(true, Ordering::SeqCst);
    let session = p.session.lock().unwrap().take();
    if let Some(session) = session {
        let _ = session.stop_tx.send(());
        let busy = p.busy.clone();
        let app = app.clone();
        // Do not allow a new mic stream until the capture thread acknowledges
        // that it has dropped the old stream. Cancellation never transcribes.
        std::thread::spawn(move || {
            let _finish = Finish { app, busy };
            let _ = session.samples_rx.recv();
        });
    }
    Ok(())
}
