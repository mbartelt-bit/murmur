import { useEffect, useState } from "react";
import {
  getVocabulary,
  setLearning,
  addWord,
  removeWord,
  resetVocabulary,
  type Vocabulary as Data,
} from "../lib/vocabulary";
export function Vocabulary() {
  const [data, setData] = useState<Data>({ learning: false, terms: [] });
  const [term, setTerm] = useState("");
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [reset, setReset] = useState(false);
  useEffect(() => {
    getVocabulary()
      .then(setData)
      .catch((e) => setError(String(e)));
  }, []);
  const run = async (operation: () => Promise<Data>) => {
    setBusy(true);
    setError("");
    try {
      setData(await operation());
      return true;
    } catch (e) {
      setError(String(e));
      return false;
    } finally {
      setBusy(false);
    }
  };
  const exportWords = () => {
    const blob = new Blob(
      [
        JSON.stringify(
          {
            version: 1,
            terms: data.terms.map((t) => ({
              term: t.term,
              source: t.source,
              observations: Object.keys(t.evidence).length,
              enabled: t.enabled,
            })),
          },
          null,
          2,
        ),
      ],
      { type: "application/json" },
    );
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "murmur-vocabulary.json";
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  return (
    <section aria-labelledby="vocabulary-title">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Made personal</p>
          <h1 id="vocabulary-title">Your words, understood.</h1>
          <p>Names, places, and the things you talk about every day.</p>
        </div>
        <span className="count-badge">{data.terms.length} words</span>
      </div>
      {error && (
        <p role="alert" className="notice error">
          {error}
        </p>
      )}
      <div className="card learning-card">
        <div>
          <h2>Learn from my corrections</h2>
          <p>
            Remember a spelling after you correct it in two different
            dictations. You can remove any word below.
          </p>
        </div>
        <label className="switch-label">
          <input
            type="checkbox"
            checked={data.learning}
            disabled={busy}
            onChange={(e) => run(() => setLearning(e.target.checked))}
          />
          <span>{data.learning ? "Learning on" : "Learning off"}</span>
        </label>
      </div>
      <p className="privacy-note">
        Stored on this device. Relevant words are sent with your audio when you
        choose a cloud transcription engine. Turning learning off stops using
        learned words; your manually added words still work.
      </p>
      <form
        className="card add-word"
        onSubmit={async (e) => {
          e.preventDefault();
          if (await run(() => addWord(term))) setTerm("");
        }}
      >
        <label htmlFor="new-word">Add a name or phrase</label>
        <div className="inline-form">
          <input
            id="new-word"
            className="input"
            value={term}
            maxLength={80}
            onChange={(e) => setTerm(e.target.value)}
            placeholder="For example, Siobhan or Acme Studio"
            required
          />
          <button className="btn btn-primary" disabled={busy || !term.trim()}>
            Add word
          </button>
        </div>
      </form>
      <div className="list-toolbar">
        <label className="search-field">
          {" "}
          <span className="sr-only">Search vocabulary</span>
          <input
            className="input"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search your words…"
          />
        </label>
        <button
          className="btn btn-ghost"
          onClick={exportWords}
          disabled={!data.terms.length}
        >
          Export
        </button>
      </div>
      <ul className="word-list">
        {data.terms
          .filter((t) =>
            t.term.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
          )
          .map((t) => (
            <li key={t.term}>
              <div>
                <strong>{t.term}</strong>
                <span>
                  {t.source === "manual"
                    ? "Added by you"
                    : Object.keys(t.evidence).length >= 2
                      ? "Learned from corrections"
                      : "Learning · one more correction needed"}
                </span>
              </div>
              <button
                className="btn btn-ghost"
                disabled={busy}
                aria-label={`Remove ${t.term}`}
                onClick={() => run(() => removeWord(t.term))}
              >
                Remove
              </button>
            </li>
          ))}
      </ul>
      {!data.terms.length && (
        <div className="empty-state">
          <h2>A little context goes a long way.</h2>
          <p>
            Add a name you use often, or turn on learning and correct a
            dictation to begin.
          </p>
        </div>
      )}
      {!!data.terms.length && (
        <div className="reset-row">
          {reset ? (
            <>
              <span>Remove all saved words and correction evidence?</span>
              <button
                className="btn btn-danger"
                disabled={busy}
                onClick={async () => {
                  await run(resetVocabulary);
                  setReset(false);
                }}
              >
                Remove all words
              </button>
              <button className="btn btn-ghost" onClick={() => setReset(false)}>
                Keep words
              </button>
            </>
          ) : (
            <button className="text-button" onClick={() => setReset(true)}>
              Reset vocabulary
            </button>
          )}
        </div>
      )}
    </section>
  );
}
