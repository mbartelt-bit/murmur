#[cfg(any(test, not(target_os = "linux")))]
use std::str::FromStr;
#[cfg(not(target_os = "linux"))]
use std::sync::{Arc, Mutex};
use tauri::AppHandle;
#[cfg(not(target_os = "linux"))]
use tauri::{Emitter, Manager};
#[cfg(any(test, not(target_os = "linux")))]
use tauri_plugin_global_shortcut::Shortcut;
#[cfg(not(target_os = "linux"))]
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
#[cfg(not(target_os = "linux"))]
use tauri_plugin_store::StoreExt;

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

#[cfg(not(target_os = "linux"))]
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

// ── managed state for dynamic shortcut ───────────────────────────────────────

/// Managed state that holds the currently-active shortcut and the double-tap
/// state machine.  Both are behind `Mutex` so commands can swap the shortcut
/// at runtime while the plugin handler reads it concurrently.
///
/// LOCK CONSTRAINT: the plugin handler holds `tap` locked across `PttSink::start`
/// / `stop`.  A `PttSink` implementation MUST NOT acquire these mutexes (directly
/// or transitively) or it will deadlock the hotkey handler.
#[cfg(not(target_os = "linux"))]
pub struct Hotkeys {
    pub current: Mutex<Shortcut>,
    pub tap: Mutex<DoubleTap>,
}

const DEFAULT_ACCELERATOR: &str = "Control+Alt+KeyD";

/// Parse an accelerator string to a `Shortcut`, returning a user-facing error
/// string on failure.
#[cfg(any(test, not(target_os = "linux")))]
pub fn parse_accelerator(accel: &str) -> Result<Shortcut, String> {
    Shortcut::from_str(accel).map_err(|_| "Invalid shortcut".to_string())
}

/// Register the global shortcut plugin and wire it to `sink`.
///
/// The active shortcut is loaded from the store on startup (key `"hotkey"` in
/// `"settings.json"`), defaulting to `Control+Alt+KeyD`.
///
/// On `Pressed`:
///   - `StartHold` / `ToggleOn` → emit `"hud-state"` = `"recording"` + `sink.start()`
///   - `ToggleOff`              → `sink.stop()`
///
/// On `Released`:
///   - `Stop`   → `sink.stop()`
///   - `Ignore` → (latched, do nothing)
#[cfg(not(target_os = "linux"))]
pub fn register(app: &AppHandle, sink: Arc<dyn PttSink>) -> tauri::Result<()> {
    // ── load saved accelerator from store ────────────────────────────────────
    let saved_accel: String = app
        .store("settings.json")
        .ok()
        .and_then(|store| store.get("hotkey"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()))
        .unwrap_or_else(|| DEFAULT_ACCELERATOR.to_owned());

    let initial_shortcut =
        parse_accelerator(&saved_accel).unwrap_or_else(|_| {
            parse_accelerator(DEFAULT_ACCELERATOR).expect("default accelerator must parse")
        });

    // ── build managed Hotkeys state ──────────────────────────────────────────
    let hotkeys = Arc::new(Hotkeys {
        current: Mutex::new(initial_shortcut),
        tap: Mutex::new(DoubleTap::default()),
    });
    app.manage(Arc::clone(&hotkeys));

    // ── clone references for plugin handler closure ──────────────────────────
    let hk = Arc::clone(&hotkeys);
    let sink2 = sink.clone();

    app.plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_handler(move |app, sc, event| {
                // Compare against the LIVE shortcut, not the one captured at startup.
                let current = hk.current.lock().unwrap();
                if sc != &*current {
                    return;
                }
                drop(current); // release before locking tap

                let mut tap = hk.tap.lock().unwrap();
                let ts = now_ms(); // single, consistent timestamp per event
                match event.state() {
                    ShortcutState::Pressed => match tap.on_press(ts) {
                        PressAction::StartHold | PressAction::ToggleOn => {
                            let _ = app.emit("hud-state", "recording");
                            sink2.start(app);
                        }
                        PressAction::ToggleOff => {
                            sink2.stop(app);
                        }
                    },
                    ShortcutState::Released => {
                        if tap.on_release(ts) == ReleaseAction::Stop {
                            sink2.stop(app);
                        }
                    }
                }
            })
            .build(),
    )?;

    app.global_shortcut()
        .register(initial_shortcut)
        .map_err(|e| {
            tauri::Error::PluginInitialization(
                "global-shortcut".to_string(),
                e.to_string(),
            )
        })?;

    Ok(())
}

// ── Tauri commands ────────────────────────────────────────────────────────────

/// Returns the current hotkey accelerator string (e.g. "control+alt+KeyD").
#[tauri::command]
#[cfg(not(target_os = "linux"))]
pub fn get_hotkey(app: AppHandle) -> String {
    let state = app.state::<Arc<Hotkeys>>();
    let sc = state.current.lock().unwrap();
    sc.into_string()
}

/// Swaps the active recording shortcut to `accelerator`.
///
/// - Parses the new accelerator; returns `Err("Invalid shortcut")` on parse failure.
/// - Unregisters the old shortcut; registers the new one.  If registration fails the
///   old shortcut is re-registered and `Err("That combo is unavailable — try another.")`
///   is returned.
/// - On success, persists the new accelerator to `settings.json`.
#[tauri::command]
#[cfg(not(target_os = "linux"))]
pub fn set_hotkey(app: AppHandle, accelerator: String) -> Result<(), String> {
    let new_sc = parse_accelerator(&accelerator)?;

    let state = app.state::<Arc<Hotkeys>>();
    let mut current = state.current.lock().unwrap();
    let old_sc = *current;

    // Unregister old shortcut. If this fails, make a best-effort attempt to keep
    // the old shortcut active so the user is never left with NO working hotkey.
    if let Err(e) = app.global_shortcut().unregister(old_sc) {
        let _ = app.global_shortcut().register(old_sc);
        return Err(format!("Failed to unregister old shortcut: {e}"));
    }

    // Attempt to register new shortcut.
    if let Err(_e) = app.global_shortcut().register(new_sc) {
        // Rollback: re-register old shortcut (best effort).
        let _ = app.global_shortcut().register(old_sc);
        return Err("That combo is unavailable — try another.".to_string());
    }

    // Update live state.
    *current = new_sc;
    drop(current);

    // Persist to store.
    if let Ok(store) = app.store("settings.json") {
        store.set("hotkey", serde_json::Value::String(new_sc.into_string()));
        let _ = store.save();
    }

    Ok(())
}

#[tauri::command]
#[cfg(target_os = "linux")]
pub fn get_hotkey() -> String { DEFAULT_ACCELERATOR.to_owned() }

#[tauri::command]
#[cfg(target_os = "linux")]
pub fn set_hotkey(accelerator: String) -> Result<(), String> {
    let _ = accelerator;
    Err("On Omarchy, change the Murmur shortcut in your Hyprland bindings.".into())
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

    /// parse_accelerator round-trip: valid strings parse without error.
    #[test]
    fn parse_valid_accelerator() {
        assert!(parse_accelerator("Control+Alt+KeyD").is_ok());
        assert!(parse_accelerator("Super+Shift+KeyR").is_ok());
        assert!(parse_accelerator("Control+Space").is_ok());
    }

    /// parse_accelerator rejects garbage strings.
    #[test]
    fn parse_invalid_accelerator() {
        assert!(parse_accelerator("NotAKey+Blah").is_err());
        assert!(parse_accelerator("").is_err());
    }
}
