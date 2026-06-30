use tauri::{AppHandle, LogicalPosition, Manager, WebviewWindow};

pub fn show_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

pub fn show_hud(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("hud") {
        // Non-interactive overlay: never steal clicks from the app beneath it.
        let _ = w.set_ignore_cursor_events(true);
        position_bottom_center(&w);
        let _ = w.show();
    }
}

pub fn hide_hud(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("hud") {
        let _ = w.hide();
    }
}

/// Park the HUD near the bottom-center of whatever monitor it's currently on
/// (Wispr-style floating indicator), clearing the Dock.
fn position_bottom_center(w: &WebviewWindow) {
    let Ok(Some(mon)) = w.current_monitor() else {
        return;
    };
    let scale = mon.scale_factor();
    let m_pos = mon.position().to_logical::<f64>(scale);
    let m_size = mon.size().to_logical::<f64>(scale);
    let win = match w.outer_size() {
        Ok(s) => s.to_logical::<f64>(scale),
        Err(_) => return,
    };
    let x = m_pos.x + (m_size.width - win.width) / 2.0;
    let y = m_pos.y + m_size.height - win.height - 90.0; // ~90pt above the bottom edge
    let _ = w.set_position(LogicalPosition::new(x, y));
}
