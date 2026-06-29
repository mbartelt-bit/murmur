import { useState } from "react";
import { Onboarding } from "./components/Onboarding";
import { HistoryList } from "./components/HistoryList";
import { HotkeySetting } from "./components/HotkeySetting";
import { EngineSettings } from "./components/EngineSettings";

export default function App() {
  const [ready, setReady] = useState(false);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return (
    <div
      style={{
        minHeight: "100vh",
        background: "var(--bg)",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        padding: "24px 16px 32px",
      }}
    >
      {/* Header */}
      <div
        style={{
          width: "100%",
          maxWidth: 440,
          marginBottom: 20,
          display: "flex",
          alignItems: "center",
          gap: 10,
        }}
      >
        {/* Inline mic/waveform glyph */}
        <svg
          width="28"
          height="28"
          viewBox="0 0 28 28"
          fill="none"
          aria-hidden="true"
          style={{ flexShrink: 0 }}
        >
          <rect width="28" height="28" rx="8" fill="var(--accent)" />
          {/* mic body */}
          <rect x="11" y="6" width="6" height="10" rx="3" fill="var(--accent-fg)" />
          {/* mic stand arc */}
          <path
            d="M8 14a6 6 0 0 0 12 0"
            stroke="var(--accent-fg)"
            strokeWidth="1.8"
            strokeLinecap="round"
            fill="none"
          />
          {/* stem */}
          <line
            x1="14"
            y1="20"
            x2="14"
            y2="23"
            stroke="var(--accent-fg)"
            strokeWidth="1.8"
            strokeLinecap="round"
          />
          {/* base */}
          <line
            x1="11"
            y1="23"
            x2="17"
            y2="23"
            stroke="var(--accent-fg)"
            strokeWidth="1.8"
            strokeLinecap="round"
          />
        </svg>
        <div>
          <div style={{ fontSize: 17, fontWeight: 600, color: "var(--text)" }}>
            Murmur
          </div>
          <div style={{ fontSize: 12, color: "var(--text-2)", marginTop: 1 }}>
            Voice dictation
          </div>
        </div>
      </div>

      {/* Card stack */}
      <div
        style={{
          width: "100%",
          maxWidth: 440,
          display: "flex",
          flexDirection: "column",
          gap: 16,
        }}
      >
        {/* Transcription + Cleanup card */}
        <div className="card">
          <EngineSettings />
        </div>

        {/* Recording shortcut card */}
        <div className="card">
          <HotkeySetting />
        </div>

        {/* History card */}
        <div className="card">
          <HistoryList />
        </div>
      </div>
    </div>
  );
}
