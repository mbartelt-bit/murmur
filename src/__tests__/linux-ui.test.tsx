import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { HotkeySetting } from "../components/HotkeySetting";

afterEach(() => { cleanup(); vi.restoreAllMocks(); });
describe("Linux shortcuts", () => {
  it("shows the actual Omarchy shortcut without claiming the hardware Fn key works", () => {
    vi.spyOn(navigator, "platform", "get").mockReturnValue("Linux x86_64");
    render(<HotkeySetting />);
    expect(screen.getByText("Ctrl+Alt+D")).toBeTruthy();
    expect(screen.queryByText(/🌐 fn/)).toBeNull();
    expect(screen.queryByRole("button", { name: "Change" })).toBeNull();
  });
});
