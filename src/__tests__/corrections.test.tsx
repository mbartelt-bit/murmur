import "@testing-library/jest-dom/vitest";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
const mocks = vi.hoisted(() => ({
  row: {
    id: 7,
    raw_text: "meet Mark tomorrow",
    clean_text: "Meet Mark tomorrow.",
    corrected_text: null as string | null,
    app_name: null,
    created_at: "2026-10-27 09:00:00",
  },
  correct: vi.fn(),
  learn: vi.fn(),
  remove: vi.fn(),
  copy: vi.fn(),
}));
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
}));
vi.mock("@tauri-apps/plugin-clipboard-manager", () => ({
  writeText: mocks.copy,
}));
vi.mock("../lib/vocabulary", () => ({ learnCorrection: mocks.learn }));
vi.mock("../lib/db", () => ({
  listTranscripts: vi.fn(async () => [{ ...mocks.row }]),
  correctTranscript: mocks.correct,
  deleteTranscript: mocks.remove,
}));
import { HistoryList } from "../components/HistoryList";
beforeEach(() => {
  cleanup();
  vi.clearAllMocks();
  mocks.row.corrected_text = null;
  mocks.correct.mockImplementation(async (_id, text) => {
    mocks.row.corrected_text = text;
  });
  mocks.learn.mockResolvedValue({});
  mocks.copy.mockResolvedValue(undefined);
});
describe("correcting a dictation", () => {
  it("preserves original text, learns from saved user edits, and reverses evidence on undo", async () => {
    render(<HistoryList />);
    fireEvent.click(await screen.findByRole("button", { name: "Correct" }));
    fireEvent.change(screen.getByLabelText("Correct dictation"), {
      target: { value: "Meet Marc tomorrow." },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save correction" }));
    await waitFor(() =>
      expect(mocks.learn).toHaveBeenCalledWith(
        7,
        "Meet Mark tomorrow.",
        "Meet Marc tomorrow.",
      ),
    );
    expect(screen.getByText("meet Mark tomorrow")).toBeTruthy();
    fireEvent.click(
      await screen.findByRole("button", { name: "Undo correction" }),
    );
    await waitFor(() =>
      expect(mocks.learn).toHaveBeenLastCalledWith(
        7,
        "Meet Mark tomorrow.",
        "Meet Mark tomorrow.",
      ),
    );
  });
  it("does not learn when saving the correction fails", async () => {
    mocks.correct.mockRejectedValueOnce(new Error("Disk full"));
    render(<HistoryList />);
    fireEvent.click(await screen.findByRole("button", { name: "Correct" }));
    fireEvent.change(screen.getByLabelText("Correct dictation"), {
      target: { value: "Marc" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save correction" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Disk full");
    expect(mocks.learn).not.toHaveBeenCalled();
    expect(screen.getByLabelText("Correct dictation")).toBeTruthy();
  });
  it("copies corrected text and requires a deliberate delete", async () => {
    mocks.row.corrected_text = "Meet Marc tomorrow.";
    render(<HistoryList />);
    fireEvent.click(await screen.findByRole("button", { name: "Copy" }));
    await waitFor(() =>
      expect(mocks.copy).toHaveBeenCalledWith("Meet Marc tomorrow."),
    );
    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(mocks.remove).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Delete dictation" }));
    await waitFor(() => expect(mocks.remove).toHaveBeenCalledWith(7));
    expect(mocks.learn).toHaveBeenCalledWith(
      7,
      "Meet Mark tomorrow.",
      "Meet Mark tomorrow.",
    );
  });
});
