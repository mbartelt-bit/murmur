import { useCallback, useEffect, useState } from "react";
import {
  micStatus,
  requestMic,
  accessibilityTrusted,
  openPrivacyPane,
  modelReady,
  downloadModel,
  onModelProgress,
} from "../lib/ipc";

export function Onboarding({ onReady }: { onReady: () => void }) {
  const [mic, setMic] = useState<string>("notDetermined");
  const [ax, setAx] = useState<boolean>(false);
  const [modelOk, setModelOk] = useState<boolean>(false);
  const [modelProgress, setModelProgress] = useState<number | null>(null);
  const [modelDownloading, setModelDownloading] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    const [m, a, mdl] = await Promise.all([
      micStatus(),
      accessibilityTrusted(),
      modelReady(),
    ]);
    setMic(m);
    setAx(a);
    setModelOk(mdl);
    if (m === "authorized" && a && mdl) onReady();
  }, [onReady]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 1500); // re-check after user returns from System Settings
    return () => clearInterval(id);
  }, [refresh]);

  const handleDownloadModel = useCallback(async () => {
    setModelDownloading(true);
    setModelProgress(0);
    const unlisten = await onModelProgress((p) => setModelProgress(p));
    try {
      await downloadModel();
      await refresh();
    } finally {
      unlisten();
      setModelDownloading(false);
    }
  }, [refresh]);

  return (
    <div className="p-8 space-y-6">
      <h1 className="text-xl font-semibold">Welcome to Murmur</h1>
      <Row label="Microphone" ok={mic === "authorized"}>
        {mic !== "authorized" && (
          <button
            onClick={async () => {
              if (mic === "notDetermined") {
                await requestMic();
              } else {
                await openPrivacyPane("mic");
              }
              refresh();
            }}
          >
            Allow microphone
          </button>
        )}
      </Row>
      <Row label="Accessibility (for paste + hotkey)" ok={ax}>
        {!ax && (
          <button onClick={() => openPrivacyPane("accessibility")}>
            Open Accessibility settings
          </button>
        )}
      </Row>
      <Row label="Speech model (base.en, ~142 MB)" ok={modelOk}>
        {!modelOk && !modelDownloading && (
          <button onClick={handleDownloadModel}>Download speech model</button>
        )}
        {!modelOk && modelDownloading && modelProgress !== null && (
          <div className="flex items-center gap-2">
            <div className="w-32 h-2 bg-gray-200 rounded overflow-hidden">
              <div
                className="h-full bg-blue-500 transition-all"
                style={{ width: `${Math.round(modelProgress * 100)}%` }}
              />
            </div>
            <span className="text-sm text-gray-500">
              {Math.round(modelProgress * 100)}%
            </span>
          </div>
        )}
      </Row>
    </div>
  );
}

function Row({
  label,
  ok,
  children,
}: {
  label: string;
  ok: boolean;
  children?: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between border-b py-3">
      <span>
        {ok ? "✓ " : "○ "}
        {label}
      </span>
      {children}
    </div>
  );
}
