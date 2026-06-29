import { useCallback, useEffect, useState } from "react";
import {
  getEngineSettings,
  setSttEngine,
  setCleanupEngine,
  setSecret,
  deleteSecret,
  downloadModel,
  onModelProgress,
  modelReady,
  type EngineSettings as EngineSettingsData,
} from "../lib/ipc";

interface Props {
  onChange?: () => void;
}

const STT_OPTIONS = [
  { value: "local", label: "Local (on-device Whisper)" },
  { value: "openai", label: "OpenAI" },
  { value: "groq", label: "Groq" },
] as const;

const CLEANUP_OPTIONS = [
  { value: "rule", label: "Rule-based (local, free)" },
  { value: "openai", label: "OpenAI" },
  { value: "groq", label: "Groq" },
] as const;

export function EngineSettings({ onChange }: Props) {
  const [settings, setSettings] = useState<EngineSettingsData | null>(null);
  const [localModelReady, setLocalModelReady] = useState(false);
  const [modelDownloading, setModelDownloading] = useState(false);
  const [modelProgress, setModelProgress] = useState<number | null>(null);

  // Per-provider key input state
  const [openaiInput, setOpenaiInput] = useState("");
  const [groqInput, setGroqInput] = useState("");
  const [savingKey, setSavingKey] = useState<string | null>(null);
  const [keyError, setKeyError] = useState<string | null>(null);

  // refresh re-reads state only; it must NOT call onChange (that would fire on
  // mount and feed back into onboarding's readiness poll). onChange fires only
  // after an actual user mutation, below.
  const refresh = useCallback(async () => {
    const [s, mdl] = await Promise.all([getEngineSettings(), modelReady()]);
    setSettings(s);
    setLocalModelReady(mdl);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const handleSttChange = useCallback(
    async (value: string) => {
      setKeyError(null); // clear any stale key error when switching provider
      await setSttEngine(value);
      await refresh();
      onChange?.();
    },
    [refresh, onChange]
  );

  const handleCleanupChange = useCallback(
    async (value: string) => {
      await setCleanupEngine(value);
      await refresh();
      onChange?.();
    },
    [refresh, onChange]
  );

  const handleSaveKey = useCallback(
    async (provider: "openai" | "groq") => {
      const keyName = provider === "openai" ? "openai_api_key" : "groq_api_key";
      const keyValue = provider === "openai" ? openaiInput : groqInput;
      if (!keyValue.trim()) return;
      setSavingKey(provider);
      setKeyError(null);
      try {
        await setSecret(keyName, keyValue.trim());
        if (provider === "openai") setOpenaiInput("");
        else setGroqInput("");
        await refresh();
        onChange?.();
      } catch (e) {
        setKeyError(e instanceof Error ? e.message : String(e));
      } finally {
        setSavingKey(null);
      }
    },
    [openaiInput, groqInput, refresh, onChange]
  );

  const handleRemoveKey = useCallback(
    async (provider: "openai" | "groq") => {
      const keyName = provider === "openai" ? "openai_api_key" : "groq_api_key";
      await deleteSecret(keyName);
      await refresh();
      onChange?.();
    },
    [refresh, onChange]
  );

  const handleDownloadModel = useCallback(async () => {
    setModelDownloading(true);
    setModelProgress(0);
    const unlisten = await onModelProgress((p) => setModelProgress(p));
    try {
      await downloadModel();
      await refresh();
      onChange?.();
    } finally {
      unlisten();
      setModelDownloading(false);
    }
  }, [refresh, onChange]);

  if (!settings) {
    return (
      <div style={{ padding: "12px 0", color: "var(--text-2)", fontSize: 13, opacity: 0.6 }}>
        Loading engine settings…
      </div>
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      {/* Transcription engine */}
      <section>
        <div className="section-label">Transcription</div>
        {/* Segmented control — radio inputs hidden visually, accessible by role */}
        <div className="seg" role="radiogroup" aria-label="Transcription engine">
          {STT_OPTIONS.map((opt) => (
            <label
              key={opt.value}
              className={`seg-item${settings.stt === opt.value ? " is-sel" : ""}`}
              style={{ cursor: "pointer" }}
            >
              <input
                type="radio"
                name="stt"
                value={opt.value}
                checked={settings.stt === opt.value}
                onChange={() => handleSttChange(opt.value)}
                style={{ position: "absolute", opacity: 0, width: 0, height: 0, margin: 0 }}
                aria-checked={settings.stt === opt.value}
              />
              {opt.label}
            </label>
          ))}
        </div>

        {/* Local model sub-row */}
        {settings.stt === "local" && (
          <div style={{ marginTop: 12, display: "flex", flexDirection: "column", gap: 6 }}>
            {localModelReady ? (
              <span className="badge-ok">
                <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
                  <path d="M2 5l2 2 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
                Model ready
              </span>
            ) : modelDownloading ? (
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <div className="progress-track" style={{ width: 128 }}>
                  <div
                    className="progress-fill"
                    style={{ width: `${Math.round((modelProgress ?? 0) * 100)}%` }}
                  />
                </div>
                <span style={{ fontSize: 12, color: "var(--text-2)" }}>
                  {Math.round((modelProgress ?? 0) * 100)}%
                </span>
              </div>
            ) : (
              <button className="btn btn-primary" onClick={handleDownloadModel} style={{ alignSelf: "flex-start" }}>
                Download model (~142 MB)
              </button>
            )}
          </div>
        )}

        {/* OpenAI key sub-row */}
        {settings.stt === "openai" && (
          <KeyRow
            provider="openai"
            keySet={settings.openai_key}
            input={openaiInput}
            onInput={setOpenaiInput}
            onSave={() => handleSaveKey("openai")}
            onRemove={() => handleRemoveKey("openai")}
            saving={savingKey === "openai"}
            error={keyError}
          />
        )}

        {/* Groq key sub-row */}
        {settings.stt === "groq" && (
          <KeyRow
            provider="groq"
            keySet={settings.groq_key}
            input={groqInput}
            onInput={setGroqInput}
            onSave={() => handleSaveKey("groq")}
            onRemove={() => handleRemoveKey("groq")}
            saving={savingKey === "groq"}
            error={keyError}
          />
        )}
      </section>

      {/* Cleanup engine */}
      <section>
        <div className="section-label">Cleanup</div>
        <div className="seg" role="radiogroup" aria-label="Cleanup engine">
          {CLEANUP_OPTIONS.map((opt) => (
            <label
              key={opt.value}
              className={`seg-item${settings.cleanup === opt.value ? " is-sel" : ""}`}
              style={{ cursor: "pointer" }}
            >
              <input
                type="radio"
                name="cleanup"
                value={opt.value}
                checked={settings.cleanup === opt.value}
                onChange={() => handleCleanupChange(opt.value)}
                style={{ position: "absolute", opacity: 0, width: 0, height: 0, margin: 0 }}
                aria-checked={settings.cleanup === opt.value}
              />
              {opt.label}
            </label>
          ))}
        </div>
        {(settings.cleanup === "openai" || settings.cleanup === "groq") && (
          <p style={{ marginTop: 8, fontSize: 12, color: "var(--text-2)" }}>
            Cleanup uses the same API key as the matching transcription provider.
            If the key is missing, cleanup falls back to rule-based.
          </p>
        )}
      </section>
    </div>
  );
}

// ── Internal sub-component ────────────────────────────────────────────────────

interface KeyRowProps {
  provider: "openai" | "groq";
  keySet: boolean;
  input: string;
  onInput: (v: string) => void;
  onSave: () => void;
  onRemove: () => void;
  saving: boolean;
  error: string | null;
}

function KeyRow({
  provider,
  keySet,
  input,
  onInput,
  onSave,
  onRemove,
  saving,
  error,
}: KeyRowProps) {
  const label = provider === "openai" ? "OpenAI" : "Groq";
  return (
    <div style={{ marginTop: 12, display: "flex", flexDirection: "column", gap: 6 }}>
      {keySet ? (
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span className="badge-ok">
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
              <path d="M2 5l2 2 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            {label} key saved
          </span>
          <button className="btn btn-ghost" onClick={onRemove} style={{ padding: "3px 10px", fontSize: 12 }}>
            Remove
          </button>
        </div>
      ) : (
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <input
            type="password"
            value={input}
            onChange={(e) => onInput(e.target.value)}
            placeholder={`${label} API key`}
            className="input"
            style={{ fontFamily: "monospace", maxWidth: 220 }}
          />
          <button
            className="btn btn-primary"
            onClick={onSave}
            disabled={saving || !input.trim()}
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      )}
      {error && (
        <p style={{ fontSize: 12, color: "var(--danger)", margin: 0 }}>{error}</p>
      )}
    </div>
  );
}
