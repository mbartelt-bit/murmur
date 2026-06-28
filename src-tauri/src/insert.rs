use arboard::{Clipboard, Error as ClipErr};
use enigo::{Direction::{Click, Press, Release}, Enigo, Key, Keyboard, Settings};
use std::{thread, time::Duration};

fn cmd_v() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.key(Key::Meta, Press).map_err(|e| e.to_string())?;
    let click = enigo.key(Key::Unicode('v'), Click).map_err(|e| e.to_string());
    let release = enigo.key(Key::Meta, Release).map_err(|e| e.to_string());
    click?;
    release?;
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
    cmd_v()?;
    thread::sleep(Duration::from_millis(150)); // let target app read before restore
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
