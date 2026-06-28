import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const { completeCb, listTranscripts, deleteTranscript } = vi.hoisted(() => {
  let _cb: (p: any) => void = () => {};
  const _rows = [
    { id: 1, raw_text: "raw", clean_text: "Hello there.", app_name: "TextEdit", created_at: "now" },
  ];
  return {
    completeCb: {
      set: (cb: (p: any) => void) => { _cb = cb; },
      fire: (p: any) => _cb(p),
    },
    listTranscripts: vi.fn(async () => _rows.slice()),
    deleteTranscript: vi.fn(async () => {}),
  };
});

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "dictation-complete") completeCb.set((p) => cb({ payload: p }));
    return () => {};
  }),
}));

vi.mock("../lib/db", () => ({
  listTranscripts,
  deleteTranscript,
}));

// clipboard plugin is not under test — stub it
vi.mock("@tauri-apps/plugin-clipboard-manager", () => ({
  writeText: vi.fn(async () => {}),
}));

import { HistoryList } from "../components/HistoryList";

describe("HistoryList", () => {
  it("renders a transcript row from listTranscripts", async () => {
    render(<HistoryList />);
    await waitFor(() => expect(screen.getByText("Hello there.")).toBeTruthy());
  });

  it("re-reads listTranscripts when dictation-complete fires (no insert)", async () => {
    const callsBefore = listTranscripts.mock.calls.length;
    render(<HistoryList />);
    completeCb.fire({ raw: "raw", clean: "World.", app: null });
    await waitFor(() => expect(listTranscripts.mock.calls.length).toBeGreaterThan(callsBefore));
  });
});
