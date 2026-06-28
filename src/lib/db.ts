import Database from "@tauri-apps/plugin-sql";

let dbPromise: Promise<Database> | null = null;
export function getDb(): Promise<Database> {
  if (!dbPromise) dbPromise = Database.load("sqlite:murmur.db");
  return dbPromise;
}

export interface Transcript {
  id: number; raw_text: string; clean_text: string; app_name: string | null; created_at: string;
}

export async function insertTranscript(raw: string, clean: string, app: string | null) {
  const db = await getDb();
  await db.execute(
    "INSERT INTO transcripts (raw_text, clean_text, app_name) VALUES ($1, $2, $3)",
    [raw, clean, app],
  );
}

export async function listTranscripts(limit = 50): Promise<Transcript[]> {
  const db = await getDb();
  return db.select<Transcript[]>(
    "SELECT * FROM transcripts ORDER BY id DESC LIMIT $1", [limit],
  );
}

export async function deleteTranscript(id: number) {
  const db = await getDb();
  await db.execute("DELETE FROM transcripts WHERE id = $1", [id]);
}
