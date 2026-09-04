# Murmur — Session Handoff

**Last updated:** 2026-09-04 · desktop trunk `3a65eb9` on `main`; mobile MM0 on `feat/mobile-core`
· https://github.com/mbartelt-bit/murmur (private)
**Platform:** macOS-first (Tauri v2 + React/TS), with iOS and Android shells on the shared
`crates/murmur-core`. Local-first, BYOK cloud optional.

> **Read the "Session 2 (2026-07-03)" block below first** — it captures everything since `274d61a`
> (on-device dictation now WORKS, code-signing setup, the mic/hardened-runtime fix, fn-key
> push-to-talk, HUD redesign). Sections farther down predate session 2 and are mostly still accurate
> for architecture, but check the session-2 block for what changed.

> **Mobile work lives in the "Mobile (MM0 landed 2026-09-04)" section directly below.** The Rust
> pipeline now lives in a workspace crate shared by desktop, iOS and Android.

---

## Mobile (MM0 landed 2026-09-04)

iOS and Android app **shells** exist and call the shared Rust core end to end. No dictation UI yet —
MM0 is the plumbing. Read these two first:

- Spec: `docs/superpowers/specs/2026-09-03-murmur-mobile-design.md` (sections 3, 4, 5, 11, 12, 13)
- Plan: `docs/superpowers/plans/2026-09-03-murmur-mobile-mm0.md`
- Per-platform detail: `apple/README.md`, `android/README.md`, `scripts/README.md`

### Worktree convention
Mobile branches are checked out as **git worktrees** at `~/murmur-wt/<branch>` (MM0 was
`~/murmur-wt/mobile-core` on `feat/mobile-core`). `~/murmur` stays on the trunk and often holds
uncommitted desktop work — never build a branch there.

### Verification gate (run all of it before claiming a mobile change works)
```bash
cd ~/murmur-wt/<branch> && . "$HOME/.cargo/env"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"

cargo test --workspace --exclude murmur              # core tests (murmur needs dist/)
npm run build && cargo test --manifest-path src-tauri/Cargo.toml \
              && cargo build --manifest-path src-tauri/Cargo.toml
npx vitest run
scripts/build-core-mobile.sh ios && scripts/build-core-mobile.sh android
xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # simctl list devices available
cd android && ./gradlew assembleDebug testDebugUnitTest
```
`.github/workflows/ci.yml` runs the same thing in a `mobile` job on `macos-latest`.

### Where generated files go (all gitignored — never commit them)
| Path | Produced by |
|---|---|
| `apple/Frameworks/MurmurCore.xcframework` | `scripts/build-core-mobile.sh ios` |
| `apple/MurmurShared/Sources/MurmurCore/Generated/MurmurCore.swift` | same |
| `android/app/src/main/jniLibs/{arm64-v8a,x86_64}/libmurmur_core.so` | `scripts/build-core-mobile.sh android` |
| `android/app/src/main/java/app/murmur/core/murmur_core.kt` | same |
| `target/uniffi/` | intermediates for both |

Committed, by contrast: `apple/project.yml` **and** the generated `apple/Murmur.xcodeproj` (so a
fresh clone builds without XcodeGen), plus the Gradle wrapper.

### Gotchas
- **The xcframework must exist before the FIRST `xcodebuild`.** Xcode resolves the `MurmurCoreFFI`
  binary target *before* any script phase runs, so a clean checkout must run
  `scripts/build-core-mobile.sh ios` by hand once. After that the app target's **Build MurmurCore**
  pre-build phase keeps it fresh — but because the framework is unpacked before that phase, **a Rust
  edit lands in the build *after* the one that rebuilt it.** Just edited `crates/murmur-core`? Build
  twice, or re-run the script by hand.
- **Gradle needs `cargo` on `PATH`.** The `buildRustCore` task shells out to the build script, and
  Gradle (like Xcode) runs with a stripped `PATH` that lacks `~/.cargo/bin`. `. "$HOME/.cargo/env"`
  in the shell you launch `./gradlew` from. Android also needs `cargo-ndk` and NDK `27.2.12479018`.
- **`whisper` is desktop-only.** Both mobile modes build `--no-default-features` on purpose: the
  `whisper` feature drags in cmake + whisper.cpp, which we do not cross-compile for phones. Phones get
  their free local engine from the platform instead (Apple `SpeechAnalyzer`/`SFSpeechRecognizer`,
  Android `SpeechRecognizer`; MM1/MM3), with the same cloud engines optional. Never "fix" a mobile
  build by turning the feature on.
