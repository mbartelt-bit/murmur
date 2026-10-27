import { useEffect, useState, useCallback } from "react";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import {
  listTranscripts,
  deleteTranscript,
  correctTranscript,
  type Transcript,
} from "../lib/db";
import { learnCorrection } from "../lib/vocabulary";

export function HistoryList() {
  const [rows, setRows] = useState<Transcript[]>([]);
  const [query, setQuery] = useState("");
  const [editing, setEditing] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [deleting, setDeleting] = useState<number | null>(null);
  const refresh = useCallback(async () => {
    try {
      setRows(await listTranscripts(500));
    } catch (e) {
      setError(`Could not load your dictations: ${String(e)}`);
    }
  }, []);
  useEffect(() => {
    refresh();
    // Persisted event avoids racing the HUD's database write; complete supports
    // live recovery even if history persistence fails.
    const un = listen("transcript-saved", refresh);
    const complete = listen("dictation-complete", refresh);
    const edit = () => {
      if (rows[0]) {
        setEditing(rows[0].id);
        setDraft(rows[0].corrected_text ?? rows[0].clean_text);
      }
    };
    window.addEventListener("murmur-correct-last", edit);
    return () => {
      un.then((f) => f());
      complete.then((f) => f());
      window.removeEventListener("murmur-correct-last", edit);
    };
  }, [refresh, rows[0]?.id, rows[0]?.corrected_text, rows[0]?.clean_text]);
  const save = async (r: Transcript, text: string | null) => {
    setBusy(true);
    setError("");
    try {
      await correctTranscript(r.id, text);
      setEditing(null);
      await refresh();
      try {
        await learnCorrection(r.id, r.clean_text, text ?? r.clean_text);
        setStatus(
          text === null
            ? "Correction undone."
            : "Correction saved. Your original transcript is preserved.",
        );
      } catch {
        setError(
          "Your correction was saved, but vocabulary could not be updated. Try saving the correction again.",
        );
      }
    } catch (e) {
      setError(`Could not save the correction: ${String(e)}`);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section aria-labelledby="history-title">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Room to think</p>
          <h1 id="history-title">Your dictations.</h1>
          <p>Pick up a thought. Make a correction. Keep moving.</p>
        </div>
        <span className="count-badge">{rows.length} saved</span>
      </div>
      <div
        role="status"
        aria-live="polite"
        className={status ? "notice" : "sr-only"}
      >
        {status}
      </div>
      {error && (
        <p role="alert" className="notice error">
          {error}
        </p>
      )}
      <label className="search-field">
        <span className="sr-only">Search dictations</span>
        <input
          className="input"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search your recent dictations…"
        />
      </label>
      {rows.length === 0 ? (
        <div className="empty-state">
          <div className="empty-mark" aria-hidden="true">
            ∿
          </div>
          <h2>Your next thought starts here.</h2>
          <p>
            Hold your recording shortcut and speak. Your words will appear here,
            ready to copy or refine.
          </p>
        </div>
      ) : (
        <ul className="transcript-list">
          {rows
            .filter((r) =>
              `${r.corrected_text ?? r.clean_text} ${r.raw_text}`
                .toLocaleLowerCase()
                .includes(query.toLocaleLowerCase()),
            )
            .map((r) => (
              <li className="transcript-card" key={r.id}>
                <div className="transcript-meta">
                  <time>
                    {r.created_at === "now"
                      ? "Just now"
                      : new Date(
                          r.created_at.replace(" ", "T") +
                            (r.created_at.includes("Z") ? "" : "Z"),
                        ).toLocaleString(undefined, {
                          month: "short",
                          day: "numeric",
                          hour: "numeric",
                          minute: "2-digit",
                        })}
                  </time>
                  <span>
                    {r.corrected_text != null
                      ? "Corrected by you"
                      : "Dictation"}
                  </span>
                </div>
                {editing === r.id ? (
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      save(r, draft);
                    }}
                  >
                    <label className="sr-only" htmlFor={`edit-${r.id}`}>
                      Correct dictation
                    </label>
                    <textarea
                      id={`edit-${r.id}`}
                      className="input transcript-editor"
                      value={draft}
                      onChange={(e) => setDraft(e.target.value)}
                      autoFocus
                      maxLength={100000}
                    />
                    <p className="privacy-note">
                      With learning enabled, repeated spelling corrections help
                      Murmur recognize your words.
                    </p>
                    <div className="row-actions">
                      <button
                        className="btn btn-primary"
                        disabled={busy || !draft.trim()}
                      >
                        Save correction
                      </button>
                      <button
                        type="button"
                        className="btn btn-ghost"
                        disabled={busy}
                        onClick={() => setEditing(null)}
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                ) : (
                  <p className="transcript-text">
                    {r.corrected_text ?? r.clean_text}
                  </p>
                )}
                <details>
                  <summary>Original transcript</summary>
                  <p className="original-text">{r.raw_text}</p>
                </details>
                <div className="row-actions">
                  <button
                    className="btn btn-ghost"
                    onClick={async () => {
                      try {
                        await writeText(r.corrected_text ?? r.clean_text);
                        setStatus("Copied to clipboard.");
                      } catch {
                        setError(
                          "Could not copy. Select the text and copy it manually.",
                        );
                      }
                    }}
                  >
                    Copy
                  </button>
                  <button
                    className="btn btn-ghost"
                    onClick={() => {
                      setEditing(r.id);
                      setDraft(r.corrected_text ?? r.clean_text);
                    }}
                  >
                    Correct
                  </button>
                  {r.corrected_text != null && (
                    <button
                      className="btn btn-ghost"
                      disabled={busy}
                      onClick={() => save(r, null)}
                    >
                      Undo correction
                    </button>
                  )}
                  <button
                    className="text-button delete-action"
                    onClick={() => setDeleting(r.id)}
                  >
                    Delete
                  </button>
                </div>
                {deleting === r.id && (
                  <div className="notice">
                    <p>Delete this dictation and its learning evidence?</p>
                    <div className="row-actions">
                      <button
                        className="btn btn-danger"
                        disabled={busy}
                        onClick={async () => {
                          setBusy(true);
                          try {
                            await learnCorrection(
                              r.id,
                              r.clean_text,
                              r.clean_text,
                            );
                            await deleteTranscript(r.id);
                            setDeleting(null);
                            await refresh();
                            setStatus("Dictation deleted.");
                          } catch (e) {
                            setError(String(e));
                          } finally {
                            setBusy(false);
                          }
                        }}
                      >
                        Delete dictation
                      </button>
                      <button
                        className="btn btn-ghost"
                        onClick={() => setDeleting(null)}
                      >
                        Keep it
                      </button>
                    </div>
                  </div>
                )}
              </li>
            ))}
        </ul>
      )}
    </section>
  );
}
