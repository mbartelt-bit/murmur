import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

type State = "idle" | "recording" | "transcribing";

export function Hud() {
  const [state, setState] = useState<State>("idle");
  const [level, setLevel] = useState(0);

  useEffect(() => {
    const un1 = listen<State>("hud-state", (e) => setState(e.payload));
    const un2 = listen<number>("vu-level", (e) => setLevel(e.payload));
    return () => { un1.then((f) => f()); un2.then((f) => f()); };
  }, []);

  const label = state === "recording" ? "Recording…"
    : state === "transcribing" ? "Transcribing…" : "";

  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 10, height: 64, padding: "0 16px",
      borderRadius: 16, background: "rgba(20,20,22,0.92)", color: "white",
      fontFamily: "system-ui", fontSize: 13,
    }}>
      <span style={{
        width: 10, height: 10, borderRadius: "50%",
        background: state === "recording" ? "#ff5d5d" : "#8a8a8a",
      }} />
      <span>{label}</span>
      <div style={{ flex: 1, height: 6, background: "rgba(255,255,255,0.15)", borderRadius: 3 }}>
        <div style={{ width: `${Math.min(100, level * 250)}%`, height: "100%",
          background: "#6ee7a8", borderRadius: 3, transition: "width 80ms linear" }} />
      </div>
    </div>
  );
}
