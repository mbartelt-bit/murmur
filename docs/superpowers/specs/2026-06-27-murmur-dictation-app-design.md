# Murmur — Design Spec

**Date:** 2026-06-27
**Status:** Approved design — ready for implementation planning (M0/M1 first)
**Codename:** Murmur (placeholder; renameable)

## 1. Summary

Murmur is a BYOK, local-first voice dictation app for macOS — a Wispr Flow alternative.
You hold a hotkey, talk, and polished text appears at your cursor in whatever app is
focused. The differentiator is cost and privacy: it runs entirely on-device for free
(Whisper on-device + a small local LLM like Gemma via Ollama), with optional
bring-your-own-key cloud engines for users who want maximum accuracy/speed. The goal is
to match Wispr's functionality, UI/UX, and ease of use without the subscription.

### Non-negotiables
- **Local-first and free by default** — works with zero cloud spend or internet.
- **BYOK cloud optional** — both AI stages can swap to a user-supplied cloud key.
- **No functional compromise vs Wispr** — full feature parity is the v1 target.
- **Product-grade** — intended for distribution (signed, notarized, auto-updating).

## 2. Scope

### In scope (v1 target)
Core dictation plus all four headline features:
1. **Custom dictionary** — user vocabulary so names/jargon/acronyms transcribe correctly.
2. **Dictation history** — searchable log with re-copy; safety net for mis-inserts.
3. **Context-aware tone** — detect focused app, adjust tone/formatting per app.
4. **Voice edit/command mode** — select text in target app, edit it by voice.

### Sequencing (not cuts)
The implementation is sliced so the **first daily-usable build is core dictation alone**
(M1), then the four features layer on in order. Everything above ships; it just ships in
milestones rather than one monolith.

### Out of scope (explicit, for now)
- Windows / Linux (architecture preserves the path; not built in v1).
- Mobile.
- Team/cloud-sync features, accounts, server backend.

## 3. Platform & stack decisions

| Decision | Choice | Rationale |
|---|---|---|
| Platform | macOS first | Fastest to dogfood; cleanest accessibility/insertion story. Windows path preserved. |
| Shell | **Tauri** (Rust core + React/TS UI) | Reuse React/TS strength for all UI; contained Rust native core; tiny notarizable binary (~10–15MB); low idle RAM for an always-on menubar app; real Windows path later. |
| STT engine | Local **whisper.cpp** + BYOK cloud | Free/offline/private default; cloud (OpenAI/Groq/Deepgram) for max accuracy/speed. |
| Cleanup LLM | Local **Gemma/Llama via Ollama** + BYOK cloud | Free/offline default; cloud (Anthropic/OpenAI/Groq) for sharper cleanup. |
| Activation | Hold-to-talk **and** double-tap toggle, auto-insert at cursor | Full Wispr parity. |
| Key storage | macOS **Keychain** | BYOK keys never touch SQLite/disk in plaintext. |
| Local store | SQLite | History, dictionary, settings, per-app tone rules. |

**Note on the fn-key trigger:** Wispr's default "hold fn" needs a low-level CGEventTap
and is the fiddliest native piece. Default to a reliable configurable chord (e.g. hold
⌥Space); offer fn-hold as an opt-in enhancement so M1 isn't blocked on it.

## 4. Architecture

A background macOS menubar (tray) app. Two layers:

- **Native core (Rust):** global hotkey, mic capture, on-device Whisper, text insertion,
  frontmost-app detection, Keychain access.
- **UI (React + TS + Tailwind):** all visible surfaces.

### 4.1 Native core modules (Rust)

| Module | Responsibility | Crate / approach |
|---|---|---|
| `hotkey` | Hold-to-talk + double-tap toggle detection | CGEventTap (core-graphics) for true key-hold; configurable binding |
| `audio` | Capture mic → PCM; stream level meter to HUD | `cpal` |
| `stt` | `SttEngine` trait + impls | local `whisper-rs`; cloud HTTP (OpenAI/Groq/Deepgram) |
| `cleanup` | `CleanupEngine` trait + impls | local Ollama HTTP client; cloud (Anthropic/OpenAI/Groq) |
| `insertion` | Polished text → focused field | save clipboard → set text → simulate ⌘V → restore clipboard |
| `context` | Frontmost app bundle id | NSWorkspace |
| `secrets` | BYOK key storage/retrieval | macOS Keychain (`keyring`) |
| `store` | SQLite persistence | `rusqlite` / tauri-plugin-sql |

