mod audio;
mod cleanup;
mod hotkey;
mod insert;
mod model;
mod permissions;
mod pipeline;
mod resample;
mod secrets;
mod stt;
mod windows;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};
use tauri_plugin_sql::{Builder as SqlBuilder, Migration, MigrationKind};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
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
        .plugin(SqlBuilder::default().add_migrations("sqlite:murmur.db", migrations).build())
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(|app| {
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

            pipeline::init(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            secrets::secret_set,
            secrets::secret_get,
            secrets::secret_delete,
            permissions::mic_status,
            permissions::request_mic,
            permissions::accessibility_trusted,
            permissions::open_privacy_pane,
            model::model_ready,
            model::download_model,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Murmur");
}