- `murmur-core` holds **no state and no secrets** — no Tauri, no store, no Keychain. Callers pass a
  `CloudConfig` in. Keep it that way; it is what makes the crate shareable across three front ends.

---

## iOS app (MM1 landed 2026-09-04) — branch `feat/mobile-mm1`, PR #3 (stacked on #2)

The iOS containing app is complete on the simulator: onboarding, home, settings, history, and
the native recorder (mic → `SpeechAnalyzer` on iOS 26 / `SFSpeechRecognizer` before that, or
Groq/OpenAI through `murmur-core` → cleanup → history → clipboard + App Group handoff).
131 XCTest cases, all with fakes. Plan: `docs/superpowers/plans/2026-09-04-murmur-mobile-mm1.md`.
Per-file map and the device checklist: `apple/README.md`.

Facts a new session needs:
- **Recording cannot run on the simulator** — `AVAudioEngine.inputNode` aborts in AudioToolbox
  (`AURemoteIO::Initialize`) with no host mic. Unit tests cover the recorder's phases; the
  first real recording is Matt's device checklist.
- **`$(AppIdentifierPrefix)` expands on simulator builds too**, so `Keychain.defaultAccessGroup`
  is `X9PU63GUAN.com.murmur.app` everywhere; the simulator keychain just doesn't enforce it.
- The cloud → on-device retry replays the same audio (`ChunkTape` in `DictationPipeline.swift`)
  — the user never repeats themselves after a network failure.
- `Handoff` (App Group) is the contract the MM2 keyboard consumes: `pending{session}` in,
  `result{session, raw, clean}` out, insert-once, 10-minute expiry.
- What MM2 builds next: the keyboard extension, the Dictate App Intent + Control Center
  button, the onboarding steps for enabling the keyboard, crash-safe recording, and the
  TestFlight script. Plan: `docs/superpowers/plans/2026-09-04-murmur-mobile-mm2.md`.
  Android is MM3: `docs/superpowers/plans/2026-09-04-murmur-mobile-mm3.md`.

---

## What Murmur is
A macOS menubar voice-dictation app (a Wispr Flow alternative). Hold a hotkey, speak, and it
transcribes (local Whisper **or** cloud), cleans the text up, and pastes it at your cursor. No Dock
icon — it lives in the menubar. Secrets (API keys) live in the macOS Keychain; history in local SQLite.

## ⭐ Status: on-device dictation WORKS (verified 2026-07-03)
The live path is proven end-to-end: **mic → hold fn (or ⌃⌥D) → Groq transcribe → cleanup →
paste at cursor**, in a code-signed `.app`. The old "single most important next step" (first real
dictation) is done. The current highest-value next step is **distribution**: Matt is setting up an
Apple Developer account — swap the local self-signed cert for a Developer ID cert, add notarization,
and cut a `.dmg` (see "Next steps" in the session-2 block).

## Run it — build a SIGNED bundle (this is what you want now)
Real testing needs a **signed `.app` bundle**, NOT `tauri dev`. `tauri dev` runs a bare binary that
macOS attributes to the launching terminal (VS Code/Terminal) for TCC, which breaks permission grants
and the fn-key event tap. Build + launch the signed bundle instead:
```bash
cd ~/murmur && . "$HOME/.cargo/env"
APPLE_SIGNING_IDENTITY="Murmur Dev" npm run tauri build -- --debug
open target/debug/bundle/macos/Murmur.app
# quit + relaunch one-liner:
pkill -x murmur; sleep 1; open target/debug/bundle/macos/Murmur.app
```
See the **Session 2** block for why the cert matters and what to do if it's missing. `--debug` reuses
cached whisper objects (fast); drop it for an optimized release build.

## Run it (dev — UI-only, avoid for permission testing)
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
The Rust side is a Cargo **workspace** now (`crates/murmur-core` + `src-tauri`), so build output
lives in `./target/` at the repo root rather than under `src-tauri/`, and every cargo command
runs from the repo root.
```bash
cd ~/murmur && . "$HOME/.cargo/env"
cargo test -p murmur-core                          # Rust core: 30 tests
npm run build                                      # tsc + vite; MUST precede any src-tauri cargo run
cargo test --manifest-path src-tauri/Cargo.toml    # Rust desktop: 20 tests
cargo build --manifest-path src-tauri/Cargo.toml   # confirms native compile
npx vitest run                                     # JS: 24 tests (7 files)
```
Green as of `c0c05fa` (Rust: murmur-core 30 + murmur 20; JS 24 across 7 files). `cmake` is a host
prereq (brew) for whisper.cpp. `tauri::generate_context!` embeds `dist/` at compile time, which is
why `npm run build` comes first. Mobile has its own gate — see the **Mobile** section above.

