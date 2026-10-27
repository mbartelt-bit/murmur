import { ChatGptConnection } from "./ChatGptConnection";
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

// ── Per-provider metadata ────────────────────────────────────────────────────

interface ProviderInfo {
  keyPage: string;
  costLabel: string;
  costTone: "free" | "paid";
  steps: string[];
}

const PROVIDER_INFO: Record<"openai" | "groq", ProviderInfo> = {
  groq: {
    keyPage: "https://console.groq.com/keys",
    costLabel: "Provider billing applies",
    costTone: "paid",
    steps: [
      "Sign in to your Groq account",
      'Click "Create API Key"',
      "Copy it and paste below",
    ],
  },
  openai: {
    keyPage: "https://platform.openai.com/api-keys",
    costLabel: "Separate API billing",
    costTone: "paid",
    steps: [
      "Check your API billing and usage limits",
      'Click "Create new secret key"',
      "Copy it and paste below",
    ],
  },
};

// ── Segmented control option definitions ────────────────────────────────────

const STT_OPTIONS = [
  { value: "local", label: "Local (on-device Whisper)", free: true },
  { value: "openai", label: "OpenAI", free: false },
  { value: "groq", label: "Groq", free: false },
] as const;

const CLEANUP_OPTIONS = [
  { value: "verbatim", label: "Verbatim", free: true },
  { value: "rule", label: "Local", free: true },
  { value: "chatgpt", label: "ChatGPT", free: false },
  { value: "openai", label: "OpenAI", free: false },
  { value: "groq", label: "Groq", free: false },
] as const;

// Legacy maps kept for compatibility (keys/labels still used in ConnectBlock)
const PROVIDER_KEY_ACCOUNT: Record<string, string> = {
  openai: "openai_api_key",
  groq: "groq_api_key",
};

const PROVIDER_LABEL: Record<string, string> = {
  openai: "OpenAI",
  groq: "Groq",
};

// ── Small cost pill ──────────────────────────────────────────────────────────

function CostBadge({ tone, label }: { tone: "free" | "paid"; label: string }) {
  if (tone === "free") {
    return (
      <span
        className="badge-ok"
        style={{ fontSize: 11, padding: "1px 7px", fontWeight: 500 }}
        aria-label={label}
      >
        {label}
      </span>
    );
  }
  return (
    <span
      style={{
        fontSize: 11,
        padding: "1px 7px",
        fontWeight: 500,
        borderRadius: 999,
        background: "rgba(128,128,128,0.12)",
        color: "var(--text-2)",
        display: "inline-flex",
        alignItems: "center",
      }}
      aria-label={label}
    >
      {label}
    </span>
  );
}

// ── Free dot indicator (inside seg-item label) ───────────────────────────────

function FreeDot() {
  return (
    <span
      aria-hidden="true"
      style={{
        display: "inline-block",
        width: 6,
        height: 6,
        borderRadius: "50%",
        background: "var(--ok)",
        marginLeft: 5,
        verticalAlign: "middle",
        flexShrink: 0,
      }}
    />
  );
}

