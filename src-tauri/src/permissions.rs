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
        "notDetermined".to_string()
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
        false
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
        false
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
            _ => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        };
        let _ = std::process::Command::new("open").arg(url).spawn();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = which;
    }
}

/// Open an arbitrary HTTPS URL in the default browser.
/// On macOS uses `open`; no-op on other platforms.
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
    #[cfg(not(target_os = "macos"))]
    {
        let _ = url;
    }
}
