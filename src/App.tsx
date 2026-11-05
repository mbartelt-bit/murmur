import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import { Onboarding } from "./components/Onboarding";
import { HistoryList } from "./components/HistoryList";
import { HotkeySetting } from "./components/HotkeySetting";
import { EngineSettings } from "./components/EngineSettings";
import { Vocabulary } from "./components/Vocabulary";
import { RecordingMode } from "./components/RecordingMode";
import { Recorder } from "./components/Recorder";

type Page = "dictation" | "words" | "settings";
export default function App() {
  const [globalError, setGlobalError] = useState("");
  useEffect(() => {
    const un = listen<string>("dictation-error", (e) =>
      setGlobalError(e.payload),
    );
    return () => {
      un.then((f) => f());
    };
  }, []);
  const [ready, setReady] = useState(false);
  const [page, setPage] = useState<Page>("dictation");
  useEffect(() => {
    const keydown = (e: KeyboardEvent) => {
      if (
        (e.metaKey || e.ctrlKey) &&
        e.shiftKey &&
        e.key.toLowerCase() === "e"
      ) {
        e.preventDefault();
        setPage("dictation");
        setTimeout(
          () => window.dispatchEvent(new Event("murmur-correct-last")),
          100,
        );
      }
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, []);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <aside className="sidebar">
        <a
          href="#main"
          className="brand"
          aria-label="Murmur home"
          onClick={() => setPage("dictation")}
        >
          <span className="brand-mark" aria-hidden="true">
            ∿
          </span>
          <span>
            murmur<span className="brand-caption">A little more you.</span>
          </span>
        </a>
        <nav aria-label="Main navigation">
          {(
            [
              { id: "dictation", label: "Dictation", icon: "◉" },
              { id: "words", label: "Your words", icon: "Aa" },
              { id: "settings", label: "Settings", icon: "⚙" },
            ] as const
          ).map((p) => (
            <button
              key={p.id}
              className={`nav-item ${page === p.id ? "active" : ""}`}
              aria-current={page === p.id ? "page" : undefined}
              onClick={() => setPage(p.id)}
            >
              <span aria-hidden="true">{p.icon}</span>
              {p.label}
            </button>
          ))}
        </nav>
        <div className="sidebar-footer">
          <span className="local-indicator" /> Your words stay yours.
          <p>
            Personal vocabulary lives on this device. Cloud processing is your
            choice.
          </p>
          <span className="version">Murmur · Preview</span>
        </div>
      </aside>
      <main id="main" className="main-content" tabIndex={-1}>
        {page !== "dictation" && globalError && (
          <div role="alert" className="notice error">
            <p>{globalError}</p>
            <button
              className="text-button"
              onClick={() => {
                setPage("dictation");
                setGlobalError("");
              }}
            >
              Open dictation recovery
            </button>
            <button className="text-button" onClick={() => setGlobalError("")}>
              Dismiss
            </button>
          </div>
        )}
        <div hidden={page !== "dictation"}>
          <Recorder />
          <HistoryList />
        </div>
        {page === "words" && <Vocabulary />}
        {page === "settings" && (
          <section>
            <div className="page-heading">
              <div>
                <p className="eyebrow">Make yourself at home</p>
                <h1>A setup that suits you.</h1>
                <p>Choose where your words are processed and how you record.</p>
              </div>
            </div>
            <div className="card settings-card">
              <EngineSettings />
            </div>
            <div className="card settings-card">
              <HotkeySetting />
              <RecordingMode />
            </div>
            <div className="card settings-card">
              <h2>Quick correction</h2>
              <p>
                Press <kbd>⌘ / Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>E</kbd>{" "}
                while Murmur is open to edit your latest dictation.
              </p>
              <p>
                Manual recording has no silence cutoff. Take your time, then
                choose Stop recording.
              </p>
            </div>
          </section>
        )}
        <footer className="main-footer">
          Less typing. More of what you mean.
        </footer>
      </main>
    </div>
  );
}
