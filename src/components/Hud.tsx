import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

type State = "idle" | "recording" | "transcribing";

export function Hud() {
  const [state, setState] = useState<State>("idle");

  useEffect(() => {
    const un = listen<State>("hud-state", (e) => setState(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "transparent",
        userSelect: "none",
        pointerEvents: "none",
      }}
    >
      <style>{`
        @keyframes murmur-pulse { 0%,100%{transform:scale(1);opacity:1} 50%{transform:scale(.7);opacity:.55} }
        @keyframes murmur-glow  { 0%{transform:scale(1);opacity:.55} 70%,100%{transform:scale(2.4);opacity:0} }
        @keyframes murmur-wave  { 0%,100%{transform:scaleY(.25)} 50%{transform:scaleY(1)} }
      `}</style>

      {state === "recording" && <RecordingDot />}
      {state === "transcribing" && <SquiggleEq />}
    </div>
  );
}

/** While recording: a small capsule with a pulsing red dot + glow ring. */
function RecordingDot() {
  return (
    <div
      role="img"
      aria-label="Recording"
      style={{
        position: "relative",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        width: 44,
        height: 24,
        borderRadius: 12,
        background: "rgba(20,20,22,0.82)",
        boxShadow: "0 3px 12px rgba(0,0,0,0.38)",
      }}
    >
      <span
        style={{
          position: "absolute",
          width: 10,
          height: 10,
          borderRadius: "50%",
          background: "#ff5d5d",
          animation: "murmur-glow 1.4s ease-out infinite",
        }}
      />
      <span
        style={{
          width: 10,
          height: 10,
          borderRadius: "50%",
          background: "#ff5d5d",
          animation: "murmur-pulse 1.4s ease-in-out infinite",
        }}
      />
    </div>
  );
}

/** While transcribing/pasting: a small, translucent squiggling EQ. */
function SquiggleEq() {
  return (
    <div
      role="img"
      aria-label="Transcribing"
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 3,
        width: 68,
        height: 24,
        borderRadius: 12,
        background: "rgba(20,20,22,0.55)",
        boxShadow: "0 3px 12px rgba(0,0,0,0.25)",
      }}
    >
      {Array.from({ length: 7 }).map((_, i) => (
        <span
          key={i}
          style={{
            width: 3,
            height: "58%",
            borderRadius: 2,
            background: "rgba(154,160,255,0.85)",
            transformOrigin: "center",
            animation: `murmur-wave 0.85s ease-in-out ${(i * 0.08).toFixed(2)}s infinite`,
          }}
        />
      ))}
    </div>
  );
}
