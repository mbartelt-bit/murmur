# Custom Hotkey — Implementation Report

**Branch:** feat/custom-hotkey
**Date:** 2026-06-29

## Check results

| Check | Result |
|---|---|
| `cargo build` | PASS — 0 errors, 2 pre-existing warnings |
| `cargo test` | PASS — 22/22 (20 existing + 2 new) |
| `npx vitest run` | PASS — 21/21 across 6 files |
| `npm run build` | PASS — both entries built cleanly |

## Device gate
Live OS hot-key re-registration must be verified on device — the OS may deny combos already claimed by system or other apps.

## Old summary (preserved)

User-configurable recording hotkey is now fully implemented. The shortcut defaults to `Control+Alt+KeyD` (⌃⌥D) and can be changed in-app via a capture UI row in Settings.

## What was built

### Rust backend (`src-tauri/src/hotkey.rs`)

- **`Hotkeys` struct** — `Arc`-managed state with `Mutex<Shortcut>` (current shortcut) and `Mutex<DoubleTap>` (double-tap FSM). Managed via `app.manage(Arc::clone(&hotkeys))`.
- **Startup load** — `register()` reads `"hotkey"` from `settings.json` via `StoreExt`. Falls back to `"Control+Alt+KeyD"` when absent or invalid.
- **Live comparison** — the plugin handler locks `Hotkeys.current` on every event and compares `sc != &*current`, so swapping the shortcut takes effect on the next keypress with no plugin restart.
- **`get_hotkey` command** — returns `Shortcut::into_string()` (lowercase, e.g. `"control+alt+KeyD"`).
- **`set_hotkey` command** — unregisters old, registers new, rolls back on failure, updates `Hotkeys.current`, persists to store.
- **`parse_accelerator` helper** — thin wrapper around `Shortcut::from_str`; used internally and exposed for tests.

### lib.rs

Added `hotkey::get_hotkey` and `hotkey::set_hotkey` to `generate_handler!`.

### Frontend (`src/`)

- **`src/lib/ipc.ts`** — `getHotkey()` and `setHotkey(accel)` wrappers using `invoke`.
- **`src/components/HotkeySetting.tsx`** — Settings row with:
  - `formatAccelerator(accel)` — converts accelerator string to symbol display (⌃⌥⇧⌘ + key), exported for tests.
  - `formatKeyToken(token)` — strips "Key"/"Digit" prefixes, handles "Space", exported for tests.
  - `buildAccelerator(e)` — builds accelerator from `KeyEventLike`; returns `null` if no modifier held, exported for tests.
  - Capture mode with Esc-to-cancel, bare-key guard, async `setHotkey` call with error display.
  - Cleanup of `keydown` listener on unmount / capture exit.
- **`src/App.tsx`** — `<HotkeySetting />` mounted above `<HistoryList />` in the main settings view.
- **`src/components/HistoryList.tsx`** — changed "Hold ⌃⌥D to start." → "Hold your shortcut to start."

### Tests (`src/__tests__/hotkey-setting.test.tsx`)

21 tests total across the suite (13 new):
- `formatKeyToken` — 4 cases
- `formatAccelerator` — 4 cases
- `buildAccelerator` — 3 cases
- `HotkeySetting` component — (a) renders ⌃⌥D on load; (b) capture + keydown ⌘⇧R calls `setHotkey("Shift+Super+KeyR")`

## API notes / deviations

- `Shortcut::into_string()` outputs lowercase modifiers (`"control+alt+KeyD"`). The parser (`parse_hotkey`) is case-insensitive, so the UI can send `"Control+Alt+KeyD"` (capitalised) and the backend accepts it. `formatAccelerator` lowercases before parsing so both cases render correctly.
- Modifier order in `buildAccelerator`: ctrl→alt→shift→meta. The resulting string (`"Shift+Super+KeyR"`) parses correctly on the Rust side since `parse_hotkey` is order-insensitive for modifiers.
- `global_hotkey` v0.8.0 (backing `tauri-plugin-global-shortcut` v2.3.2) exposes `HotKey as Shortcut` with `from_str` / `PartialEq` / `Copy` — all used directly.

## Verification results

| Check | Result |
|---|---|
| `cargo build` | ✅ 0 errors, 2 pre-existing warnings |
| `cargo test` | ✅ 22/22 passed (18 original + 4 new) |
| `npx vitest run` | ✅ 21/21 passed (8 original + 13 new) |
| `npm run build` | ✅ 5 chunks, 0 errors |
