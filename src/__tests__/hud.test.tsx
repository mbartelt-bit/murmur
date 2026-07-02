import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";

let stateCb: (p: string) => void = () => {};
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "hud-state") stateCb = (p) => cb({ payload: p });
    return () => {};
  }),
}));

import { Hud } from "../components/Hud";

describe("Hud", () => {
  it("shows Recording when state event fires", async () => {
    render(<Hud />);
    stateCb("recording");
    expect(await screen.findByLabelText(/recording/i)).toBeTruthy();
  });
});
