//! Hyprland sends explicit recording edges; no global keyboard monitoring is needed.
use crate::hotkey::{DoubleTap, PressAction, PttSink, ReleaseAction};
use std::{io, os::unix::{fs::PermissionsExt, net::UnixDatagram}, path::PathBuf, sync::Arc};
use tauri::{AppHandle, Emitter};

fn socket_path() -> io::Result<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR is not set; launch from your desktop session"))?;
    Ok(PathBuf::from(runtime).join("murmur.sock"))
}

/// Forward CLI actions to the existing process, or reserve the socket for a new one.
pub fn prepare() -> io::Result<Option<UnixDatagram>> {
    let arg = std::env::args().nth(1);
    let command = match arg.as_deref() {
        None | Some("--show-settings") => "settings",
        Some("--background") => "ping",
        Some("--ptt-press") => "press",
        Some("--ptt-release") => "release",
        Some("--status") => "ping",
        Some("--check-install") => {
            if !cfg!(feature = "custom-protocol") {
                return Err(io::Error::other("Rebuild with --features custom-protocol to embed the interface"));
            }
            return Ok(None);
        }
        Some("--help") => {
            println!("Murmur: local voice dictation\n  --background     Start without opening settings\n  --show-settings  Open settings\n  --ptt-press      Begin recording (Hyprland binding)\n  --ptt-release    End recording\n  --status         Check that Murmur is running");
            return Ok(None);
        }
        Some(_) => return Err(io::Error::other("Unknown option; use --help")),
    };
    let path = socket_path()?;
    let client = UnixDatagram::unbound()?;
    match client.send_to(command.as_bytes(), &path) {
        Ok(_) => return Ok(None),
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused) => {}
        Err(e) => return Err(e),
    }
    if matches!(command, "press" | "release") || arg.as_deref() == Some("--status") {
        return Err(io::Error::other("Murmur is not running. Open Murmur first."));
    }
    match std::fs::remove_file(&path) {
        Ok(()) => {},
        Err(e) if e.kind() == io::ErrorKind::NotFound => {},
        Err(e) => return Err(e),
    }
    let socket = UnixDatagram::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    Ok(Some(socket))
}

#[derive(Default)]
struct Edges {
    pressed: bool,
    tap: DoubleTap,
}

impl Edges {
    fn update(&mut self, command: &str, now: u64) -> Option<bool> {
        match command {
            "press" if !self.pressed => {
                self.pressed = true;
                Some(!matches!(self.tap.on_press(now), PressAction::ToggleOff))
            }
            "release" if self.pressed => {
                self.pressed = false;
                (self.tap.on_release(now) == ReleaseAction::Stop).then_some(false)
            }
            _ => None,
        }
    }
}

pub fn listen(app: AppHandle, socket: UnixDatagram, sink: Arc<dyn PttSink>) {
    std::thread::spawn(move || {
        let mut edges = Edges::default();
        let clock = std::time::Instant::now();
        let mut bytes = [0u8; 32];
        while let Ok(n) = socket.recv(&mut bytes) {
            let Ok(command) = std::str::from_utf8(&bytes[..n]) else { continue };
            if command == "settings" {
                let app2 = app.clone();
                let _ = app.run_on_main_thread(move || crate::windows::show_settings(&app2));
            } else if let Some(start) = edges.update(command, clock.elapsed().as_millis() as u64) {
                let app2 = app.clone();
                let sink = sink.clone();
                let _ = app.run_on_main_thread(move || {
                    if start {
                        let _ = app2.emit("hud-state", "recording");
                        sink.start(&app2);
                    } else {
                        sink.stop(&app2);
                    }
                });
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repeats_and_unmatched_releases_are_ignored() {
        let mut e = Edges::default();
        assert_eq!(e.update("release", 0), None);
        assert_eq!(e.update("press", 100), Some(true));
        assert_eq!(e.update("press", 200), None);
        assert_eq!(e.update("release", 900), Some(false));
        assert_eq!(e.update("release", 901), None);
    }
    #[test]
    fn double_tap_latches_until_next_press() {
        let mut e = Edges::default();
        assert_eq!(e.update("press", 100), Some(true));
        assert_eq!(e.update("release", 150), Some(false));
        assert_eq!(e.update("press", 200), Some(true));
        assert_eq!(e.update("release", 250), None);
        assert_eq!(e.update("press", 3000), Some(false));
    }
}
