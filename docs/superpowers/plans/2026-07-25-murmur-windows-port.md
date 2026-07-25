# Murmur Windows Port — Plan

**Written:** 2026-07-25 against `main` @ `559d926`.
**Goal:** the same product on Windows 10/11 — hold a key, speak, transcribed + cleaned text pastes
at the cursor. Tray app, local-first, BYOK cloud optional. One codebase, platform-gated natives.

## Portability audit

**Already portable (~80% of the app, no changes):** `pipeline.rs` orchestration, `audio.rs` (cpal →
WASAPI on Windows), `resample.rs`, `stt/cloud.rs`, all of `cleanup/`, `wav.rs`, `provider.rs`,
`engines.rs`, `model.rs` download, `hotkey.rs` (tauri-plugin-global-shortcut is cross-platform),
`windows.rs` HUD management (Tauri APIs), arboard clipboard, SQLite/store plugins, and the entire
React/Tailwind UI (WebView2 on Windows).

**macOS-only — must gate + replace:**

| Component | macOS today | Windows replacement |
|---|---|---|
| `ptt_key.rs` | fn-key CGEventTap | Low-level keyboard hook (`SetWindowsHookEx` WH_KEYBOARD_LL via the `windows` crate, or `rdev`). **The fn key does not exist for the OS on most PCs** (firmware-level) — new default bare PTT key needed; recommend **hold Right Ctrl**, with the same double-tap latch. |
| `insert.rs` | ⌘V with raw keycode `0x09` (mac thread-crash workaround) | Plain enigo Ctrl+V (SendInput); keep clipboard save/restore logic as-is. |
| `permissions.rs` | AVFoundation mic + Accessibility trust | Massively simpler: no Accessibility/Input-Monitoring equivalents. Only check Settings → Privacy → Microphone (app-level toggle); onboarding shrinks to mic check + engine setup. |
| `secrets.rs` | keyring `apple-native` | keyring `windows-native` (Windows Credential Manager) — feature swap only, API identical. |
| `stt/local.rs` | whisper-rs `metal` | CPU baseline first (base.en is fine on modern CPUs); optional `vulkan` feature for GPU (broadest coverage; `cuda` = NVIDIA-only, skip initially). |
| `lib.rs` + signing | Accessory/no-Dock policy, `macos-private-api`, "Murmur Dev" cert + TCC dance | Tray + `skip_taskbar`; whole TCC/cert dance disappears. New concerns: NSIS installer target, Authenticode signing (Azure Trusted Signing, ~$10/mo) to calm SmartScreen. |

## Cargo mechanics

Move mac-only deps (`objc2*`, `macos-accessibility-client`) into
`[target.'cfg(target_os = "macos")'.dependencies]`; add a windows table with `windows`/`rdev` +
keyring `windows-native` + whisper-rs without `metal`. Target-specific dependency tables apply
features per-OS, so one Cargo.toml serves both. Gate modules with `#[cfg(target_os = ...)]` and keep
the existing trait seams (`PttSink`, `SttEngine`, `CleanupEngine`) — the pipeline never needs to
know the platform.

## Milestones

- **W0 — it compiles on Windows.** cfg-gate the six mac modules, stub Windows impls, add a GitHub
  Actions matrix (`windows-latest` — free CI now that the repo is public) running `cargo test` +
  `vitest` + `tauri build` on both OSes. This is the whole point of W0: keep both platforms green
  forever after.
- **W1 — MVP loop (cloud-first).** Tray + settings window + Ctrl+Alt+D global shortcut + WASAPI
  capture + Groq STT + cleanup + Ctrl+V insert + HUD. Cloud-first sidesteps every GPU question and
  reuses the free-Groq onboarding. End state: real dictation into Notepad on real hardware.
- **W2 — local Whisper.** CPU inference first, reusing the model download; then a `vulkan` build
  flag for GPU. Benchmark before promising local as the Windows default.
- **W3 — push-to-talk parity.** LL keyboard hook, bare-key hold (default Right Ctrl) + double-tap
  latch; per-platform hotkey copy in `HotkeySetting.tsx`.
- **W4 — distribution.** `nsis` bundle target, `.ico` icon, Authenticode via Azure Trusted Signing,
  autostart toggle; later Tauri updater + winget manifest.

## Windows-specific gotchas (collected up front)

- **fn/globe key is invisible to the OS** on most laptops — don't promise fn parity, pick Right Ctrl.
- **UIPI:** synthetic Ctrl+V cannot reach elevated (admin) windows or UAC/secure-desktop prompts —
  detect focus elevation and toast instead of failing silently.
- **Mic privacy toggle off = silent capture**, exactly like the mac hardened-runtime bug — the
  `"You."`-means-silence diagnosis and the `diag.log` startup snapshot both port straight across;
  check the mic privacy setting in diag.
- **WebView2** is preinstalled on current Win 10/11; have NSIS embed the bootstrapper anyway.
- **Transparent click-through HUD** works in Tauri on Windows but is GPU/driver-sensitive — test
  early; fallback is a small opaque pill.
- **SmartScreen** will scare users on an unsigned installer even more than Gatekeeper does —
  signing is a W4 requirement, not a nice-to-have.

## Hardware / verification reality

CI covers compile + unit tests, but the device gates (mic capture, paste into real apps, hook
behavior, HUD rendering) need a **physical Windows machine** — any cheap x64 laptop. A Parallels VM
on the Mac is fine for W0/W1 smoke testing but ARM-Windows + virtual audio is not a final verify.

**Effort ballpark:** W0+W1 ≈ a weekend with agent help; W2–W4 are independent increments.
