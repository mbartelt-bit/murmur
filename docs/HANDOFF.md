# Murmur — Session Handoff

**Last updated:** main @ `274d61a` · pushed to https://github.com/mbartelt-bit/murmur (private)
**Platform:** macOS-first. Tauri v2 (Rust core) + React/TS (Vite). Local-first, BYOK cloud optional.

---

## What Murmur is
A macOS menubar voice-dictation app (a Wispr Flow alternative). Hold a hotkey, speak, and it
transcribes (local Whisper **or** cloud), cleans the text up, and pastes it at your cursor. No Dock
icon — it lives in the menubar. Secrets (API keys) live in the macOS Keychain; history in local SQLite.

## ⭐ The single most important next step
**Nobody has run a real end-to-end dictation on-device yet.** Everything below is reviewed +
test-green but the live path is unverified. Before building more, the highest-value action is:
launch it, complete onboarding (grant mic + accessibility, connect a Groq/Local engine), and
**hold the hotkey + speak into TextEdit** to confirm transcribe→clean→paste actually works.
Whatever friction shows up there is the real backlog.

## Run it (dev)
```bash
cd ~/murmur
npm run tauri dev          # compiles + launches; look for the menubar icon (no Dock icon)
```
- **Port 1420 already in use?** A previous dev server is still running. Free it:
  `lsof -ti tcp:1420 | xargs kill -9` (also `pkill -f target/debug/murmur` to kill a stray app instance), then re-run.
- After merging changes, **restart `tauri dev`** to be sure Rust changes load.
- Stop it: Ctrl+C in the terminal, or Quit from the menubar menu.
- **Do NOT** run `tauri dev` from inside an automated/agent context — it's a long-running GUI process.

## Tests / build (what CI-equivalent looks like)
```bash
cd src-tauri && . "$HOME/.cargo/env" && cargo test   # Rust: 38 tests
cd ~/murmur && npx vitest run                          # JS: 24 tests (7 files)
cd ~/murmur && npm run build                           # tsc + vite, builds index.html + hud.html
cd src-tauri && cargo build                            # confirms native compile
```
All green as of `274d61a`. `cmake` is a host prereq (installed via brew) for the whisper.cpp build.

---

## Status by milestone
- **M0 (skeleton):** Tauri menubar (accessory/no-dock), tray, SQLite + settings store, Keychain
  secrets, mic + accessibility onboarding gate. ✅
- **M1 (core dictation):** cpal capture → 16kHz resample → local Whisper (whisper-rs, Metal) →
  rule cleanup → clipboard-paste insertion; recording HUD; hold + double-tap hotkey; end-to-end
  pipeline; history persistence. ✅
- **Configurable hotkey:** record any modifier+key combo in Settings, persisted, live re-register.
  Default `⌃⌥D`. ✅ (Bare single-key like Right Control/fn is NOT supported — needs an event tap, deferred.)
- **M2 (BYOK cloud engines):** OpenAI + Groq (OpenAI-compatible) cloud STT + cloud LLM cleanup
  behind the `SttEngine`/`CleanupEngine` traits; engine picker + key storage; onboarding accepts a
  cloud key in place of the local model. ✅
- **UI:** Tailwind v4 set up (it was never installed before — screens were unstyled), macOS-native
  design, auto light/dark, indigo accent. ✅
- **Guided Connect + cheapest-path:** "Get your API key ↗" opens the provider page, live key
  validation (`verify_provider` → ✓ Connected), per-provider signup steps, cost badges, "Free" tags
  on Local/Groq. ✅

## Cost reality (for users + steering)
- **Local** = $0, offline, no signup (model already downloaded). Default engine.
- **Groq** = FREE tier, Google/GitHub sign-in, **no credit card**. Cheapest cloud path.
- **OpenAI** = pay-as-you-go (~$0.006/min, pennies) BUT requires ~$5 prepaid credit + a card.
- Consumer subscriptions (ChatGPT Plus, Claude Pro) **cannot** power the API — different billing rail.

