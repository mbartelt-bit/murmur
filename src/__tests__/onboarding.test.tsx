import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("../lib/ipc", () => ({
  micStatus: () => invoke("mic_status"),
  requestMic: () => invoke("request_mic"),
  accessibilityTrusted: () => invoke("accessibility_trusted"),
  openPrivacyPane: (w: string) => invoke("open_privacy_pane", w),
}));

import { Onboarding } from "../components/Onboarding";

describe("Onboarding", () => {
  beforeEach(() => invoke.mockReset());

  it("calls onReady when both permissions are granted", async () => {
    invoke.mockImplementation((cmd: string) =>
      cmd === "mic_status" ? Promise.resolve("authorized")
      : cmd === "accessibility_trusted" ? Promise.resolve(true)
      : Promise.resolve(true));
    const onReady = vi.fn();
    render(<Onboarding onReady={onReady} />);
    await waitFor(() => expect(onReady).toHaveBeenCalled());
  });

  it("shows a grant button when mic is not granted", async () => {
    invoke.mockImplementation((cmd: string) =>
      cmd === "mic_status" ? Promise.resolve("notDetermined")
      : cmd === "accessibility_trusted" ? Promise.resolve(false)
      : Promise.resolve(true));
    render(<Onboarding onReady={vi.fn()} />);
    expect(await screen.findByRole("button", { name: /allow microphone/i })).toBeTruthy();
  });
});