export function EngineSettings({ onChange }: Props) {
  const [error, setError] = useState("");
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
    refresh().catch((e) => setError(String(e)));
  }, [refresh]);

  const handleSttChange = useCallback(
    async (value: string) => {
      try {
        await setSttEngine(value);
        await refresh();
        onChange?.();
        setError("");
      } catch (e) {
        setError(String(e));
      }
    },
    [refresh, onChange],
  );

  const handleCleanupChange = useCallback(
    async (value: string) => {
      try {
        await setCleanupEngine(value);
        await refresh();
        onChange?.();
        setError("");
      } catch (e) {
        setError(String(e));
      }
    },
    [refresh, onChange],
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
    [setVerifyState],
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
    [openaiInput, groqInput, refresh, onChange, handleVerify, setVerifyState],
  );

  const handleRemoveKey = useCallback(
    async (provider: "openai" | "groq") => {
      const keyName = PROVIDER_KEY_ACCOUNT[provider];
      try {
        await deleteSecret(keyName);
        setVerifyState(provider, "idle");
        await refresh();
        onChange?.();
      } catch (e) {
        setError(String(e));
      }
    },
    [refresh, onChange, setVerifyState],
  );

  const handleDownloadModel = useCallback(async () => {
    setModelDownloading(true);
    setModelProgress(0);
    let unlisten: (() => void) | undefined;
    setError("");
    try {
      unlisten = await onModelProgress((p) => setModelProgress(p));
      await downloadModel();
      await refresh();
      onChange?.();
    } catch (e) {
      setError(
        `The model could not download. Check your connection and try again. ${String(e)}`,
      );
    } finally {
      unlisten?.();
      setModelDownloading(false);
    }
  }, [refresh, onChange]);

  if (!settings) {
    return (
      <div
        style={{
          padding: "12px 0",
          color: "var(--text-2)",
          fontSize: 13,
          opacity: 0.6,
        }}
      >
        {error
          ? `Could not load settings: ${error}`
          : "Loading engine settings…"}
      </div>
    );
  }

  // Compute the set of cloud providers currently IN USE by stt or cleanup.
  // This is the gap fix: if Local STT + OpenAI cleanup, OpenAI key block still shows.
  const cloudProvidersInUse = Array.from(
    new Set(
      [settings.stt, settings.cleanup].filter(
        (v) => v === "openai" || v === "groq",
      ),
    ),
  ) as ("openai" | "groq")[];

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      {error && (
        <p role="alert" className="notice error">
          {error}
        </p>
      )}
      {/* Transcription engine */}
      <section>
        <div className="section-label">Transcription</div>
        {/* Segmented control — radio inputs hidden visually, accessible by role */}
        <div
          className="seg"
          role="radiogroup"
          aria-label="Transcription engine"
        >
          {STT_OPTIONS.map((opt) => (
            <label
              key={opt.value}
              className={`seg-item${settings.stt === opt.value ? " is-sel" : ""}`}
              style={{
                cursor: "pointer",
                display: "inline-flex",
                alignItems: "center",
                gap: 0,
              }}
            >
              <input
                type="radio"
                name="stt"
                value={opt.value}
                checked={settings.stt === opt.value}
                onChange={() => handleSttChange(opt.value)}
                style={{
                  position: "absolute",
                  opacity: 0,
                  width: 0,
                  height: 0,
                  margin: 0,
                }}
                aria-checked={settings.stt === opt.value}
              />
              {opt.label}
              {opt.free && <FreeDot />}
            </label>
          ))}
        </div>

        {/* Free-path steering tip */}
        <p
          style={{
            margin: "6px 0 0",
            fontSize: 12,
            color: "var(--text-2)",
            lineHeight: 1.5,
          }}
        >
          Local works offline after download. OpenAI and Groq send audio to
          their cloud services and use your own API credentials.
        </p>

        {/* Local model sub-row */}
        {settings.stt === "local" && (
          <div
            style={{
              marginTop: 12,
              display: "flex",
              flexDirection: "column",
              gap: 6,
            }}
          >
            {localModelReady ? (
              <span className="badge-ok">
                <svg
                  width="10"
                  height="10"
                  viewBox="0 0 10 10"
                  fill="none"
                  aria-hidden="true"
                >
                  <path
                    d="M2 5l2 2 4-4"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
                Model ready
              </span>
            ) : modelDownloading ? (
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <div className="progress-track" style={{ width: 128 }}>
                  <div
                    className="progress-fill"
                    style={{
                      width: `${Math.round((modelProgress ?? 0) * 100)}%`,
                    }}
                  />
                </div>
                <span style={{ fontSize: 12, color: "var(--text-2)" }}>
                  {Math.round((modelProgress ?? 0) * 100)}%
                </span>
              </div>
            ) : (
              <button
                className="btn btn-primary"
                onClick={handleDownloadModel}
                style={{ alignSelf: "flex-start" }}
              >
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
              style={{
                cursor: "pointer",
                display: "inline-flex",
                alignItems: "center",
                gap: 0,
              }}
            >
              <input
                type="radio"
                name="cleanup"
                value={opt.value}
                checked={settings.cleanup === opt.value}
                onChange={() => handleCleanupChange(opt.value)}
                style={{
                  position: "absolute",
                  opacity: 0,
                  width: 0,
                  height: 0,
                  margin: 0,
                }}
                aria-checked={settings.cleanup === opt.value}
              />
              {opt.label}
              {opt.free && <FreeDot />}
            </label>
          ))}
        </div>
      </section>

      {/* Guided Connect blocks — one per in-use cloud provider */}
      {settings.cleanup === "chatgpt" && (
        <ChatGptConnection onChange={onChange} />
      )}

      {cloudProvidersInUse.map((provider) => (
        <ConnectBlock
          key={provider}
          provider={provider}
          keySet={
            provider === "openai" ? settings.openai_key : settings.groq_key
          }
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
  const info = PROVIDER_INFO[provider];

  return (
    <section
      className="card"
      style={{ display: "flex", flexDirection: "column", gap: 10 }}
    >
      {/* Header row */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 8,
          flexWrap: "wrap",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <div className="section-label" style={{ marginBottom: 0 }}>
            Connect {label}
          </div>
          <CostBadge tone={info.costTone} label={info.costLabel} />
        </div>
        <button
          className="btn btn-ghost"
          style={{ fontSize: 12, padding: "3px 10px" }}
          onClick={() => openUrl(info.keyPage)}
        >
          Get your API key ↗
        </button>
      </div>

      {/* Provider-specific step hint */}
      <ol
        style={{
          margin: 0,
          padding: "0 0 0 16px",
          fontSize: 12,
          color: "var(--text-2)",
          lineHeight: 1.6,
        }}
      >
        {info.steps.map((step, i) => (
          <li key={i}>{step}</li>
        ))}
      </ol>

      {/* Key input or saved state */}
      {keySet ? (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            flexWrap: "wrap",
          }}
        >
          <span className="badge-ok">
            <svg
              width="10"
              height="10"
              viewBox="0 0 10 10"
              fill="none"
              aria-hidden="true"
            >
              <path
                d="M2 5l2 2 4-4"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
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
            aria-label={`${label} API key`}
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
        <p style={{ margin: 0, fontSize: 12, color: "var(--text-2)" }}>
          Verifying…
        </p>
      )}
      {verifyState === "ok" && (
        <span className="badge-ok" style={{ alignSelf: "flex-start" }}>
          <svg
            width="10"
            height="10"
            viewBox="0 0 10 10"
            fill="none"
            aria-hidden="true"
          >
            <path
              d="M2 5l2 2 4-4"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          Connected
        </span>
      )}
      {verifyState !== "idle" &&
        verifyState !== "verifying" &&
        verifyState !== "ok" && (
          <p style={{ margin: 0, fontSize: 12, color: "var(--danger)" }}>
            {verifyState}
          </p>
        )}
    </section>
  );
}