---

## Architecture / where things live

### Rust (`src-tauri/src/`)
- `lib.rs` — builder: plugins (sql, store, clipboard-manager, global-shortcut), single
  `invoke_handler` (~17 commands), `.setup` (tray + accessory policy), `pipeline::init` at end.
- `main.rs` — calls `murmur_lib::run()`.
- `pipeline.rs` — **the orchestrator.** `PttSink` impl; `start()` spawns a dedicated audio thread
  (cpal `Stream` is `!Send` on macOS — it MUST stay confined to that thread; `Session` holds only
  mpsc channel endpoints). `stop()` spawns a worker that: recv samples → `stt::make_engine(app)` →
  `cleanup::make_engine(app)` → emit `dictation-complete` → insert (or `dictation-empty`) → HUD idle.
  `init(app)` builds the Pipeline + `hotkey::register`.
- `audio.rs` — `start_capture()->Capture` (cpal), `rms/peak/stereo_to_mono` helpers.
- `resample.rs` — `resample_linear(&[f32], in, out)`.
- `stt/` — `mod.rs` (trait `SttEngine` + `make_engine(app)` factory reading store choice + Keychain
  key), `local.rs` (whisper-rs Metal), `cloud.rs` (`CloudStt`, OpenAI-compatible /audio/transcriptions).
- `cleanup/` — `mod.rs` (trait + `make_engine`), `rules.rs` (`RuleCleanup`), `cloud.rs`
  (`CloudCleanup` via /chat/completions; **falls back to RuleCleanup on any error** so words are never lost).
- `insert.rs` — `insert_text`: save clipboard → set → synthetic ⌘V (enigo) → sleep → restore.
- `hotkey.rs` — `DoubleTap` state machine (hold vs double-tap-toggle), `register`, `get_hotkey`/
  `set_hotkey` commands; `Hotkeys { current: Mutex<Shortcut>, tap: Mutex<DoubleTap> }` managed state.
- `model.rs` — `model_path`, `model_ready`, `download_model` (142MB ggml base.en from HF, streamed).
- `secrets.rs` — Keychain via `keyring` v3; `secret_set/get/delete` commands + `pub fn get/set/delete`.
- `permissions.rs` — mic (AVFoundation objc2), accessibility trust, `open_privacy_pane`, `open_url`
  (https-guarded). `request_mic` uses spawn_blocking (RcBlock scoped to drop before await).
- `provider.rs` — `Provider{OpenAI,Groq}`: base_url, stt_model, chat_model, key_account.
- `wav.rs` — `wav_from_f32_mono` (f32→PCM16 WAV) for cloud STT upload.
- `engines.rs` — `get_engine_settings`, `set_stt_engine`, `set_cleanup_engine`, `stt_ready`,
  `verify_provider` (pings {base}/models with the stored key).
- `windows.rs` — `show_hud`/`hide_hud`.

### React (`src/`)
- `main.tsx` — settings entry; imports `index.css` (Tailwind). `hud.tsx` — separate transparent HUD
  entry (do NOT import settings CSS here; `hud.html` stays `background:transparent`).
- `App.tsx` — gates on onboarding `ready`, then renders `<EngineSettings/> <HotkeySetting/> <HistoryList/>`.
- `components/` — `Onboarding.tsx` (gates on mic && ax && `stt_ready`), `EngineSettings.tsx`
  (engine pickers + guided Connect + key mgmt + cost badges), `HotkeySetting.tsx` (record combo),
  `HistoryList.tsx` (read-only list + refresh on event), `Hud.tsx` (pill overlay).
- `lib/` — `ipc.ts` (all command/event wrappers), `db.ts` (SQLite via sql plugin), `persist.ts`
  (the **sole** dictation-complete→SQLite writer; runs in the always-alive HUD window).
- `index.css` — design system: CSS vars (light + `prefers-color-scheme: dark`), `.card .seg .input
  .btn-* .kbd .badge-ok .icon-btn`, indigo accent.