**Key abstraction:** `SttEngine` and `CleanupEngine` traits. Local, cloud, and future
providers all implement the same interface; the pipeline is provider-agnostic.

### 4.2 UI surfaces (React)

- **Menubar panel** — status, quick toggle, last few dictations, active-engine indicator.
- **Recording HUD** — small always-on-top borderless window with live waveform + partial
  transcript. The "feel" centerpiece.
- **Settings window** — engine config (local vs cloud per stage, model picker, key entry),
  hotkeys, dictionary editor, history browser, per-app tone rules.
- **Onboarding** — permissions (mic + accessibility), engine selection, local model
  download, test dictation.

## 5. Data flow (one dictation)

1. User holds hotkey → HUD appears, audio capture starts, mic level streams to HUD.
2. (Optional, later) streaming partial STT for live preview.
3. User releases → capture stops → audio buffer → `SttEngine` → **raw transcript**
   (written to history immediately — never lose words).
4. Raw transcript + context (frontmost app, custom dictionary, tone rule) → `CleanupEngine`
   → **polished text**.
5. Insertion: save current clipboard → set clipboard to polished text → simulate ⌘V →
   restore original clipboard.
6. History row updated with final text; HUD fades out.

## 6. AI pipeline detail

- **Cleanup prompt assembly:** system instructions (remove filler, preserve meaning,
  format) + tone preset (from per-app context rule) + custom dictionary (spelling
  hints / replacement map) + voice-command grammar ("new line", "scratch that",
  "make this a list").
- **Dictionary feeds STT too:** whisper `initial_prompt` seeded with user vocab; cloud
  STT prompt param where supported.
- **Voice edit/command mode (M6):** a distinct hotkey captures the current selection in
  the target app (AX or ⌘C), sends selection + spoken instruction to the cleanup LLM,
  and replaces the selection with the result.

## 7. Error handling

- **No mic permission** → onboarding prompt; block dictation with clear CTA.
- **No accessibility permission** → insertion fails gracefully → "copied to clipboard"
  toast + grant CTA.
- **Local model missing** → prompt to download or switch to cloud.
- **Ollama not running/installed** → detect; offer to install/start, or fall back to
  cloud / skip-cleanup.
- **Cloud key invalid / offline** → toast; fall back to local if configured, else deliver
  the raw transcript.
- **Empty/garbled STT** → keep raw in history, insert nothing (never silently insert
  wrong text).
- **Crash safety** → raw transcript always written to history before insertion.

## 8. Milestones (each = its own spec → plan → build)

- **M0 — Skeleton & permissions:** Tauri tray app, settings shell, mic + accessibility
  permission flow, Keychain wiring, SQLite bootstrap.
- **M1 — Core dictation (local-only):** hotkey (hold + toggle) → `cpal` capture →
  whisper.cpp → light rule-based cleanup → clipboard-paste insertion → HUD overlay →
  history write. **← first daily-usable build.**
- **M2 — Engines & BYOK:** engine trait abstraction; cloud STT + cloud LLM providers;
  settings to pick/configure each; local model download manager; Ollama/Gemma cleanup.
- **M3 — Custom dictionary** (feeds STT + cleanup).
- **M4 — Dictation history UI** (search, re-copy, delete).
- **M5 — Context-aware tone** (per-app rules).
- **M6 — Voice edit/command mode.**
- **M7 — Product polish:** onboarding, code signing + notarization, auto-update
  (tauri-updater / Sparkle), licensing hook.

This spec covers the full product architecture plus M0/M1 in depth. Later milestones are
described at lower resolution and will each be expanded into their own spec when reached.

## 9. Testing strategy

- **Rust unit tests** per engine trait, prompt assembly, dictionary replacement, and
  clipboard save/restore logic.
- **Mock engines** (`SttEngine`/`CleanupEngine`) for deterministic pipeline tests.
- **React component tests** (Vitest + RTL) for settings, history, onboarding.
- **Manual E2E checklist** per milestone — real dictation into Notes, Slack, VS Code.

## 10. Open questions / deferred

- Final product name (Murmur is a placeholder).
- Default local Whisper model size vs. download size tradeoff (decide in M1/M2).
- Licensing/monetization model (decide before M7).
- Whether to bundle a default Whisper model or download on first run (decide in M2).
