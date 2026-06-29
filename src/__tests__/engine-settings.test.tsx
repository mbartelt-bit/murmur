import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("../lib/ipc", () => ({
  getEngineSettings: () => invoke("get_engine_settings"),
  setSttEngine: (value: string) => invoke("set_stt_engine", value),
  setCleanupEngine: (value: string) => invoke("set_cleanup_engine", value),
  setSecret: (key: string, value: string) => invoke("secret_set", key, value),
  getSecret: (key: string) => invoke("secret_get", key),
  deleteSecret: (key: string) => invoke("secret_delete", key),
  modelReady: () => invoke("model_ready"),
  downloadModel: () => invoke("download_model"),
  onModelProgress: () => Promise.resolve(() => {}),
  openUrl: (url: string) => invoke("open_url", url),
  verifyProvider: (provider: string) => invoke("verify_provider", provider),
}));

import { EngineSettings } from "../components/EngineSettings";

const defaultSettings = {
  stt: "local",
  cleanup: "rule",
  openai_key: false,
  groq_key: false,
};

describe("EngineSettings", () => {
  beforeEach(() => {
    invoke.mockReset();
    // Default: return current settings + model not ready
    invoke.mockImplementation((cmd: string) => {
      if (cmd === "get_engine_settings") return Promise.resolve(defaultSettings);
      if (cmd === "model_ready") return Promise.resolve(false);
      return Promise.resolve(undefined);
    });
  });

  it("renders current engine selections (Local + Rule selected by default)", async () => {
    render(<EngineSettings />);

    // Wait for settings to load
    await waitFor(() =>
      expect(screen.queryByText(/loading engine settings/i)).toBeNull()
    );

    // Local (on-device Whisper) radio should be checked for STT
    const localRadio = screen.getByRole("radio", { name: /local \(on-device whisper\)/i });
    expect((localRadio as HTMLInputElement).checked).toBe(true);

    // Rule-based radio should be checked for cleanup
    const ruleRadio = screen.getByRole("radio", { name: /rule-based/i });
    expect((ruleRadio as HTMLInputElement).checked).toBe(true);
  });

  it("selecting OpenAI for transcription calls setSttEngine('openai')", async () => {
    // After setSttEngine, refresh will call get_engine_settings again
    let callCount = 0;
    invoke.mockImplementation((cmd: string) => {
      if (cmd === "get_engine_settings") {
        callCount++;
        // Second call (after set) returns openai selected
        if (callCount > 1)
          return Promise.resolve({ ...defaultSettings, stt: "openai" });
        return Promise.resolve(defaultSettings);
      }
      if (cmd === "model_ready") return Promise.resolve(false);
      if (cmd === "set_stt_engine") return Promise.resolve(undefined);
      return Promise.resolve(undefined);
    });

    render(<EngineSettings />);
    await waitFor(() =>
      expect(screen.queryByText(/loading engine settings/i)).toBeNull()
    );

    const openaiRadio = screen.getAllByRole("radio", { name: /openai/i })[0];
    fireEvent.click(openaiRadio);

    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("set_stt_engine", "openai")
    );
  });

  it("entering and saving an OpenAI key calls setSecret('openai_api_key', value)", async () => {
    let callCount = 0;
    invoke.mockImplementation((cmd: string) => {
      if (cmd === "get_engine_settings") {
        callCount++;
        if (callCount > 1)
          return Promise.resolve({ ...defaultSettings, stt: "openai" });
        return Promise.resolve({ ...defaultSettings, stt: "openai" });
      }
      if (cmd === "model_ready") return Promise.resolve(false);
      if (cmd === "set_stt_engine") return Promise.resolve(undefined);
      if (cmd === "secret_set") return Promise.resolve(undefined);
      if (cmd === "verify_provider") return Promise.resolve("Connected");
      return Promise.resolve(undefined);
    });

    render(<EngineSettings />);
    await waitFor(() =>
      expect(screen.queryByText(/loading engine settings/i)).toBeNull()
    );

    // With stt=openai, the key input should appear
    const keyInput = await screen.findByPlaceholderText(/openai api key/i);
    fireEvent.change(keyInput, { target: { value: "sk-test-key-123" } });

    // Button is now labeled "Connect"
    const connectBtn = screen.getByRole("button", { name: /connect/i });
    fireEvent.click(connectBtn);

    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("secret_set", "openai_api_key", "sk-test-key-123")
    );

    // Auto-verify fires after save
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("verify_provider", "openai")
    );
  });
});
