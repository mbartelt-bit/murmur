import { useCallback, useEffect, useState } from "react";
import {
  micStatus,
  requestMic,
  accessibilityTrusted,
  openPrivacyPane,
  sttReady,
} from "../lib/ipc";
import { EngineSettings } from "./EngineSettings";

export function Onboarding({ onReady }: { onReady: () => void }) {
  const [mic, setMic] = useState<string>("notDetermined");
  const [ax, setAx] = useState<boolean>(false);
  const [ready, setReady] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    const [m, a, r] = await Promise.all([
      micStatus(),
      accessibilityTrusted(),
      sttReady(),
    ]);
    setMic(m);
    setAx(a);
    setReady(r);
    if (m === "authorized" && a && r) onReady();
  }, [onReady]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 1500); // re-check after user returns from System Settings
    return () => clearInterval(id);
  }, [refresh]);

  return (
    <div
      style={{
        minHeight: "100vh",
        background: "var(--bg)",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        padding: "24px 16px 40px",
      }}
    >
      {/* Header */}
      <div style={{ textAlign: "center", marginBottom: 24 }}>
        {/* Mic icon */}
        <div
          style={{
            width: 48,
            height: 48,
            borderRadius: 14,
            background: "var(--accent)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            margin: "0 auto 14px",
          }}
        >
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" aria-hidden="true">
            <rect x="9" y="3" width="6" height="10" rx="3" fill="white" />
            <path d="M5 11a7 7 0 0 0 14 0" stroke="white" strokeWidth="2" strokeLinecap="round" fill="none" />
            <line x1="12" y1="18" x2="12" y2="21" stroke="white" strokeWidth="2" strokeLinecap="round" />
            <line x1="9" y1="21" x2="15" y2="21" stroke="white" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </div>
        <h1 style={{ fontSize: 20, fontWeight: 700, color: "var(--text)", marginBottom: 4 }}>
          Welcome to Murmur
        </h1>
        <p style={{ fontSize: 13, color: "var(--text-2)", margin: 0 }}>
          Set up permissions and your transcription engine to get started.
        </p>
      </div>

      {/* Steps card */}
      <div className="card" style={{ width: "100%", maxWidth: 400 }}>
        {/* Microphone */}
        <OnboardRow
          label="Microphone"
          hint="Required to capture your voice."
          ok={mic === "authorized"}
        >
          {mic !== "authorized" && (
            <button
              className="btn btn-primary"
              style={{ padding: "5px 12px", fontSize: 12 }}
              onClick={async () => {
                if (mic === "notDetermined") {
                  await requestMic();
                } else {
                  await openPrivacyPane("mic");
                }
                refresh();
              }}
            >
              Allow microphone
            </button>
          )}
        </OnboardRow>

        {/* Accessibility */}
        <OnboardRow
          label="Accessibility"
          hint="Needed for paste-on-cursor and the global hotkey."
          ok={ax}
        >
          {!ax && (
            <button
              className="btn btn-ghost"
              style={{ padding: "5px 12px", fontSize: 12 }}
              onClick={() => openPrivacyPane("accessibility")}
            >
              Open Accessibility settings
            </button>
          )}
        </OnboardRow>

        {/* Transcription — embedded EngineSettings, no border after */}
        <div style={{ paddingTop: 14 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
            {ready ? (
              <span className="status-icon-ok">
                <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
                  <path d="M2 5l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              </span>
            ) : (
              <span className="status-icon-pending" />
            )}
            <span style={{ fontSize: 13, fontWeight: 500, color: "var(--text)" }}>
              Transcription
            </span>
          </div>
          <p style={{ margin: "0 0 12px", fontSize: 12, color: "var(--text-2)", lineHeight: 1.5 }}>
            Pick how Murmur transcribes — Local and Groq are free; you can change this anytime.
          </p>
          <EngineSettings onChange={refresh} />
        </div>
      </div>
    </div>
  );
}

function OnboardRow({
  label,
  hint,
  ok,
  children,
}: {
  label: string;
  hint?: string;
  ok: boolean;
  children?: React.ReactNode;
}) {
  return (
    <div className="status-row">
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        {ok ? (
          <span className="status-icon-ok">
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
              <path d="M2 5l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
        ) : (
          <span className="status-icon-pending" />
        )}
        <div>
          <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text)" }}>{label}</div>
          {hint && (
            <div style={{ fontSize: 12, color: "var(--text-2)" }}>{hint}</div>
          )}
        </div>
      </div>
      {children && (
        <div style={{ flexShrink: 0 }}>{children}</div>
      )}
    </div>
  );
}
