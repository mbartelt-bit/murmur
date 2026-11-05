import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
export function Recorder() {
  const [state, setState] = useState("idle");
  const [level, setLevel] = useState(0);
  const [latest, setLatest] = useState("");
  const [error, setError] = useState("");
  const [note, setNote] = useState("");
  const [pending, setPending] = useState(false);
  useEffect(() => {
    invoke<string>("recording_state")
      .then(setState)
      .catch(() => {});
    const listeners = [
      listen<string>("hud-state", (e) => setState(e.payload)),
      listen<number>("vu-level", (e) => setLevel(e.payload)),
      listen<{ clean: string }>("dictation-complete", (e) => {
        setLatest(e.payload.clean);
        setNote("Your dictation is ready.");
      }),
      listen<string>("dictation-error", (e) => setError(e.payload)),
      listen("dictation-empty", () =>
        setNote("No speech detected. Check your microphone and try again."),
      ),
    ];
    return () => {
      listeners.forEach((p) => p.then((f) => f()));
    };
  }, []);
  const command = async (name: string) => {
    setPending(true);
    setError("");
    setNote("");
    try {
      await invoke(name);
      if (name === "cancel_recording")
        setNote(
          "Cancelled. Any in-flight processing will finish without saving or pasting.",
        );
    } catch (e) {
      setError(String(e));
    } finally {
      setPending(false);
    }
  };
  return (
    <section className="recorder-card" aria-label="Record a dictation">
      <div className="recorder-top">
        <div>
          <p className="eyebrow">A thought, into words</p>
          <h2>
            {state === "recording"
              ? "Go ahead. We’re listening."
              : state === "transcribing"
                ? "Finding your words…"
                : "What’s on your mind?"}
          </h2>
          <p>
            Record here to create a draft. Use your shortcut to dictate into
            another app.
          </p>
        </div>
        <div className={`voice-orb ${state}`} aria-hidden="true">
          ∿
        </div>
      </div>
      <div className="recorder-bottom">
        <div className="row-actions">
          <button
            className={`btn ${state === "recording" ? "btn-danger" : "btn-primary"}`}
            disabled={pending || state === "transcribing"}
            onClick={() =>
              command(
                state === "recording" ? "stop_recording" : "start_recording",
              )
            }
          >
            {state === "recording"
              ? "Stop recording"
              : state === "transcribing"
                ? "Transcribing…"
                : "Start recording"}
          </button>
          {state !== "idle" && (
            <button
              className="btn btn-ghost"
              disabled={pending}
              onClick={() => command("cancel_recording")}
            >
              Cancel
            </button>
          )}
        </div>
        <span role="status" aria-live="polite" className="recording-status">
          <span className={`status-dot ${state}`} />
          {state === "idle"
            ? "Ready when you are"
            : state === "recording"
              ? "Recording"
              : "Transcribing"}
        </span>
      </div>
      {state === "recording" && (
        <meter
          aria-label="Microphone input level"
          min={0}
          max={1}
          value={Math.min(1, level * 8)}
        />
      )}
      {error && (
        <div role="alert" className="notice error">
          <strong>Something needs attention</strong>
          <p>{error}</p>
          <button className="text-button" onClick={() => setError("")}>
            Dismiss
          </button>
        </div>
      )}
      {note && (
        <p role="status" className="notice">
          {note}
        </p>
      )}
      {latest && (
        <details className="latest-draft">
          <summary>
            Latest text · available even if history could not save
          </summary>
          <p className="transcript-text">{latest}</p>
          <button
            className="btn btn-ghost"
            onClick={async () => {
              try {
                await writeText(latest);
                setNote("Copied to clipboard.");
              } catch {
                setError("Could not copy. Select the text to copy manually.");
              }
            }}
          >
            Copy latest text
          </button>
        </details>
      )}
    </section>
  );
}
