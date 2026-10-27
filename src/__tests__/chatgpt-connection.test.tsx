import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
const { invoke } = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("../lib/ipc", () => ({ openUrl: vi.fn(async () => {}) }));
import { ChatGptConnection } from "../components/ChatGptConnection";
afterEach(cleanup);
beforeEach(() => {
  invoke.mockReset();
  invoke.mockImplementation(async (name: string) => {
    if (name === "chatgpt_status")
      return { active: null, accounts: [], signing_in: false };
  });
});
describe("ChatGPT connection", () => {
  it("explains text-only scope and waits for native verified sign-in", async () => {
    render(<ChatGptConnection />);
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("chatgpt_status"));
    expect(
      screen.getByText(/does not provide audio transcription/),
    ).toBeTruthy();
    invoke.mockImplementation((name: string) =>
      name === "chatgpt_sign_in" ? new Promise(() => {}) : Promise.resolve(),
    );
    fireEvent.click(
      screen.getByRole("button", { name: "Continue with ChatGPT" }),
    );
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("chatgpt_sign_in", {
        clientId: null,
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Cancel sign-in" }));
    expect(invoke).toHaveBeenCalledWith("chatgpt_cancel_sign_in");
  });
  it("does not load models when plan scope is declined", async () => {
    const state = {
      active: "oaiapp_test",
      accounts: [
        {
          client_id: "oaiapp_test",
          label: "Test",
          signed_in: true,
          plan_enabled: false,
          model: null,
        },
      ],
      signing_in: false,
    };
    invoke.mockImplementation(async (name: string) =>
      name === "chatgpt_status" || name === "chatgpt_sign_in" ? state : [],
    );
    render(<ChatGptConnection />);
    await screen.findByRole("combobox", { name: "ChatGPT account" });
    fireEvent.click(
      screen.getByRole("button", { name: "Continue with ChatGPT" }),
    );
    await screen.findByText(/ChatGPT plan usage was not enabled/);
    expect(invoke.mock.calls.some(([name]) => name === "chatgpt_models")).toBe(
      false,
    );
  });
  it("surfaces native failures without claiming a connection", async () => {
    invoke.mockImplementation(async (name: string) => {
      if (name === "chatgpt_sign_in")
        throw new Error("Identity nonce did not match");
      return { active: null, accounts: [], signing_in: false };
    });
    render(<ChatGptConnection />);
    fireEvent.click(
      screen.getByRole("button", { name: "Continue with ChatGPT" }),
    );
    expect((await screen.findByRole("alert")).textContent).toContain(
      "Identity nonce did not match",
    );
  });
});
