import { invoke } from "@tauri-apps/api/core";

export const micStatus = () => invoke<string>("mic_status");
export const requestMic = () => invoke<boolean>("request_mic");
export const accessibilityTrusted = () => invoke<boolean>("accessibility_trusted");
export const openPrivacyPane = (which: "mic" | "accessibility") =>
  invoke<void>("open_privacy_pane", { which });
