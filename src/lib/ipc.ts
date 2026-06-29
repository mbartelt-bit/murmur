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

// --- Dictation pipeline events (Task 13) ---

export type HudState = "recording" | "transcribing" | "idle";

export interface DictationResult {
  raw: string;
  clean: string;
  app: string | null;
}

/** Live microphone level, 0..1, emitted ~every 60ms while recording. */
export const onVuLevel = (cb: (level: number) => void) =>
  listen<number>("vu-level", (e) => cb(e.payload));

/** HUD state transitions: recording → transcribing → idle. */
export const onHudState = (cb: (state: HudState) => void) =>
  listen<HudState>("hud-state", (e) => cb(e.payload));

/** Fires when a transcript is ready (raw + cleaned), regardless of insertion. */
export const onDictationComplete = (cb: (result: DictationResult) => void) =>
  listen<DictationResult>("dictation-complete", (e) => cb(e.payload));

/** Fires when transcription produced nothing insertable (no garbage pasted). */
export const onDictationEmpty = (cb: () => void) =>
  listen<null>("dictation-empty", () => cb());

/** Fires on any pipeline failure (capture/transcribe/insert). */
export const onDictationError = (cb: (message: string) => void) =>
  listen<string>("dictation-error", (e) => cb(e.payload));

// --- Hotkey commands ---

// --- Engine settings (BYOK) ---

export interface EngineSettings {
  stt: string;
  cleanup: string;
  openai_key: boolean;
  groq_key: boolean;
}

export const getEngineSettings = () => invoke<EngineSettings>("get_engine_settings");
export const setSttEngine = (value: string) => invoke<void>("set_stt_engine", { value });
export const setCleanupEngine = (value: string) => invoke<void>("set_cleanup_engine", { value });
export const sttReady = () => invoke<boolean>("stt_ready");
export const setSecret = (key: string, value: string) => invoke<void>("secret_set", { key, value });
export const getSecret = (key: string) => invoke<string | null>("secret_get", { key });
export const deleteSecret = (key: string) => invoke<void>("secret_delete", { key });

// --- Hotkey commands ---

/** Returns the current recording shortcut accelerator string (e.g. "control+alt+KeyD"). */
export const getHotkey = (): Promise<string> => invoke<string>("get_hotkey");

/**
 * Sets a new recording shortcut.  Rejects with a user-facing message if the
 * accelerator is invalid or the combo is already in use by another app.
 */
export const setHotkey = (accel: string): Promise<void> =>
  invoke<void>("set_hotkey", { accelerator: accel });
