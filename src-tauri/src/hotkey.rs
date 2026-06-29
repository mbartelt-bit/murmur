use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

/// How long (ms) the second tap must arrive after the first release to count as a double-tap.
pub const DOUBLE_TAP_MS: u64 = 400;

#[derive(Debug, PartialEq)]
pub enum PressAction {
    StartHold,
    ToggleOn,
    ToggleOff,
}

/// Returned by `on_release`.  `Stop` = end recording; `Ignore` = we are latched, do nothing.
#[derive(Debug, PartialEq)]
pub enum ReleaseAction {
    Stop,
    Ignore,
}

/// Pure state machine: hold-to-talk unless the second tap arrives within `DOUBLE_TAP_MS` of the
/// first release, in which case it latches (toggle on/off).
///
/// # Refinement vs. brief
/// Both `on_press` and `on_release` accept an explicit `now_ms: u64` parameter instead of reading
/// the real wall-clock internally.  This makes the timing window genuinely testable with
/// deterministic timestamps — the caller (`register`) passes `now_ms()` at the call site so
/// production behavior is identical (one consistent clock source per event).
#[derive(Default)]
pub struct DoubleTap {
    /// Timestamp (ms) of the most recent key-release, if any.
    last_release_ms: Option<u64>,
    /// True while we are in toggle-on (latched) mode.
    latched: bool,
}

impl DoubleTap {
    /// Called on key-press.  Returns the action to take.
    pub fn on_press(&mut self, now_ms: u64) -> PressAction {
        if self.latched {
            self.latched = false;
            return PressAction::ToggleOff;
        }
        if let Some(prev) = self.last_release_ms {
            if now_ms.saturating_sub(prev) <= DOUBLE_TAP_MS {
                self.latched = true;
                return PressAction::ToggleOn;
            }
        }
        PressAction::StartHold
    }

    /// Called on key-release.  `now_ms` is the timestamp at the moment of release (injected by
    /// the caller so tests can supply fake clocks).
    pub fn on_release(&mut self, now_ms: u64) -> ReleaseAction {
        if self.latched {
            return ReleaseAction::Ignore;
        }
        self.last_release_ms = Some(now_ms);
        ReleaseAction::Stop
    }
}

// ── wall-clock helper (used only in `register`) ──────────────────────────────

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

// ── public contract for Task 13 ───────────────────────────────────────────────

/// Task 13 (pipeline) implements this to receive start/stop recording edges.
pub trait PttSink: Send + Sync {
    fn start(&self, app: &AppHandle);
    fn stop(&self, app: &AppHandle);
}

/// Register `⌃⌥D` (Control+Option+D) as a global shortcut and wire it to `sink`.
///
/// On `Pressed`:
///   - `StartHold` / `ToggleOn` → emit `"hud-state"` = `"recording"` + `sink.start()`
///   - `ToggleOff`              → `sink.stop()`
///
/// On `Released`:
///   - `Stop`   → `sink.stop()`
///   - `Ignore` → (latched, do nothing)
///
/// This function compiles but is NOT called until Task 13 wires the pipeline.
#[allow(dead_code)]
pub fn register(app: &AppHandle, sink: Arc<dyn PttSink>) -> tauri::Result<()> {
    let shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyD);
    let state = Arc::new(Mutex::new(DoubleTap::default()));
    let sink2 = sink.clone();

    app.plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_handler(move |app, sc, event| {
                if sc != &shortcut {
                    return;
                }
                let mut st = state.lock().unwrap();
                let ts = now_ms(); // single, consistent timestamp per event
                match event.state() {
                    ShortcutState::Pressed => match st.on_press(ts) {
                        PressAction::StartHold | PressAction::ToggleOn => {
                            let _ = app.emit("hud-state", "recording");
                            sink2.start(app);
                        }
                        PressAction::ToggleOff => {
                            sink2.stop(app);
                        }
                    },
                    ShortcutState::Released => {
                        if st.on_release(ts) == ReleaseAction::Stop {
                            sink2.stop(app);
                        }
                    }
                }
            })
            .build(),
    )?;
    app.global_shortcut()
        .register(shortcut)
        .map_err(|e| {
            tauri::Error::PluginInitialization(
                "global-shortcut".to_string(),
                e.to_string(),
            )
        })?;
    Ok(())
}

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Lone press then release = pure hold-to-talk.
    #[test]
    fn lone_press_then_release_is_hold() {
        let mut d = DoubleTap::default();
        assert_eq!(d.on_press(1000), PressAction::StartHold);
        assert_eq!(d.on_release(1100), ReleaseAction::Stop);
    }

    /// Second tap within 400 ms of first release latches toggle-on;
    /// subsequent release is ignored (still recording).
    #[test]
    fn quick_second_tap_latches_toggle_on() {
        let mut d = DoubleTap::default();
        // First hold cycle
        d.on_press(1000);
        d.on_release(1100); // release at 1100 → last_release_ms = 1100
        // Second press 200 ms later (1300 - 1100 = 200 ≤ 400) → ToggleOn
        assert_eq!(d.on_press(1300), PressAction::ToggleOn);
        assert_eq!(d.on_release(1350), ReleaseAction::Ignore);
    }

    /// While latched, a new press toggles off.
    #[test]
    fn press_while_latched_toggles_off() {
        let mut d = DoubleTap::default();
        d.on_press(1000);
        d.on_release(1100);
        d.on_press(1300); // ToggleOn
        d.on_release(1350); // Ignore (still latched)
        // Next press — 5000 ms later — should ToggleOff
        assert_eq!(d.on_press(5000), PressAction::ToggleOff);
    }

    /// Slow second tap (600 ms > 400 ms window) must be treated as a fresh hold,
    /// NOT a toggle.  This is the case that proves the window logic works.
    #[test]
    fn slow_second_tap_is_fresh_hold() {
        let mut d = DoubleTap::default();
        d.on_press(1000);
        d.on_release(1100); // last_release_ms = 1100
        // Second press 600 ms after release (1700 - 1100 = 600 > 400) → StartHold
        assert_eq!(d.on_press(1700), PressAction::StartHold);
        assert_eq!(d.on_release(1800), ReleaseAction::Stop);
    }
}
