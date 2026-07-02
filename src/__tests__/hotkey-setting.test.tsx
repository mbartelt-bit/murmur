import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, act, fireEvent } from "@testing-library/react";

// Mock ipc before importing anything that depends on it.
const mockGetHotkey = vi.fn(async () => "Control+Alt+KeyD");
const mockSetHotkey = vi.fn(async (_accel?: string) => {});

vi.mock("../lib/ipc", () => ({
  getHotkey: () => mockGetHotkey(),
  setHotkey: (accel: string) => mockSetHotkey(accel),
  inputMonitoringTrusted: () => Promise.resolve(false),
  openPrivacyPane: () => {},
}));

import {
  HotkeySetting,
  formatAccelerator,
  formatKeyToken,
  buildAccelerator,
} from "../components/HotkeySetting";

// ── Formatter unit tests ──────────────────────────────────────────────────────

describe("formatKeyToken", () => {
  it("strips 'Key' prefix from single-letter keys", () => {
    expect(formatKeyToken("KeyD")).toBe("D");
    expect(formatKeyToken("KeyR")).toBe("R");
  });

  it("strips 'Digit' prefix from digit keys", () => {
    expect(formatKeyToken("Digit1")).toBe("1");
    expect(formatKeyToken("Digit0")).toBe("0");
  });

  it("handles Space", () => {
    expect(formatKeyToken("Space")).toBe("Space");
  });

  it("passes through other keys unchanged (capitalised)", () => {
    expect(formatKeyToken("F12")).toBe("F12");
    expect(formatKeyToken("ArrowUp")).toBe("ArrowUp");
  });
});

describe("formatAccelerator", () => {
  it("formats Control+Alt+KeyD as ⌃⌥D", () => {
    expect(formatAccelerator("Control+Alt+KeyD")).toBe("⌃⌥D");
  });

  it("formats control+alt+KeyD (lowercase modifiers) as ⌃⌥D", () => {
    expect(formatAccelerator("control+alt+KeyD")).toBe("⌃⌥D");
  });

  it("formats Super+Shift+KeyR as ⇧⌘R", () => {
    expect(formatAccelerator("Super+Shift+KeyR")).toBe("⇧⌘R");
  });

  it("formats Control+Space as ⌃Space", () => {
    expect(formatAccelerator("Control+Space")).toBe("⌃Space");
  });
});

describe("buildAccelerator", () => {
  const makeEvent = (overrides: Partial<KeyboardEvent>): KeyboardEvent =>
    ({
      ctrlKey: false,
      altKey: false,
      shiftKey: false,
      metaKey: false,
      code: "KeyD",
      ...overrides,
    } as unknown as KeyboardEvent);

  it("returns null when no modifiers are held", () => {
    expect(buildAccelerator(makeEvent({ code: "KeyD" }))).toBeNull();
  });

  it("builds Control+Alt+KeyD from ctrl+alt+D", () => {
    expect(
      buildAccelerator(makeEvent({ ctrlKey: true, altKey: true, code: "KeyD" }))
    ).toBe("Control+Alt+KeyD");
  });

  it("builds Shift+Super+KeyR from meta+shift+R (ctrl→alt→shift→super order)", () => {
    expect(
      buildAccelerator(makeEvent({ metaKey: true, shiftKey: true, code: "KeyR" }))
    ).toBe("Shift+Super+KeyR");
  });
});

// ── Component tests ───────────────────────────────────────────────────────────

describe("HotkeySetting", () => {
  beforeEach(() => {
    mockGetHotkey.mockClear();
    mockSetHotkey.mockClear();
    mockGetHotkey.mockResolvedValue("Control+Alt+KeyD");
    mockSetHotkey.mockResolvedValue(undefined);
  });

  it("(a) renders the formatted current combo ⌃⌥D on load", async () => {
    render(<HotkeySetting />);
    // Wait for getHotkey to resolve and the label to appear.
    await waitFor(() => expect(screen.getByText("⌃⌥D")).toBeTruthy());
  });

  it("(b) entering capture + dispatching ⌘⇧R calls setHotkey('Super+Shift+KeyR')", async () => {
    render(<HotkeySetting />);

    // Wait for the component to finish loading.
    await waitFor(() => expect(screen.getByText("⌃⌥D")).toBeTruthy());

    // Click "Change" to enter capture mode.
    const changeBtn = screen.getByRole("button", { name: /change/i });
    act(() => {
      fireEvent.click(changeBtn);
    });

    // Should show capture prompt.
    expect(screen.getByText(/press a key combo/i)).toBeTruthy();

    // Dispatch a keydown event for ⌘⇧R.
    await act(async () => {
      fireEvent.keyDown(window, {
        metaKey: true,
        shiftKey: true,
        code: "KeyR",
        key: "R",
      });
    });

    // setHotkey should have been called with the correct accelerator.
    // Order is ctrl→alt→shift→meta → "Shift+Super+KeyR".
    await waitFor(() =>
      expect(mockSetHotkey).toHaveBeenCalledWith("Shift+Super+KeyR")
    );
  });
});