---

## Session 2 (2026-07-03) — what changed since `274d61a`

On-device dictation went from unverified → **working end-to-end**. New commits on `main`:
`96b7a47` (first working dictation + paste/keychain/onboarding fixes), `823f879` (HUD redesign),
`3a65eb9` (fn-key push-to-talk + hardened-runtime mic fix). Everything below is LIVE + committed.

### Code-signing with a self-signed cert (why grants persist)
- The app is signed with a **local self-signed cert "Murmur Dev"** (SHA-1 `D4C4693D…`, in the login
  keychain). This gives a **stable Designated Requirement**:
  `identifier "com.murmur.app" and certificate leaf = H"d4c4693d84ddef093c14b5b87f89676a2a327b86"`.
  TCC keys accessibility/input-monitoring/mic grants to that DR, so **grants survive rebuilds**.
  Ad-hoc builds get a new cdhash each build → grants reset every time (that pain is gone now).
- Sign by setting `APPLE_SIGNING_IDENTITY="Murmur Dev"` (Tauri reads it). This is NOT committed to
  config on purpose — it's a machine-local identity. Just export it when building.
- The cert does **not** need to be a trusted root (that step is unnecessary and got blocked by the
  agent sandbox — codesign works with it untrusted; TCC only wants a valid, stable signature).
- **If the cert is ever gone** (`security find-identity -p codesigning | grep -i murmur` empty),
  recreate it:
  ```bash
  cat > /tmp/cs.cnf <<'EOF'
  [req]
  distinguished_name = dn
  x509_extensions = ext
  prompt = no
  [dn]
  CN = Murmur Dev
  [ext]
  basicConstraints = critical,CA:false
  keyUsage = critical,digitalSignature
  extendedKeyUsage = critical,codeSigning
  EOF
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/k.pem -out /tmp/c.pem -days 3650 -nodes -config /tmp/cs.cnf
  openssl pkcs12 -export -inkey /tmp/k.pem -in /tmp/c.pem -out /tmp/m.p12 -passout pass:murmur -name "Murmur Dev"
  security import /tmp/m.p12 -k ~/Library/Keychains/login.keychain-db -P murmur -T /usr/bin/codesign
  # first codesign will pop a keychain dialog — click "Always Allow" once
  ```

### ⚠️ Hardened-runtime + entitlements (the mic silence bug — read this)
Signing with an identity turns ON the **hardened runtime** (`codesign -dv` shows `flags=0x10000`).
Under it, macOS **blocks the microphone unless the app carries the
`com.apple.security.device.audio-input` entitlement** — and it blocks it *before* the permission
prompt can fire, so it's **silent**: every recording captured nothing and Groq/Whisper returned
`"You."` (its output for silence). Fixed via `src-tauri/entitlements.plist` +
`bundle.macOS.entitlements` in `tauri.conf.json`. **Lesson:** any hardened-runtime-protected
resource you add later (camera, etc.) needs its entitlement here too, or it fails silently.

### Permission grants — the recurring gotchas
- **Stale TCC rows** ("Murmur shows enabled but the box won't check / doesn't function"): leftover
  entries from old build identities. Fix: `tccutil reset <Service> com.murmur.app`, then re-grant.
  Services: `Accessibility`, `ListenEvent` (= Input Monitoring), `Microphone`.
- **Settings changes aren't seen live** — most grants are re-read only at app launch, so **relaunch**
  after toggling anything in System Settings.
- **Mic can't be added manually** in Settings — the app must *request* it via the inline
  `AVCaptureDevice.requestAccess` prompt. If the app thinks mic = denied (button opens Settings
  instead of prompting), `tccutil reset Microphone com.murmur.app` + relaunch → status becomes
  notDetermined → clicking "Allow microphone" fires the real popup.
- A "Restart Murmur" button in onboarding (Tauri `app.restart()`) would end this dance — not built yet.

