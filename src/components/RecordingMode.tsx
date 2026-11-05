import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
export function RecordingMode() {
  const [mode, setMode] = useState("hold");
  const [error, setError] = useState("");
  useEffect(() => {
    invoke<string>("get_recording_mode")
      .then(setMode)
      .catch((e) => setError(String(e)));
  }, []);
  return (
    <div className="recording-mode">
      <label htmlFor="recording-mode">Recording shortcut behavior</label>
      <select
        id="recording-mode"
        className="input"
        value={mode}
        onChange={async (e) => {
          const value = e.target.value;
          try {
            await invoke("set_recording_mode", { mode: value });
            setMode(value);
            setError("");
          } catch (e) {
            setError(String(e));
          }
        }}
      >
        <option value="hold">Hold to talk</option>
        <option value="toggle">Press once to start, once to stop</option>
      </select>
      <p className="privacy-note">
        Press-once mode lets you speak without holding a key. This also applies
        to the globe key on Mac.
      </p>
      {error && <p role="alert">{error}</p>}
    </div>
  );
}
