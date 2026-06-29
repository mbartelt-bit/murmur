import { useEffect, useState, useCallback } from "react";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { listTranscripts, deleteTranscript, type Transcript } from "../lib/db";

// Inline SVG icons — no icon dependency

function IconCopy() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <rect x="4" y="4" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.4" />
      <path d="M3 10H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v1" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

function IconTrash() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <path d="M2 4h10M5 4V2.5A.5.5 0 0 1 5.5 2h3a.5.5 0 0 1 .5.5V4M11 4l-.7 7.3A1 1 0 0 1 9.3 12H4.7a1 1 0 0 1-1-.7L3 4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

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
    <div>
      <div className="section-label">History</div>
      {rows.length === 0 ? (
        <div
          style={{
            textAlign: "center",
            padding: "24px 0 8px",
            color: "var(--text-2)",
            fontSize: 13,
          }}
        >
          {/* Waveform icon */}
          <svg
            width="32"
            height="20"
            viewBox="0 0 32 20"
            fill="none"
            aria-hidden="true"
            style={{ display: "block", margin: "0 auto 10px" }}
          >
            <rect x="0" y="8" width="3" height="4" rx="1.5" fill="currentColor" opacity="0.4" />
            <rect x="5" y="5" width="3" height="10" rx="1.5" fill="currentColor" opacity="0.5" />
            <rect x="10" y="2" width="3" height="16" rx="1.5" fill="currentColor" opacity="0.6" />
            <rect x="15" y="0" width="3" height="20" rx="1.5" fill="currentColor" opacity="0.7" />
            <rect x="20" y="2" width="3" height="16" rx="1.5" fill="currentColor" opacity="0.6" />
            <rect x="25" y="5" width="3" height="10" rx="1.5" fill="currentColor" opacity="0.5" />
            <rect x="30" y="8" width="2" height="4" rx="1" fill="currentColor" opacity="0.4" />
          </svg>
          No dictations yet. Hold your shortcut to start.
        </div>
      ) : (
        <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
          {rows.map((r) => (
            <li key={r.id} className="history-row">
              <span
                style={{
                  fontSize: 13,
                  color: "var(--text)",
                  flex: 1,
                  overflow: "hidden",
                  display: "-webkit-box",
                  WebkitLineClamp: 2,
                  WebkitBoxOrient: "vertical",
                }}
              >
                {r.clean_text}
              </span>
              <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
                <button
                  className="icon-btn"
                  onClick={() => writeText(r.clean_text)}
                  title="Copy"
                  aria-label="Copy"
                >
                  <IconCopy />
                </button>
                <button
                  className="icon-btn icon-btn-danger"
                  onClick={async () => {
                    await deleteTranscript(r.id);
                    refresh();
                  }}
                  title="Delete"
                  aria-label="Delete"
                >
                  <IconTrash />
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
