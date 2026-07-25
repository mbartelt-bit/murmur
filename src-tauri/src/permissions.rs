#[cfg(target_os = "macos")]
mod mac {
    use block2::RcBlock;
    use objc2::runtime::Bool;
    use objc2_av_foundation::{AVAuthorizationStatus, AVCaptureDevice, AVMediaTypeAudio};
    use std::sync::mpsc;

    pub fn mic_status_str() -> &'static str {
        let media_type = unsafe { AVMediaTypeAudio.unwrap() };
        let status =
            unsafe { AVCaptureDevice::authorizationStatusForMediaType(media_type) };
        if status == AVAuthorizationStatus::Authorized {
            "authorized"
        } else if status == AVAuthorizationStatus::Denied {
            "denied"
        } else if status == AVAuthorizationStatus::Restricted {
            "restricted"
        } else {
            "notDetermined"
        }
    }

    pub async fn request_mic_inner() -> bool {
        let (tx, rx) = mpsc::channel::<bool>();
        // Scope the non-Send RcBlock so it is dropped before the `.await` below.
        // requestAccess... returns immediately and AVFoundation retains the block
        // internally, so dropping our local reference here is safe.
        {
            let handler = RcBlock::new(move |granted: Bool| {
                let _ = tx.send(granted.as_bool());
            });
            let media_type = unsafe { AVMediaTypeAudio.unwrap() };
            unsafe {
                AVCaptureDevice::requestAccessForMediaType_completionHandler(
                    media_type, &handler,
                );
            }
        }
        // The completion handler fires on an internal queue. Move the blocking
        // recv off the async worker thread.
        tauri::async_runtime::spawn_blocking(move || rx.recv().unwrap_or(false))
            .await
            .unwrap_or(false)
    }
}

#[tauri::command]
pub fn mic_status() -> String {
    #[cfg(target_os = "macos")]
    {
        mac::mic_status_str().to_string()
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Off macOS there is no per-app mic authorization API for desktop apps;
        // capture either works or the OS-level privacy toggle silently blanks
        // it (surfaced via diag.log; real privacy-toggle check = port plan W1).
        "authorized".to_string()
    }
}

#[tauri::command]
pub async fn request_mic() -> bool {
    #[cfg(target_os = "macos")]
    {
        mac::request_mic_inner().await
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

#[tauri::command]
pub fn accessibility_trusted() -> bool {
    #[cfg(target_os = "macos")]
    {
        macos_accessibility_client::accessibility::application_is_trusted()
    }
    #[cfg(not(target_os = "macos"))]
    {
        // No Accessibility grant exists off macOS; synthetic input needs no
        // permission.
        true
    }
}

// Input Monitoring (needed for the fn-key event tap). These are the documented
// CoreGraphics gates for a listen-only event tap.
#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
}

/// True when the app already has Input Monitoring access for listening to events.
#[tauri::command]
pub fn input_monitoring_trusted() -> bool {
    #[cfg(target_os = "macos")]
    {
        unsafe { CGPreflightListenEventAccess() }
    }
    #[cfg(not(target_os = "macos"))]
    {
        // No Input Monitoring concept off macOS; nothing to grant.
        true
    }
}

/// Trigger the macOS Input Monitoring prompt (and register the app in that
/// list). Returns the current grant status.
#[tauri::command]
pub fn request_input_monitoring() -> bool {
    #[cfg(target_os = "macos")]
    {
        unsafe { CGRequestListenEventAccess() }
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Like `accessibility_trusted`, but on the first call it triggers the macOS
/// system prompt ("… would like to control this computer using accessibility
/// features"). The side effect that matters: it registers the app in the
/// Accessibility list so the user actually has a Murmur row to toggle on.
/// Plain `application_is_trusted()` never adds the app to that list.
#[tauri::command]
pub fn prompt_accessibility() -> bool {
    #[cfg(target_os = "macos")]
    {
        macos_accessibility_client::accessibility::application_is_trusted_with_prompt()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

#[tauri::command]
pub fn open_privacy_pane(which: String) {
    #[cfg(target_os = "macos")]
    {
        let url = match which.as_str() {
            "accessibility" => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
            "input-monitoring" => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
            _ => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        };
        let _ = std::process::Command::new("open").arg(url).spawn();
    }
    #[cfg(target_os = "windows")]
    {
        // Only the mic pane has a Windows equivalent; all three requests route
        // there.
        let _ = which;
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", "ms-settings:privacy-microphone"])
            .spawn();
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = which;
    }
}

/// Open an arbitrary HTTPS URL in the default browser.
/// macOS uses `open`; Windows uses `rundll32`; no-op elsewhere.
#[tauri::command]
pub fn open_url(url: String) {
    // Only ever open https:// links (provider key pages) — never file:// or app schemes.
    if !url.starts_with("https://") {
        return;
    }
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(&url).spawn();
    }
    #[cfg(target_os = "windows")]
    {
        // rundll32 hands the URL straight to the default browser with no
        // cmd/start quoting pitfalls.
        let _ = std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", &url])
            .spawn();
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = url;
    }
}
