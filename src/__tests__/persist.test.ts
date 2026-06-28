import { describe, it, expect, vi } from "vitest";

const { dictationCb, insertTranscript } = vi.hoisted(() => {
  let _cb: (p: any) => void = () => {};
  const _insert = vi.fn(async () => {});
  return {
    dictationCb: {
      set: (cb: (p: any) => void) => { _cb = cb; },
      fire: (p: any) => _cb(p),
    },
    insertTranscript: _insert,
  };
});

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "dictation-complete") dictationCb.set((p) => cb({ payload: p }));
    return () => {};
  }),
}));

vi.mock("../lib/db", () => ({
  insertTranscript,
}));

import { startDictationPersistence } from "../lib/persist";

describe("startDictationPersistence", () => {
  it("calls insertTranscript with correct args when dictation-complete fires", async () => {
    await startDictationPersistence();
    await dictationCb.fire({ raw: "raw text", clean: "Clean text.", app: "TextEdit" });
    expect(insertTranscript).toHaveBeenCalledWith("raw text", "Clean text.", "TextEdit");
  });

  it("returns an unlisten function", async () => {
    const unlisten = await startDictationPersistence();
    expect(typeof unlisten).toBe("function");
  });
});