### fn-key push-to-talk (new — `src-tauri/src/ptt_key.rs`)
- **Hold the `fn` (globe) key** to dictate, no modifiers. Implemented as a **listen-only
  CGEventTap** on a dedicated CFRunLoop thread, watching `FlagsChanged` for
  `CGEventFlagSecondaryFn`; start/stop are marshalled to the main thread (Tauri window/audio work
  must be on main). Needs **Input Monitoring** permission (`CGPreflight/CGRequestListenEventAccess`
  in `permissions.rs`; onboarding gates on it). Started from `pipeline::init`.
- The **⌃⌥D global-shortcut combo still works** too (configurable). The combo recorder in
  `HotkeySetting.tsx` **cannot** capture bare keys like fn — that's intentional; fn is a separate
  path. The UI now shows fn as the primary "Push to talk" trigger with an Active/Needs-Input-
  Monitoring badge, and labels the combo as the alternative.
- If holding fn pops the emoji/input menu: **System Settings → Keyboard → "Press 🌐 key to → Do
  Nothing"**. (A single-modifier combo like plain Control+D is a BAD hotkey — it collides with apps
  and caused flicker/churn; default is `Control+Alt+KeyD`.)

### HUD redesign (`src/components/Hud.tsx` + `windows.rs`)
- **Recording:** a pulsing red dot in a small capsule, floating **bottom-center** of the screen.
- **Transcribing/pasting:** a small **translucent squiggle EQ**.
- Overlay is **click-through** (`set_ignore_cursor_events(true)`) and self-positions bottom-center of
  the active monitor (`windows::show_hud`). Indicators carry `aria-label` for a11y + tests.

### Other session-2 fixes (all live)
- **Paste crash fixed:** `insert.rs` posts the **raw V keycode** (`Key::Other(0x09)`), not
  `Key::Unicode('v')` — Unicode resolution goes through **main-thread-only** Text Input Source APIs
  and SIGTRAP-crashes when called from the paste worker thread.
- **Keychain prompt loop fixed:** `secrets.rs` caches lookups in memory (one Keychain read per
  launch) so onboarding's 1.5s poll can't trigger a prompt storm.
- **Paste reliability:** clipboard now propagates before ⌘V and restores after a longer delay.
- **History copy button** confirms with a green check.
- **Release/app build fix:** `bundle.macOS.minimumSystemVersion = "10.15"` (whisper's `u8path` needs
  10.15+; the default 10.13 failed the ggml compile).

### Next steps (priority order)
1. **Distribution via Apple Developer ID** (Matt is creating the account). Path: create a
   **"Developer ID Application"** cert → swap `APPLE_SIGNING_IDENTITY` from "Murmur Dev" to it → add
   **notarization** (`xcrun notarytool submit` + `xcrun stapler staple`; Tauri supports
   `APPLE_ID`/`APPLE_PASSWORD`/`APPLE_TEAM_ID` env) → add `"dmg"` to `bundle.targets` → produce a
   **notarized `.dmg`** that runs on any Mac with no Gatekeeper warnings. Need from Matt: Team ID +
   the Developer ID cert in keychain + an app-specific password.
   - **Mac App Store is NOT viable** — the sandbox forbids the global event tap (Input Monitoring)
     and synthesizing ⌘V into other apps (Accessibility). All such dictation tools ship via
     Developer ID, not the store.
2. **Groq key ownership:** the Groq Keychain item may still be owned by an old build identity → an
   occasional login-password prompt at launch. Delete it (`security delete-generic-password -s
   com.murmur.app -a groq_api_key`) and re-enter the key in the signed app so it owns the item.
3. Optional: "Restart Murmur" onboarding button; the deferred items from session 1 (launch-at-login,
   real app icon, Claude cleanup provider, etc.).

### Sanity / dogfood tips for a new session
- Check what the mic actually captured by reading history:
  `sqlite3 ~/Library/Application\ Support/com.murmur.app/murmur.db "select id,created_at,raw_text from transcripts order by id desc limit 5;"`
  All `"you"`/`"You."` = silent mic feed (permission/entitlement problem), not a paste bug.
- Install the built app to `/Applications` so cleanup agents that wipe `target/` don't delete it.
- Cleanup agents wiped `target/` once this session — source + cert survived; just rebuild signed.

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
- `.superpowers/` IS gitignored now (SDD reports/diffs stay local).
- `package.json` name is `murmur`; `version` is `0.1.0` and is bumped by hand, not by any script.

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
