import { describe, it, expect, vi } from "vitest";

vi.mock("@tauri-apps/plugin-sql", () => {
  const rows: any[] = [];
  const fake = {
    execute: vi.fn(async (sql: string, args: any[]) => {
      if (sql.startsWith("INSERT")) rows.push({ id: rows.length + 1, raw_text: args[0], clean_text: args[1], app_name: args[2] });
      return { rowsAffected: 1, lastInsertId: rows.length };
    }),
    select: vi.fn(async () => rows.slice().reverse()),
  };
  return { default: { load: vi.fn(async () => fake) } };
});

import { insertTranscript, listTranscripts } from "../lib/db";

describe("db", () => {
  it("inserts then lists newest-first", async () => {
    await insertTranscript("raw one", "Clean one", "TextEdit");
    const rows = await listTranscripts(10);
    expect(rows[0].clean_text).toBe("Clean one");
  });
});
