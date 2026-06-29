use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

/// Returned by `get_engine_settings` — tells the UI what's currently chosen
/// and whether API keys are present (without exposing the key values).
#[derive(serde::Serialize)]
pub struct EngineSettings {
    pub stt: String,
    pub cleanup: String,
    pub openai_key: bool,
    pub groq_key: bool,
}

/// Return current engine selections + whether each cloud provider's key is set.
#[tauri::command]
pub fn get_engine_settings(app: AppHandle) -> EngineSettings {
    let store = app.store("settings.json").ok();

    let stt = store
        .as_ref()
        .and_then(|s| s.get("stt_engine"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()))
        .unwrap_or_else(|| "local".to_owned());

    let cleanup = store
        .as_ref()
        .and_then(|s| s.get("cleanup_engine"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()))
        .unwrap_or_else(|| "rule".to_owned());

    let openai_key = key_present("openai_api_key");
    let groq_key = key_present("groq_api_key");

    EngineSettings {
        stt,
        cleanup,
        openai_key,
        groq_key,
    }
}

/// Persist the user's chosen STT engine. Valid values: "local", "openai", "groq".
#[tauri::command]
pub fn set_stt_engine(app: AppHandle, value: String) -> Result<(), String> {
    if !matches!(value.as_str(), "local" | "openai" | "groq") {
        return Err(format!("invalid stt_engine value: {:?}", value));
    }
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    store.set("stt_engine", serde_json::Value::String(value));
    store.save().map_err(|e| e.to_string())
}

/// Persist the user's chosen cleanup engine. Valid values: "rule", "openai", "groq".
#[tauri::command]
pub fn set_cleanup_engine(app: AppHandle, value: String) -> Result<(), String> {
    if !matches!(value.as_str(), "rule" | "openai" | "groq") {
        return Err(format!("invalid cleanup_engine value: {:?}", value));
    }
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    store.set("cleanup_engine", serde_json::Value::String(value));
    store.save().map_err(|e| e.to_string())
}

/// Return true when the selected STT engine is usable:
/// - Cloud (openai/groq): API key is present and non-empty in Keychain.
/// - Local: model file exists and is >1 MB.
#[tauri::command]
pub fn stt_ready(app: AppHandle) -> bool {
    let stored = app
        .store("settings.json")
        .ok()
        .and_then(|s| s.get("stt_engine"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()));

    let choice = crate::stt::stt_choice(stored.as_deref());

    if let Some(provider) = crate::provider::Provider::from_id(choice) {
        key_present(provider.key_account())
    } else {
        // Local: model file must exist and be >1 MB
        let p = crate::model::model_path(&app);
        std::fs::metadata(&p)
            .map(|m| m.len() > 1_000_000)
            .unwrap_or(false)
    }
}

/// True when secrets::get returns a non-empty value for `account`.
fn key_present(account: &str) -> bool {
    crate::secrets::get(account)
        .ok()
        .flatten()
        .map(|k| !k.is_empty())
        .unwrap_or(false)
}
