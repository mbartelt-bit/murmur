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
  openUrl,
  verifyProvider,
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

const PROVIDER_KEY_PAGE: Record<string, string> = {
  openai: "https://platform.openai.com/api-keys",
  groq: "https://console.groq.com/keys",
};

const PROVIDER_KEY_ACCOUNT: Record<string, string> = {
  openai: "openai_api_key",
  groq: "groq_api_key",
};

const PROVIDER_LABEL: Record<string, string> = {
  openai: "OpenAI",
  groq: "Groq",
};

export function EngineSettings({ onChange }: Props) {
  const [settings, setSettings] = useState<EngineSettingsData | null>(null);
  const [localModelReady, setLocalModelReady] = useState(false);
  const [modelDownloading, setModelDownloading] = useState(false);
  const [modelProgress, setModelProgress] = useState<number | null>(null);

  // Per-provider key input state
  const [openaiInput, setOpenaiInput] = useState("");
  const [groqInput, setGroqInput] = useState("");
  const [savingKey, setSavingKey] = useState<string | null>(null);

  // Per-provider verify state: "idle" | "verifying" | "ok" | error message
  const [openaiVerify, setOpenaiVerify] = useState<string>("idle");
  const [groqVerify, setGroqVerify] = useState<string>("idle");

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

  const setVerifyState = useCallback((provider: string, state: string) => {
    if (provider === "openai") setOpenaiVerify(state);
    else setGroqVerify(state);
  }, []);

  const handleVerify = useCallback(
    async (provider: string) => {
      setVerifyState(provider, "verifying");
      try {
        await verifyProvider(provider);
        setVerifyState(provider, "ok");
      } catch (e) {
        setVerifyState(provider, e instanceof Error ? e.message : String(e));
      }
    },
    [setVerifyState]
  );

  const handleSaveKey = useCallback(
    async (provider: "openai" | "groq") => {
      const keyName = PROVIDER_KEY_ACCOUNT[provider];
      const keyValue = provider === "openai" ? openaiInput : groqInput;
      if (!keyValue.trim()) return;
      setSavingKey(provider);
      setVerifyState(provider, "idle");
      try {
        await setSecret(keyName, keyValue.trim());
        if (provider === "openai") setOpenaiInput("");
        else setGroqInput("");
        await refresh();
        onChange?.();
        // Auto-verify after saving so user gets immediate feedback
        await handleVerify(provider);
      } catch (e) {
        setVerifyState(provider, e instanceof Error ? e.message : String(e));
      } finally {
        setSavingKey(null);
      }
    },
    [openaiInput, groqInput, refresh, onChange, handleVerify, setVerifyState]
  );

  const handleRemoveKey = useCallback(
    async (provider: "openai" | "groq") => {
      const keyName = PROVIDER_KEY_ACCOUNT[provider];
      await deleteSecret(keyName);
      setVerifyState(provider, "idle");
      await refresh();
      onChange?.();
    },
    [refresh, onChange, setVerifyState]
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

  // Compute the set of cloud providers currently IN USE by stt or cleanup.
  // This is the gap fix: if Local STT + OpenAI cleanup, OpenAI key block still shows.
  const cloudProvidersInUse = Array.from(
    new Set(
      [settings.stt, settings.cleanup].filter((v) => v === "openai" || v === "groq")
    )
  ) as ("openai" | "groq")[];

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
      </section>

      {/* Guided Connect blocks — one per in-use cloud provider */}
      {cloudProvidersInUse.map((provider) => (
        <ConnectBlock
          key={provider}
          provider={provider}
          keySet={provider === "openai" ? settings.openai_key : settings.groq_key}
          input={provider === "openai" ? openaiInput : groqInput}
          onInput={provider === "openai" ? setOpenaiInput : setGroqInput}
          onSave={() => handleSaveKey(provider)}
          onRemove={() => handleRemoveKey(provider)}
          onVerify={() => handleVerify(provider)}
          saving={savingKey === provider}
          verifyState={provider === "openai" ? openaiVerify : groqVerify}
        />
      ))}
    </div>
  );
}

// ── Guided Connect block ──────────────────────────────────────────────────────

interface ConnectBlockProps {
  provider: "openai" | "groq";
  keySet: boolean;
  input: string;
  onInput: (v: string) => void;
  onSave: () => void;
  onRemove: () => void;
  onVerify: () => void;
  saving: boolean;
  verifyState: string; // "idle" | "verifying" | "ok" | error message
}

function ConnectBlock({
  provider,
  keySet,
  input,
  onInput,
  onSave,
  onRemove,
  onVerify,
  saving,
  verifyState,
}: ConnectBlockProps) {
  const label = PROVIDER_LABEL[provider];
  const keyPage = PROVIDER_KEY_PAGE[provider];

  return (
    <section className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      {/* Header row */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div className="section-label" style={{ marginBottom: 0 }}>Connect {label}</div>
        <button
          className="btn btn-ghost"
          style={{ fontSize: 12, padding: "3px 10px" }}
          onClick={() => openUrl(keyPage)}
        >
          Get your API key ↗
        </button>
      </div>

      {/* Inline step hint */}
      <p style={{ margin: 0, fontSize: 12, color: "var(--text-2)", lineHeight: 1.5 }}>
        1. Create a key &nbsp;&nbsp;2. Copy it &nbsp;&nbsp;3. Paste below
      </p>

      {/* Key input or saved state */}
      {keySet ? (
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <span className="badge-ok">
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
              <path d="M2 5l2 2 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            Key saved
          </span>
          <button
            className="btn btn-ghost"
            style={{ fontSize: 12, padding: "3px 10px" }}
            onClick={onVerify}
            disabled={verifyState === "verifying"}
          >
            Verify
          </button>
          <button
            className="btn btn-ghost"
            style={{ fontSize: 12, padding: "3px 10px" }}
            onClick={onRemove}
          >
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
            {saving ? "Connecting…" : "Connect"}
          </button>
        </div>
      )}

      {/* Verify status line */}
      {verifyState === "verifying" && (
        <p style={{ margin: 0, fontSize: 12, color: "var(--text-2)" }}>Verifying…</p>
      )}
      {verifyState === "ok" && (
        <span className="badge-ok" style={{ alignSelf: "flex-start" }}>
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
            <path d="M2 5l2 2 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          Connected
        </span>
      )}
      {verifyState !== "idle" && verifyState !== "verifying" && verifyState !== "ok" && (
        <p style={{ margin: 0, fontSize: 12, color: "var(--danger)" }}>{verifyState}</p>
      )}
    </section>
  );
}
