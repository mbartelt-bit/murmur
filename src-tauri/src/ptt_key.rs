//! Single-key push-to-talk. Per-OS implementations behind one `start` entry.
//!
//! macOS: the `fn` (globe) key. It is a modifier, so it never emits normal key
//! events — only `FlagsChanged`, with the `SecondaryFn` flag toggling on
//! press/release. We install a **listen-only** CGEventTap (which requires the
//! Input Monitoring permission) on a dedicated thread running its own
//! CFRunLoop, and translate fn-down / fn-up into `PttSink::start` / `stop`.
//!
//! Window/audio work must happen on the main thread on macOS, so every
//! start/stop is marshalled there via `run_on_main_thread`. This is the
//! no-modifier "hold to talk" trigger; the ⌃⌥D global shortcut still works too.

#[cfg(target_os = "macos")]
mod imp {
    use std::cell::Cell;
    use std::sync::Arc;

    use core_foundation::runloop::CFRunLoop;
    use core_graphics::event::{
        CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
        CGEventType, CallbackResult,
    };
    use tauri::{AppHandle, Emitter};

    use crate::hotkey::PttSink;

    /// Spawn the fn-key listener thread. If the event tap can't be created (Input
    /// Monitoring not granted yet), the thread logs and exits — the user grants the
    /// permission in onboarding and relaunches.
    pub fn start(app: AppHandle, sink: Arc<dyn PttSink>) {
        std::thread::spawn(move || {
            // Tracks the last-seen fn state so we only act on transitions
            // (FlagsChanged fires for every modifier, not just fn).
            let fn_down = Cell::new(false);

            let result = CGEventTap::with_enabled(
                CGEventTapLocation::HID,
                CGEventTapPlacement::HeadInsertEventTap,
                CGEventTapOptions::ListenOnly,
                vec![CGEventType::FlagsChanged],
                move |_proxy, _etype, event| {
                    let now = event
                        .get_flags()
                        .contains(CGEventFlags::CGEventFlagSecondaryFn);
                    if now != fn_down.get() {
                        fn_down.set(now);
                        let app_main = app.clone();
                        let sink_main = sink.clone();
                        // Hop to the main thread: start/stop touch Tauri windows.
                        let _ = app.run_on_main_thread(move || {
                            if now {
                                let _ = app_main.emit("hud-state", "recording");
                                sink_main.start(&app_main);
                            } else {
                                sink_main.stop(&app_main);
                            }
                        });
                    }
                    CallbackResult::Keep
                },
                || CFRunLoop::run_current(),
            );

            if result.is_err() {
                eprintln!(
                    "fn-key listener: couldn't create event tap (Input Monitoring not granted?)"
                );
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::sync::Arc;

    use tauri::AppHandle;

    use crate::hotkey::PttSink;

    /// Bare-key push-to-talk is macOS-only for now (fn/globe key — invisible to
    /// the OS on most PC keyboards). Off macOS the chord global shortcut is the
    /// sole trigger until the low-level keyboard hook lands (port plan W3).
    pub fn start(_app: AppHandle, _sink: Arc<dyn PttSink>) {}
}

pub use imp::start;
