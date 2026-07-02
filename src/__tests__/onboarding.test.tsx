import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("../lib/ipc", () => ({
  micStatus: () => invoke("mic_status"),
  requestMic: () => invoke("request_mic"),
  accessibilityTrusted: () => invoke("accessibility_trusted"),
  promptAccessibility: () => invoke("prompt_accessibility"),
  inputMonitoringTrusted: () => invoke("input_monitoring_trusted"),
  requestInputMonitoring: () => invoke("request_input_monitoring"),
  openPrivacyPane: (w: string) => invoke("open_privacy_pane", w),
  // Legacy model commands (still exported from ipc, used by EngineSettings for local path)
  modelReady: () => invoke("model_ready"),
  downloadModel: () => invoke("download_model"),
  onModelProgress: () => Promise.resolve(() => {}),
  // Engine settings (BYOK)
  sttReady: () => invoke("stt_ready"),
  getEngineSettings: () =>
    invoke("get_engine_settings").then(
      (r: unknown) =>
        r ?? { stt: "local", cleanup: "rule", openai_key: false, groq_key: false }
    ),
  setSttEngine: (value: string) => invoke("set_stt_engine", value),
  setCleanupEngine: (value: string) => invoke("set_cleanup_engine", value),
  setSecret: (key: string, value: string) => invoke("secret_set", key, value),
  getSecret: (key: string) => invoke("secret_get", key),
  deleteSecret: (key: string) => invoke("secret_delete", key),
  openUrl: (url: string) => invoke("open_url", url),
  verifyProvider: (provider: string) => invoke("verify_provider", provider),
}));

import { Onboarding } from "../components/Onboarding";

describe("Onboarding", () => {
  beforeEach(() => invoke.mockReset());

  it("calls onReady when mic, accessibility, and sttReady are all granted", async () => {
    invoke.mockImplementation((cmd: string) => {
      if (cmd === "mic_status") return Promise.resolve("authorized");
      if (cmd === "accessibility_trusted") return Promise.resolve(true);
      if (cmd === "stt_ready") return Promise.resolve(true);
      if (cmd === "get_engine_settings")
        return Promise.resolve({
          stt: "local",
          cleanup: "rule",
          openai_key: false,
          groq_key: false,
        });
      if (cmd === "model_ready") return Promise.resolve(true);
      return Promise.resolve(true);
    });
    const onReady = vi.fn();
    render(<Onboarding onReady={onReady} />);
    await waitFor(() => expect(onReady).toHaveBeenCalled());
  });

  it("shows a grant button when mic is not granted", async () => {
    invoke.mockImplementation((cmd: string) => {
      if (cmd === "mic_status") return Promise.resolve("notDetermined");
      if (cmd === "accessibility_trusted") return Promise.resolve(false);
      if (cmd === "stt_ready") return Promise.resolve(false);
      if (cmd === "get_engine_settings")
        return Promise.resolve({
          stt: "local",
          cleanup: "rule",
          openai_key: false,
          groq_key: false,
        });
      if (cmd === "model_ready") return Promise.resolve(false);
      return Promise.resolve(false);
    });
    render(<Onboarding onReady={vi.fn()} />);
    expect(await screen.findByRole("button", { name: /allow microphone/i })).toBeTruthy();
  });
});
