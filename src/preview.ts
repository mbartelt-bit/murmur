// Development-only UI fixture. No microphone, account or provider calls.
import { mockIPC } from "@tauri-apps/api/mocks";
export function installPreview() {
  let settings = {
    stt: "local",
    cleanup: "rule",
    openai_key: false,
    groq_key: false,
  };
  let vocabulary = {
    learning: true,
    terms: [
      { term: "Siobhan", source: "manual", enabled: true, evidence: {} },
      {
        term: "Murmur",
        source: "learned",
        enabled: true,
        evidence: { "1": "murmor", "2": "murmor" },
      },
    ],
  };
  const rows = [
    {
      id: 1,
      raw_text: "send the updated proposal to Siobhan tomorrow morning",
      clean_text: "Send the updated proposal to Siobhan tomorrow morning.",
      corrected_text: null,
      created_at: "2026-10-27 09:42:00",
      app_name: null,
    },
    {
      id: 2,
      raw_text: "a good tool should get out of the way and let you think",
      clean_text: "A good tool should get out of the way and let you think.",
      corrected_text: null,
      created_at: "2026-10-27 09:35:00",
      app_name: null,
    },
  ];
  mockIPC((command, payload) => {
    const args = payload as Record<string, unknown> | undefined;
    switch (command) {
      case "mic_status":
        return "authorized";
      case "accessibility_trusted":
      case "input_monitoring_trusted":
      case "stt_ready":
      case "model_ready":
        return true;
      case "get_hotkey":
        return "Control+Alt+KeyD";
      case "recording_state":
        return "idle";
      case "get_recording_mode":
        return "hold";
      case "get_engine_settings":
        return settings;
      case "set_stt_engine":
        settings = { ...settings, stt: String(args?.value) };
        return;
      case "set_cleanup_engine":
        settings = { ...settings, cleanup: String(args?.value) };
        return;
      case "start_recording":
      case "chatgpt_sign_in":
        throw new Error(
          "This is a UI preview. Use the native app for microphone and account connections.",
        );
      case "get_vocabulary":
        return vocabulary;
      case "set_learning":
        vocabulary = { ...vocabulary, learning: Boolean(args?.enabled) };
        return vocabulary;
      case "add_word":
        vocabulary.terms.push({
          term: String(args?.term),
          source: "manual",
          enabled: true,
          evidence: {},
        });
        return vocabulary;
      case "remove_word":
        vocabulary.terms = vocabulary.terms.filter(
          (t) => t.term !== args?.term,
        );
        return vocabulary;
      case "reset_vocabulary":
        vocabulary.terms = [];
        return vocabulary;
      case "plugin:sql|load":
        return "sqlite:murmur.db";
      case "plugin:sql|select":
        return rows;
      case "plugin:sql|execute":
        return { rowsAffected: 1 };
      case "chatgpt_status":
        return { accounts: [], active: null, signing_in: false };
      default:
        return null;
    }
  });
}
