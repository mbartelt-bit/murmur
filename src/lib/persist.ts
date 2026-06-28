import { listen } from "@tauri-apps/api/event";
import { insertTranscript } from "./db";

export async function startDictationPersistence(): Promise<() => void> {
  const unlisten = await listen<{ raw: string; clean: string; app: string | null }>(
    "dictation-complete",
    async (e) => {
      await insertTranscript(e.payload.raw, e.payload.clean, e.payload.app);
    },
  );
  return unlisten;
}
