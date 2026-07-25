use arboard::{Clipboard, Error as ClipErr};
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

#[cfg(not(target_os = "macos"))]
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
