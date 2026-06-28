use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager};

pub const MODEL_FILE: &str = "ggml-base.en.bin";
pub const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";

fn models_dir(app: &AppHandle) -> PathBuf {
    let dir = app.path().app_data_dir().expect("app data dir").join("models");
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
        .map(|m| m.len() > 1_000_000)
        .unwrap_or(false)
}

#[tauri::command]
pub async fn download_model(app: AppHandle) -> Result<(), String> {
    use futures_util::StreamExt;
    use std::io::Write;

    let dest = model_path(&app);
    let resp = reqwest::get(MODEL_URL)
        .await
        .map_err(|e| e.to_string())?;
    let total = resp.content_length().unwrap_or(0);
    let mut stream = resp.bytes_stream();
    let tmp = dest.with_extension("part");
    let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut downloaded: u64 = 0;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        downloaded += chunk.len() as u64;
        if total > 0 {
            let _ = app.emit("model-progress", downloaded as f64 / total as f64);
        }
    }
    drop(file);
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
