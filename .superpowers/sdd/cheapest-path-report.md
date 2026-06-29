# cheapest-path-byok — implementation report

**Status:** DONE

**Vitest:** 7 files, 24 tests — all pass. No test queries updated (existing regex patterns still match; `FreeDot` is `aria-hidden` and does not affect accessible names).

**Build:** `tsc && vite build` — clean. Both entries (`main`, `hud`) built. No TypeScript errors.

**Cargo:** `Finished dev profile` — 7 pre-existing warnings, 0 errors, no Rust changes.

**Changes (presentational only):**
- `src/components/EngineSettings.tsx`: Added `PROVIDER_INFO` map (keyPage, costLabel, costTone, steps). Added `CostBadge` pill (green `.badge-ok` for free, muted neutral for paid). Added `FreeDot` (aria-hidden green dot) inside Local/Groq seg-item labels. Added free-path tip under Transcription control. ConnectBlock now renders `CostBadge` in header and provider-specific `<ol>` steps instead of the generic 3-step hint. `openUrl` target now comes from `PROVIDER_INFO[provider].keyPage` (same URLs as before).
- `src/components/Onboarding.tsx`: Added one muted intro line above `<EngineSettings>` in the Transcription step.

**No logic/ipc changed:** setSttEngine, setCleanupEngine, setSecret, deleteSecret, verifyProvider, openUrl, getEngineSettings, modelReady, downloadModel, onModelProgress, onChange-on-mutation pattern — all untouched.

**Accessible names preserved:** `FreeDot` is `aria-hidden`; label text still contains "Local (on-device Whisper)", "OpenAI", "Groq", "Rule-based". All existing `getByRole("radio", ...)` and button queries match unchanged.

**Concerns:** None. Purely additive presentational layer.

**Report path:** `/Users/matthewbartelt/murmur/.superpowers/sdd/cheapest-path-report.md`
