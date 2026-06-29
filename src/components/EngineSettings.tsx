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
      <div className="px-4 py-3 text-sm opacity-50">Loading engine settings…</div>
    );
  }

  return (
    <div className="space-y-5 px-4 py-3">
      {/* Transcription engine */}
      <section>
        <p className="text-xs font-semibold uppercase tracking-wide opacity-50 mb-2">
          Transcription engine
        </p>
        <div className="space-y-2">
          {STT_OPTIONS.map((opt) => (
            <label
              key={opt.value}
              className="flex items-center gap-2 cursor-pointer text-sm"
            >
              <input
                type="radio"
                name="stt"
                value={opt.value}
                checked={settings.stt === opt.value}
                onChange={() => handleSttChange(opt.value)}
                className="accent-blue-500"
              />
              {opt.label}
            </label>
          ))}
        </div>

        {/* Local model sub-row */}
        {settings.stt === "local" && (
          <div className="mt-3 ml-5 text-sm">
            {localModelReady ? (
              <span className="text-green-600 dark:text-green-400">
                ✓ model ready
              </span>
            ) : modelDownloading ? (
              <div className="flex items-center gap-2">
                <div className="w-32 h-2 bg-gray-200 dark:bg-gray-700 rounded overflow-hidden">
                  <div
                    className="h-full bg-blue-500 transition-all"
                    style={{ width: `${Math.round((modelProgress ?? 0) * 100)}%` }}
                  />
                </div>
                <span className="text-xs opacity-60">
                  {Math.round((modelProgress ?? 0) * 100)}%
                </span>
              </div>
            ) : (
              <button
                onClick={handleDownloadModel}
                className="text-xs underline opacity-70 hover:opacity-100"
              >
                Download model (~142 MB)
              </button>
            )}
          </div>
        )}

        {/* OpenAI key sub-row (shown for STT = openai, or when key might also be needed) */}
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
        <p className="text-xs font-semibold uppercase tracking-wide opacity-50 mb-2">
          Cleanup engine
        </p>
        <div className="space-y-2">
          {CLEANUP_OPTIONS.map((opt) => (
            <label
              key={opt.value}
              className="flex items-center gap-2 cursor-pointer text-sm"
            >
              <input
                type="radio"
                name="cleanup"
                value={opt.value}
                checked={settings.cleanup === opt.value}
                onChange={() => handleCleanupChange(opt.value)}
                className="accent-blue-500"
              />
              {opt.label}
            </label>
          ))}
        </div>
        {(settings.cleanup === "openai" || settings.cleanup === "groq") && (
          <p className="mt-2 ml-5 text-xs opacity-50">
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
    <div className="mt-3 ml-5 space-y-1">
      {keySet ? (
        <div className="flex items-center gap-3 text-sm">
          <span className="text-green-600 dark:text-green-400">
            ✓ {label} key saved
          </span>
          <button
            onClick={onRemove}
            className="text-xs underline opacity-60 hover:opacity-100"
          >
            Remove
          </button>
        </div>
      ) : (
        <div className="flex items-center gap-2">
          <input
            type="password"
            value={input}
            onChange={(e) => onInput(e.target.value)}
            placeholder={`${label} API key`}
            className="text-sm border rounded px-2 py-1 bg-background w-48 font-mono"
          />
          <button
            onClick={onSave}
            disabled={saving || !input.trim()}
            className="text-xs underline opacity-70 hover:opacity-100 disabled:opacity-30"
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      )}
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
