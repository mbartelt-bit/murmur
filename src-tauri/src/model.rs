use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager};

const MODEL_SIZE: u64 = 147_964_211;
// SHA-256 from the upstream Hugging Face LFS object metadata.
const MODEL_SHA256: &str = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002";
static DOWNLOADING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
struct DownloadGuard;
impl Drop for DownloadGuard {
    fn drop(&mut self) {
        DOWNLOADING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

pub const MODEL_FILE: &str = "ggml-base.en.bin";
pub const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";

fn models_dir(app: &AppHandle) -> PathBuf {
    let dir = app
        .path()
        .app_data_dir()
        .expect("app data dir")
        .join("models");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn model_path(app: &AppHandle) -> PathBuf {
    models_dir(app).join(MODEL_FILE)
}

#[tauri::command]
pub fn model_ready(app: AppHandle) -> bool {
    let p = model_path(&app);
    std::fs::metadata(&p)
        .map(|m| m.len() == MODEL_SIZE)
        .unwrap_or(false)
}

#[tauri::command]
pub async fn download_model(app: AppHandle) -> Result<(), String> {
    use futures_util::StreamExt;
    use sha2::{Digest, Sha256};
    use std::io::Write;
    if DOWNLOADING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return Err("A model download is already running.".into());
    }
    let _guard = DownloadGuard;
    let mut digest = Sha256::new();

    let dest = model_path(&app);
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(900))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .get(MODEL_URL)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?;
    let total = resp.content_length().unwrap_or(0);
    let mut stream = resp.bytes_stream();
    let tmp = dest.with_extension("part");
    let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut downloaded: u64 = 0;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if downloaded + chunk.len() as u64 > MODEL_SIZE {
            return Err("Unexpected model size. Please retry the download.".into());
        }
        digest.update(&chunk);
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        downloaded += chunk.len() as u64;
        if total > 0 {
            let _ = app.emit("model-progress", downloaded as f64 / total as f64);
        }
    }
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    if downloaded != MODEL_SIZE || format!("{:x}", digest.finalize()) != MODEL_SHA256 {
        let _ = std::fs::remove_file(&tmp);
        return Err("Model verification failed. Please retry the download.".into());
    }
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    let _ = app.emit("model-progress", 1.0_f64);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_points_at_base_en() {
        assert!(MODEL_URL.ends_with(MODEL_FILE));
    }
}
