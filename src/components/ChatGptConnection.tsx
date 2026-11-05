import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "../lib/ipc";

type Account = {
  client_id: string;
  label: string;
  signed_in: boolean;
  plan_enabled: boolean;
  model: string | null;
};
type Connection = {
  active: string | null;
  accounts: Account[];
  signing_in: boolean;
  storage_pending?: boolean;
};
type Model = { slug: string; display_name: string };

/** Text cleanup only. Tokens and authorization URLs never enter this webview. */
export function ChatGptConnection({ onChange }: { onChange?: () => void }) {
  const [connection, setConnection] = useState<Connection | null>(null);
  const [models, setModels] = useState<Model[]>([]);
  const [busy, setBusy] = useState(false);
  const [signingIn, setSigningIn] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const active = connection?.accounts.find(
    (a) => a.client_id === connection.active,
  );
  const refresh = useCallback(async () => {
    const state = await invoke<Connection>("chatgpt_status");
    setConnection(state);
    return state;
  }, []);
  useEffect(() => {
    refresh().catch((e) => setError(String(e)));
  }, [refresh]);

  const run = async (operation: () => Promise<void>) => {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await operation();
      await refresh();
      onChange?.();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };
  const signIn = (clientId: string | null) =>
    run(async () => {
      setSigningIn(true);
      try {
        const state = await invoke<Connection>("chatgpt_sign_in", { clientId });
        setConnection(state);
        setModels([]);
        const account = state.accounts.find(
          (a) => a.client_id === state.active,
        );
        if (account?.plan_enabled) {
          setModels(await invoke<Model[]>("chatgpt_models"));
          setNotice(
            "Connected. Choose a cleanup model below, then select ChatGPT as your cleanup engine.",
          );
        } else {
          setNotice(
            "Signed in. ChatGPT plan usage was not enabled. You can enable it by signing in again.",
          );
        }
      } finally {
        setSigningIn(false);
      }
    });

  return (
    <section aria-labelledby="chatgpt-title" className="chatgpt-connection">
      <div className="section-label" id="chatgpt-title">
        ChatGPT connection <span className="badge">Experimental</span>
      </div>
      <p>
        Use your eligible ChatGPT plan to polish dictated text. Speech
        recognition stays with your chosen transcription engine.
      </p>
      <p className="muted">
        With ChatGPT cleanup enabled, your transcript is sent to OpenAI. This
        connection does not provide audio transcription or access your ChatGPT
        conversations.
      </p>
      {connection && connection.accounts.length > 0 && (
        <div className="field">
          <label htmlFor="chatgpt-account">ChatGPT account</label>
          <select
            id="chatgpt-account"
            className="input"
            value={connection.active ?? ""}
            disabled={busy}
            onChange={(e) => {
              const clientId = e.target.value;
              run(async () => {
                const state = await invoke<Connection>(
                  "chatgpt_select_account",
                  { clientId },
                );
                setConnection(state);
                setModels([]);
              });
            }}
          >
            {!connection.active && <option value="">Choose an account</option>}
            {connection.accounts.map((a) => (
              <option key={a.client_id} value={a.client_id}>
                {a.label}
                {a.signed_in ? "" : " (signed out)"}
              </option>
            ))}
          </select>
        </div>
      )}
      <div
        className="button-row"
        style={{ display: "flex", flexWrap: "wrap", gap: 8 }}
      >
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => signIn(active?.client_id ?? null)}
        >
          {signingIn ? "Waiting for browser…" : "Continue with ChatGPT"}
        </button>
        {active && (
          <button
            type="button"
            className="btn btn-ghost"
            disabled={busy}
            onClick={() => signIn(null)}
          >
            Add another account
          </button>
        )}
        {active?.signed_in && (
          <button
            type="button"
            className="btn btn-ghost"
            disabled={busy}
            onClick={() =>
              run(async () => {
                setNotice(
                  await invoke<string>("chatgpt_sign_out", {
                    clientId: active.client_id,
                  }),
                );
                setModels([]);
              })
            }
          >
            Sign out
          </button>
        )}
        {signingIn && (
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() => {
              invoke("chatgpt_cancel_sign_in").catch((e) =>
                setError(String(e)),
              );
            }}
          >
            Cancel sign-in
          </button>
        )}
      </div>
      {active?.signed_in && active.plan_enabled && (
        <div className="field" style={{ marginTop: 16 }}>
          <label htmlFor="chatgpt-model">Cleanup model</label>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            <select
              id="chatgpt-model"
              className="input"
              disabled={busy || models.length === 0}
              value={active.model ?? ""}
              onChange={(e) => {
                const model = e.target.value;
                run(async () => {
                  await invoke("chatgpt_select_model", { model });
                  setNotice("Cleanup model saved.");
                });
              }}
            >
              <option value="">Choose a model</option>
              {active.model && !models.some((m) => m.slug === active.model) && (
                <option value={active.model}>{active.model}</option>
              )}
              {models.map((m) => (
                <option value={m.slug} key={m.slug}>
                  {m.display_name}
                </option>
              ))}
            </select>
            <button
              type="button"
              className="btn btn-ghost"
              disabled={busy}
              onClick={() =>
                run(async () => {
                  setModels(await invoke<Model[]>("chatgpt_models"));
                })
              }
            >
              Load available models
            </button>
          </div>
        </div>
      )}
      <p>
        <button
          type="button"
          className="btn btn-ghost"
          onClick={() =>
            openUrl("https://chatgpt.com/settings/usage").catch((e) =>
              setError(String(e)),
            )
          }
        >
          Manage ChatGPT usage and access ↗
        </button>
      </p>
      {connection?.storage_pending && (
        <p role="alert">
          Credential storage needs attention. Keep Murmur open, unlock your
          system credential store, and retry. If you restart, you may need to
          sign in again.
        </p>
      )}
      {notice && <p role="status">{notice}</p>}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
