import { useCallback, useEffect, useState } from "react";
import {
  micStatus,
  requestMic,
  accessibilityTrusted,
  openPrivacyPane,
  sttReady,
} from "../lib/ipc";
import { EngineSettings } from "./EngineSettings";

export function Onboarding({ onReady }: { onReady: () => void }) {
  const [mic, setMic] = useState<string>("notDetermined");
  const [ax, setAx] = useState<boolean>(false);
  const [ready, setReady] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    const [m, a, r] = await Promise.all([
      micStatus(),
      accessibilityTrusted(),
      sttReady(),
    ]);
    setMic(m);
    setAx(a);
    setReady(r);
    if (m === "authorized" && a && r) onReady();
  }, [onReady]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 1500); // re-check after user returns from System Settings
    return () => clearInterval(id);
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
      <div className="border-b py-3">
        <div className="flex items-center justify-between mb-3">
          <span>
            {ready ? "✓ " : "○ "}
            Transcription
          </span>
        </div>
        <EngineSettings onChange={refresh} />
      </div>
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
