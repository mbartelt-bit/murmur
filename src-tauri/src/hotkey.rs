#[cfg(any(test, not(target_os = "linux")))]
use std::str::FromStr;
#[cfg(not(target_os = "linux"))]
use std::sync::{Arc, Mutex};
use tauri::AppHandle;
#[cfg(not(target_os = "linux"))]
use tauri::Manager;
#[cfg(any(test, not(target_os = "linux")))]
use tauri_plugin_global_shortcut::Shortcut;
#[cfg(not(target_os = "linux"))]
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
#[cfg(not(target_os = "linux"))]
use tauri_plugin_store::StoreExt;

/// Keyboard repeat filtering is shared by hold and toggle modes.
#[derive(Default)]
pub struct KeyEdges {
    pressed: bool,
}
impl KeyEdges {
    pub fn update(&mut self, pressed: bool) -> bool {
        if self.pressed == pressed {
            return false;
        }
        self.pressed = pressed;
        true
    }
}

// ── public contract for Task 13 ───────────────────────────────────────────────

/// Task 13 (pipeline) implements this to receive start/stop recording edges.
pub trait PttSink: Send + Sync {
    fn start(&self, app: &AppHandle);
    fn stop(&self, app: &AppHandle);
    fn toggle(&self, app: &AppHandle) {
        self.start(app);
    }
}

// ── managed state for dynamic shortcut ───────────────────────────────────────

/// Managed state that holds the currently-active shortcut and the key-edge
/// state machine.  Both are behind `Mutex` so commands can swap the shortcut
/// at runtime while the plugin handler reads it concurrently.
///
/// Edge locks are released before invoking the recording pipeline.
#[cfg(not(target_os = "linux"))]
pub struct Hotkeys {
    pub current: Mutex<Shortcut>,
    pub edges: Mutex<KeyEdges>,
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
/// Hold mode records between press/release. Toggle mode acts on presses only.
#[cfg(not(target_os = "linux"))]
pub fn register(app: &AppHandle, sink: Arc<dyn PttSink>) -> tauri::Result<()> {
    // ── load saved accelerator from store ────────────────────────────────────
    let saved_accel: String = app
        .store("settings.json")
        .ok()
        .and_then(|store| store.get("hotkey"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()))
        .unwrap_or_else(|| DEFAULT_ACCELERATOR.to_owned());

    let initial_shortcut = parse_accelerator(&saved_accel).unwrap_or_else(|_| {
        parse_accelerator(DEFAULT_ACCELERATOR).expect("default accelerator must parse")
    });

    // ── build managed Hotkeys state ──────────────────────────────────────────
    let hotkeys = Arc::new(Hotkeys {
        current: Mutex::new(initial_shortcut),
        edges: Mutex::new(KeyEdges::default()),
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
                drop(current); // release before locking edges

                let pressed = event.state() == ShortcutState::Pressed;
                if !hk.edges.lock().unwrap().update(pressed) {
                    return;
                }
                if toggle_mode(app) {
                    if pressed {
                        sink2.toggle(app);
                    }
                } else if pressed {
                    sink2.start(app);
                } else {
                    sink2.stop(app);
                }
            })
            .build(),
    )?;

    app.global_shortcut()
        .register(initial_shortcut)
        .map_err(|e| {
            tauri::Error::PluginInitialization("global-shortcut".to_string(), e.to_string())
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
    if crate::pipeline::recording_state(app.clone()) != "idle" {
        return Err("Finish your dictation before changing the shortcut.".into());
    }
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
    *state.edges.lock().unwrap() = KeyEdges::default();

    // Persist to store.
    if let Ok(store) = app.store("settings.json") {
        store.set("hotkey", serde_json::Value::String(new_sc.into_string()));
        let _ = store.save();
    }

    Ok(())
}

#[tauri::command]
#[cfg(target_os = "linux")]
pub fn get_hotkey() -> String {
    DEFAULT_ACCELERATOR.to_owned()
}

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

    #[test]
    fn key_repeat_and_unmatched_release_do_not_toggle() {
        let mut edges = KeyEdges::default();
        assert!(!edges.update(false));
        assert!(edges.update(true));
        assert!(!edges.update(true));
        assert!(edges.update(false));
        assert!(!edges.update(false));
        assert!(edges.update(true));
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

pub fn toggle_mode(app: &AppHandle) -> bool {
    use tauri_plugin_store::StoreExt;
    app.store("settings.json")
        .ok()
        .and_then(|s| s.get("recording_mode"))
        .and_then(|v| v.as_str().map(|s| s == "toggle"))
        .unwrap_or(false)
}
#[tauri::command]
pub fn get_recording_mode(app: AppHandle) -> String {
    if toggle_mode(&app) { "toggle" } else { "hold" }.into()
}
#[tauri::command]
pub fn set_recording_mode(app: AppHandle, mode: String) -> Result<(), String> {
    use tauri_plugin_store::StoreExt;
    if !matches!(mode.as_str(), "hold" | "toggle") {
        return Err("Unknown recording mode".into());
    }
    if crate::pipeline::recording_state(app.clone()) != "idle" {
        return Err("Finish recording before changing this setting.".into());
    }
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    store.set("recording_mode", serde_json::Value::String(mode));
    store.save().map_err(|e| e.to_string())
}
