mod audio;
mod cleanup;
mod engines;
mod hotkey;
mod insert;
mod model;
mod permissions;
mod pipeline;
mod provider;
mod ptt_key;
mod resample;
mod secrets;
mod stt;
mod wav;
mod windows;
#[cfg(target_os = "linux")]
mod linux;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};
use tauri_plugin_sql::{Builder as SqlBuilder, Migration, MigrationKind};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Set before GTK/WebKit starts any threads. NVIDIA's explicit-sync path
    // can terminate the Wayland connection when opening a webview (WebKit #280210).
    // Other drivers ignore this NVIDIA-specific switch; retain user overrides.
    #[cfg(target_os = "linux")]
    if std::env::var_os("WAYLAND_DISPLAY").is_some()
        && std::env::var_os("__NV_DISABLE_EXPLICIT_SYNC").is_none()
    {
        std::env::set_var("__NV_DISABLE_EXPLICIT_SYNC", "1");
    }
    #[cfg(target_os = "linux")]
    let socket = match linux::prepare() {
        Ok(Some(socket)) => socket,
        Ok(None) => return,
        Err(e) => { eprintln!("Murmur: {e}"); std::process::exit(1); }
    };
    let migrations = vec![Migration {
        version: 1,
        description: "create_core_tables",
        sql: "
            CREATE TABLE transcripts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                raw_text TEXT NOT NULL,
                clean_text TEXT NOT NULL,
                app_name TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE dictionary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                term TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
        ",
        kind: MigrationKind::Up,
    }];

    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(SqlBuilder::default().add_migrations("sqlite:murmur.db", migrations).build())
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let quit = MenuItem::with_id(app, "quit", "Quit Murmur", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "settings" => windows::show_settings(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        windows::show_settings(tray.app_handle());
                    }
                })
                .build(app)?;

            // Keep the settings window reachable: hide (don't destroy) on
            // close so the tray can always reopen it, and show it on launch so
            // the user is never locked out of the UI.
            if let Some(w) = app.get_webview_window("settings") {
                let wc = w.clone();
                w.on_window_event(move |e| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = e {
                        api.prevent_close();
                        let _ = wc.hide();
                    }
                });
                if !std::env::args().any(|arg| arg == "--background") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }

            // Startup diagnostic — write the live permission state to a file so
            // trigger/permission problems can be read directly.
            if let Ok(dir) = app.path().app_data_dir() {
                let diag = format!(
                    "startup accessibility={} input_monitoring={} mic={}\n",
                    permissions::accessibility_trusted(),
                    permissions::input_monitoring_trusted(),
                    permissions::mic_status(),
                );
                let _ = std::fs::write(dir.join("diag.log"), diag);
            }

            let _pipeline = pipeline::init(app.handle());
            #[cfg(target_os = "linux")]
            linux::listen(app.handle().clone(), socket, _pipeline);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            secrets::secret_set,
            secrets::secret_get,
            secrets::secret_delete,
            permissions::mic_status,
            permissions::request_mic,
            permissions::accessibility_trusted,
            permissions::prompt_accessibility,
            permissions::input_monitoring_trusted,
            permissions::request_input_monitoring,
            permissions::open_privacy_pane,
            permissions::open_url,
            model::model_ready,
            model::download_model,
            hotkey::get_hotkey,
            hotkey::set_hotkey,
            engines::get_engine_settings,
            engines::set_stt_engine,
            engines::set_cleanup_engine,
            engines::stt_ready,
            engines::verify_provider,
            windows::restart_app,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Murmur");
}
