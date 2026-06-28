import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

let completeCb: (p: any) => void = () => {};
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "dictation-complete") completeCb = (p) => cb({ payload: p });
    return () => {};
  }),
}));
const rows: any[] = [];
vi.mock("../lib/db", () => ({
  insertTranscript: vi.fn(async (raw: string, clean: string, app: string | null) => { rows.unshift({ id: rows.length+1, raw_text: raw, clean_text: clean, app_name: app, created_at: "now" }); }),
  listTranscripts: vi.fn(async () => rows.slice()),
  deleteTranscript: vi.fn(async () => {}),
}));

import { HistoryList } from "../components/HistoryList";

describe("HistoryList", () => {
  it("appends a completed dictation", async () => {
    render(<HistoryList />);
    completeCb({ raw: "raw", clean: "Hello there.", app: "TextEdit" });
    await waitFor(() => expect(screen.getByText("Hello there.")).toBeTruthy());
  });
});
