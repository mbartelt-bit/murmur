import { useEffect, useState, useCallback } from "react";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { listTranscripts, deleteTranscript, type Transcript } from "../lib/db";

export function HistoryList() {
  const [rows, setRows] = useState<Transcript[]>([]);
  const refresh = useCallback(async () => setRows(await listTranscripts(50)), []);

  useEffect(() => {
    refresh();
    const un = listen<{ raw: string; clean: string; app: string | null }>(
      "dictation-complete",
      async (_e) => {
        refresh();
      },
    );
    return () => {
      un.then((f) => f());
    };
  }, [refresh]);

  return (
    <div className="p-4 space-y-2">
      <h2 className="font-semibold">Recent dictations</h2>
      {rows.length === 0 && (
        <p className="text-sm opacity-60">No dictations yet. Hold ⌘⇧D to start.</p>
      )}
      {rows.map((r) => (
        <div key={r.id} className="flex items-start justify-between gap-3 border-b py-2">
          <span className="text-sm">{r.clean_text}</span>
          <div className="flex gap-2 shrink-0">
            <button onClick={() => writeText(r.clean_text)} title="Copy">⧉</button>
            <button
              onClick={async () => {
                await deleteTranscript(r.id);
                refresh();
              }}
              title="Delete"
            >
              ✕
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
