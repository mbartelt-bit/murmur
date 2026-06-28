import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export const micStatus = () => invoke<string>("mic_status");
export const requestMic = () => invoke<boolean>("request_mic");
export const accessibilityTrusted = () => invoke<boolean>("accessibility_trusted");
export const openPrivacyPane = (which: "mic" | "accessibility") =>
  invoke<void>("open_privacy_pane", { which });

export const modelReady = () => invoke<boolean>("model_ready");
export const downloadModel = () => invoke<void>("download_model");
export const onModelProgress = (cb: (p: number) => void) =>
  listen<number>("model-progress", (e) => cb(e.payload));
