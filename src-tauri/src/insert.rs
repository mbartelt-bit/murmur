#[cfg(not(target_os = "linux"))]
use arboard::{Clipboard, Error as ClipErr};
#[cfg(not(target_os = "linux"))]
use enigo::{Direction::{Click, Press, Release}, Enigo, Key, Keyboard, Settings};
use std::{thread, time::Duration};

// macOS virtual keycode for the V key (kVK_ANSI_V). We post the raw keycode
// rather than `Key::Unicode('v')` on purpose: Unicode resolution goes through
// the Text Input Source (TIS) APIs, which are MAIN-THREAD-ONLY and abort the
// process (dispatch_assert_queue_fail / SIGTRAP) when called from the paste
// worker thread. The raw keycode skips that lookup entirely.
#[cfg(target_os = "macos")]
const KEYCODE_V: u32 = 0x09;

#[cfg(target_os = "macos")]
fn paste_chord() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.key(Key::Meta, Press).map_err(|e| e.to_string())?;

    // Release Meta on every exit path — including a panic or an early `?`
    // return from the click below — so we never leave ⌘ stuck down.
    struct MetaGuard<'a>(&'a mut Enigo);
    impl Drop for MetaGuard<'_> {
        fn drop(&mut self) {
            let _ = self.0.key(Key::Meta, Release);
        }
    }
    let mut guard = MetaGuard(&mut enigo);

    guard.0.key(Key::Other(KEYCODE_V), Click).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn paste_chord() -> Result<(), String> {
    // Ctrl+V. No raw-keycode dance off macOS: enigo's SendInput path has no
    // main-thread-only APIs, and virtual keycodes differ per OS (0x09 is Tab
    // on Windows).
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.key(Key::Control, Press).map_err(|e| e.to_string())?;

    // Release Ctrl on every exit path so we never leave it stuck down.
    struct CtrlGuard<'a>(&'a mut Enigo);
    impl Drop for CtrlGuard<'_> {
        fn drop(&mut self) {
            let _ = self.0.key(Key::Control, Release);
        }
    }
    let mut guard = CtrlGuard(&mut enigo);

    guard.0.key(Key::Unicode('v'), Click).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn insert_text(text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    let mut clip = Clipboard::new().map_err(|e| e.to_string())?;
    let prev = match clip.get_text() {
        Ok(s) => Some(s),
        Err(ClipErr::ContentNotAvailable) => None,
        Err(e) => return Err(e.to_string()),
    };
    clip.set_text(text.to_owned()).map_err(|e| e.to_string())?;
    // Let the clipboard propagate before synthesizing the paste chord — a large
    // payload isn't instantly readable by the target app, so an immediate paste
    // can land empty.
    thread::sleep(Duration::from_millis(40));
    paste_chord()?;
    // Give the target app time to consume the paste before we restore the
    // previous clipboard. 150ms was too tight for longer transcripts.
    thread::sleep(Duration::from_millis(300));
    match prev {
        Some(p) => {
            let _ = clip.set_text(p);
        }
        None => {
            let _ = clip.clear();
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn insert_text(text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    if text.is_empty() { return Ok(()); }
    // Keep transcript text on stdin, never in process arguments. wl-copy owns
    // the Wayland selection after this process exits, unlike an X11 clipboard.
    let copy = |data: &[u8], mime: &str| -> Result<(), String> {
        let mut child = Command::new("wl-copy").args(["--type", mime])
            .stdin(Stdio::piped()).spawn().map_err(|e| format!("wl-copy: {e}"))?;
        child.stdin.take().unwrap().write_all(data).map_err(|e| e.to_string())?;
        if !child.wait().map_err(|e| e.to_string())?.success() {
            return Err("Could not set the Wayland clipboard".into());
        }
        Ok(())
    };
    // Preserve one representation of the previous selection, including images.
    let previous = Command::new("wl-paste").arg("--list-types").output().ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|types| types.lines().find(|t| t.contains('/')).map(str::to_owned))
        .and_then(|mime| Command::new("wl-paste").args(["--no-newline", "--type", &mime])
            .output().ok().filter(|o| o.status.success()).map(|o| (mime, o.stdout)));
    copy(text.as_bytes(), "text/plain;charset=utf-8")?;
    thread::sleep(Duration::from_millis(80));
    let class = Command::new("hyprctl").args(["activewindow", "-j"]).output().ok()
        .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
        .and_then(|v| v["class"].as_str().map(str::to_owned)).unwrap_or_default();
    // Use the same explicit-modifier dispatch as Omarchy's universal paste.
    // A virtual keyboard can merge physically held modifiers into the chord.
    let mods = if terminal_class(&class) { "CTRL SHIFT" } else { "CTRL" };
    let send_key = |state: &str| -> Result<(), String> {
        let dispatch = format!("hl.dsp.send_key_state({{mods=\"{mods}\",key=\"V\",state=\"{state}\"}})");
        let output = Command::new("hyprctl").args(["dispatch", &dispatch])
            .output().map_err(|e| format!("hyprctl: {e}"))?;
        if output.status.success() { Ok(()) }
        else { Err("Paste failed; your transcript is available in History.".into()) }
    };
    let down = send_key("down");
    thread::sleep(Duration::from_millis(50));
    // Always send key-up, even if key-down returned an error.
    let result = down.and(send_key("up"));
    thread::sleep(Duration::from_millis(500));
    // Don't overwrite a selection the user changed while the paste was in flight.
    let unchanged = Command::new("wl-paste").args(["--no-newline", "--type", "text/plain"])
        .output().ok().is_some_and(|o| o.status.success() && o.stdout == text.as_bytes());
    if unchanged {
        if let Some((mime, bytes)) = previous { let _ = copy(&bytes, &mime); }
        else { let _ = Command::new("wl-copy").arg("--clear").status(); }
    }
    result
}

#[cfg(target_os = "linux")]
fn terminal_class(class: &str) -> bool {
    matches!(class.to_ascii_lowercase().as_str(), "foot" | "footclient" | "alacritty" | "kitty" |
        "com.mitchellh.ghostty" | "org.wezfurlong.wezterm" | "org.gnome.terminal" | "org.kde.konsole" |
        "org.omarchy.terminal" | "org.omarchy.agent")
}

#[cfg(all(test, target_os = "linux"))]
mod linux_tests {
    #[test]
    fn uses_terminal_paste_only_for_known_terminal_classes() {
        assert!(super::terminal_class("Alacritty"));
        assert!(super::terminal_class("foot"));
        assert!(super::terminal_class("org.omarchy.agent"));
        assert!(!super::terminal_class("chromium"));
        assert!(!super::terminal_class("foot-notes"));
    }
}
