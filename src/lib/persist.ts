import { emit, listen } from "@tauri-apps/api/event";
import { insertTranscript } from "./db";

export async function startDictationPersistence(): Promise<() => void> {
  const unlisten = await listen<{
    raw: string;
    clean: string;
    app: string | null;
  }>("dictation-complete", async (e) => {
    try {
      await insertTranscript(e.payload.raw, e.payload.clean, e.payload.app);
      await emit("transcript-saved");
    } catch {
      await emit(
        "dictation-error",
        "Could not save history. Copy your latest text before closing Murmur.",
      );
    }
  });
  return unlisten;
}