### Data / events
- **Tauri events:** `vu-level`(f64), `hud-state`("recording"|"transcribing"|"idle"),
  `dictation-complete`({raw,clean,app}), `dictation-empty`(()), `dictation-error`(String),
  `model-progress`(f64). Rust emits, JS `listen`s — names must match across both sides.
- **Storage:** API keys → Keychain ONLY (accounts `openai_api_key`/`groq_api_key`). Engine choice →
  store `settings.json` keys `stt_engine`/`cleanup_engine` + `hotkey`. Transcripts → SQLite `transcripts`.

---

## Dev process used in prior sessions (subagent-driven)
Work was done via a controller loop: create a feature branch → dispatch an **implementer** subagent
with a precise brief → dispatch an independent **reviewer** subagent against the diff → apply fixes →
merge to `main` → `git push origin main`. Per-task notes/diffs were written under `.superpowers/sdd/`.
This is optional — a fresh session can work directly — but the pattern caught several real bugs
(audio-thread leak, persistence-lifecycle bug, blocking-recv in async command).

## Device gates (ONLY Matt can verify — never automatable headlessly)
- Mic permission prompt; Accessibility grant (required for hotkey + paste); Input Monitoring is NOT
  used (chord hotkey via global-shortcut, no event tap).
- Local model download (142MB) + actual whisper inference.
- Live hold-hotkey → speak → paste into a real app; clipboard restore; double-tap latch.
- Cloud: real key → `verify_provider` ✓; cloud transcription + cleanup quality; `open_url` browser launch.
- Dev builds are ad-hoc signed → macOS may re-prompt for Accessibility/Keychain after rebuilds.

## Known follow-ups / deferred (none blocking)
- **Sign + notarize** the app (it's a dev build; needs Apple Developer cert) — prerequisite to rely on it daily / share it.
- **Launch at login**, real app icon.
- Hotkey: bare single-key (Right Control / fn) push-to-talk → needs a CGEventTap + Input Monitoring permission.
- Add **Claude** as a cleanup provider (Anthropic API; easy next to OpenAI/Groq).
- Hardening: `ready_rx.recv()` in pipeline has no timeout; `insert.rs` Meta-release-on-error is handled
  but worth a Defer guard; consider `zeroize::Zeroizing` for the API key in `verify_provider`/cloud engines.
- a11y: segmented-control keyboard nav lands on the hidden radio input (functional, could be nicer).
- `Provider::id()` + `getSecret` ipc wrapper are dead code; reqwest `charset`/`json` features slightly gratuitous.
- `.superpowers/` is NOT gitignored — SDD reports/diffs are committed (add to `.gitignore` if you want it clean).
- `package.json` name is still `murmur-scaffold`; README is the Tauri scaffold default.

## Roadmap (from the design spec, `docs/superpowers/specs/`)
- **M3** Custom dictionary (names/jargon feeding STT prompt + cleanup) — biggest accuracy lift.
- **M4** Dictation history UI (search, re-copy, pin, export, usage stats).
- **M5** Context-aware tone / per-app rules (formal in Mail, casual in Slack, raw in code).
- Plus: streaming partial transcription, voice formatting commands ("new paragraph"), Windows support,
  auto-update, and (a separate business decision) a hosted/SaaS model so users need no key at all.

## Gotchas (bite-list)
- **cpal `Stream` is `!Send` on macOS** — keep it on its own thread; `Pipeline` must stay `Send+Sync`.
- **Tailwind v4** via `@tailwindcss/vite`; `src/index.css` imported only in `main.tsx`, never the HUD.
- **cmake** required for the whisper.cpp build (`brew install cmake`).
- **keyring pinned to v3** (`apple-native`); v4 renamed the feature.
- Onboarding only completes when `stt_ready` (local model present OR selected cloud provider has a key).
- The cleanup engine always has a local fallback — a cloud failure degrades to rule cleanup, never lost text.
- Verify state/keys are per-provider; key fields render for any provider used by STT **or** cleanup.
