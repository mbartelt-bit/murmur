# Murmur M0 + M1 — Skeleton & Core Local Dictation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first daily-usable build of Murmur — a macOS menubar app where holding a hotkey records the mic, transcribes on-device with Whisper, lightly cleans the text, and pastes it at the cursor in the focused app — plus the skeleton (tray app, permissions, Keychain, SQLite) it stands on.

**Architecture:** A Tauri v2 background (Accessory) macOS app. Rust core owns the native work (hotkey, mic capture, on-device Whisper, clipboard-paste insertion, Keychain, permissions); a React+TS+Vite frontend owns every visible surface (onboarding, settings, recording HUD, menubar panel). The dictation pipeline lives in Rust and is driven by global-shortcut Pressed/Released events; results stream to the UI via Tauri events and are persisted to SQLite from the JS side.

**Tech Stack:** Tauri 2.11 · React 18 + TypeScript + Vite · Tailwind · Rust. Crates: `cpal` 0.18, `whisper-rs` 0.16 (feature `metal`), `arboard` 3.6, `enigo` 0.6, `keyring` 3 (feature `apple-native`), `objc2-av-foundation` 0.3, `macos-accessibility-client` 0.0.2, `reqwest` 0.12, `anyhow` 1. Plugins: `tauri-plugin-sql` 2.4 (sqlite), `tauri-plugin-store` 2.4, `tauri-plugin-global-shortcut` 2.3, `tauri-plugin-opener` 2.

## Global Constraints

- **Platform:** macOS first (Apple Silicon primary). All native code is `#[cfg(target_os = "macos")]`-guarded so a Windows path stays open.
- **Local-first:** M0+M1 use ZERO cloud calls. Whisper runs on-device; cleanup is rule-based. BYOK/cloud engines are M2, not here.
- **Engine traits are load-bearing:** define `SttEngine` and `CleanupEngine` traits in M1 even though only local impls exist — M2 swaps cloud impls behind them. Do not inline whisper/cleanup calls into the pipeline.
- **Never lose words:** the raw transcript is emitted to the UI and written to history before/independent of insertion success.
- **Never silently insert garbage:** empty/failed transcription inserts nothing and surfaces a toast.
- **Secrets:** API keys (M2) live only in macOS Keychain — never SQLite/store/disk. (The Keychain module is built in M0 so M2 can use it.)
- **Pinned versions:** use the exact crate/plugin major versions above; they were API-verified June 2026. If a pinned API doesn't compile, check docs.rs for that exact version before changing approach.
- **Rust min version:** 1.77.2.
- **Codename:** "Murmur" / bundle id `com.murmur.app` (placeholder; one place to change later).

---

## File Structure

```
~/murmur/
├── package.json
├── index.html                      # settings/onboarding entry
├── hud.html                        # HUD overlay entry (separate webview)
├── vite.config.ts
├── tailwind.config.js
├── src/                            # React frontend
│   ├── main.tsx                    # mounts <App/> on #root in index.html
│   ├── App.tsx                     # router: onboarding vs settings
│   ├── hud.tsx                     # mounts <Hud/> on #hud in hud.html
│   ├── lib/
│   │   ├── ipc.ts                  # typed wrappers over invoke()/listen()
│   │   └── db.ts                   # SQLite history access (plugin-sql)
│   ├── components/
│   │   ├── Onboarding.tsx          # permission + model gate
│   │   ├── Settings.tsx            # settings shell
│   │   ├── HistoryList.tsx         # recent dictations
│   │   └── Hud.tsx                 # recording overlay (waveform + state)
│   └── __tests__/                  # Vitest + RTL
└── src-tauri/
    ├── Cargo.toml
    ├── tauri.conf.json
    ├── Info.plist                  # NSMicrophoneUsageDescription (auto-merged)
    ├── capabilities/default.json   # plugin permission grants
    └── src/
        ├── main.rs                 # calls murmur_lib::run()
        ├── lib.rs                  # builder, plugins, command registration, setup
        ├── audio.rs                # cpal capture + rms/peak/mono helpers
        ├── resample.rs             # linear resampler to 16k (pure)
        ├── stt/
        │   ├── mod.rs              # SttEngine trait + factory
        │   └── local.rs            # whisper-rs impl
        ├── cleanup/
        │   ├── mod.rs              # CleanupEngine trait + factory
        │   └── rules.rs            # rule-based impl (pure)
        ├── insert.rs               # clipboard save/set/restore + ⌘V
        ├── hotkey.rs               # global-shortcut: hold + double-tap
        ├── pipeline.rs             # orchestrates capture→stt→cleanup→insert
        ├── permissions.rs          # mic + accessibility status/request/open
        ├── secrets.rs              # Keychain get/set/delete (for M2 BYOK)
        ├── model.rs                # ensure/download whisper model
        └── windows.rs              # show/hide HUD + settings helpers
```

**Responsibility boundaries:** each Rust module is one concern with a small public surface. The pipeline is the only module that knows about all the others; everything else is independently unit-testable (pure modules) or manually verifiable (native side-effect modules). Pure modules (`resample`, `cleanup::rules`, `audio` helpers) get real unit tests; side-effecting modules (`audio` stream, `insert`, `hotkey`, `windows`, `permissions`) get manual verification steps with exact expected behavior, because mocking CoreAudio/AX/pasteboard yields tests that assert nothing real.

---

# M0 — Skeleton & Permissions

## Task 1: Scaffold the Tauri v2 menubar app

**Files:**
- Create: whole project tree under `~/murmur` (scaffolded), then edit `src-tauri/src/lib.rs`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`
- Create: `hud.html`

**Interfaces:**
- Produces: a running Accessory (no-dock) app with a tray icon; a hidden `settings` window shown on tray click; a hidden `hud` window. `murmur_lib::run()` entry point.

- [ ] **Step 1: Scaffold into the existing repo**

The repo `~/murmur` already exists (git initialized, contains `docs/`). Scaffold Tauri into a temp dir and move files in, to avoid the CLI refusing a non-empty dir.

```bash
cd ~
npm create tauri-app@latest murmur-scaffold -- --template react-ts --manager npm
rsync -a --exclude='.git' ~/murmur-scaffold/ ~/murmur/
rm -rf ~/murmur-scaffold
cd ~/murmur && npm install
```

- [ ] **Step 2: Pin identifiers and enable tray + macOSPrivateApi**

Edit `src-tauri/tauri.conf.json` — set `identifier`, enable `macOSPrivateApi`, declare the two windows (both initially hidden):

```json
{
  "$schema": "https://schema.tauri.app/config/2",
  "productName": "Murmur",
  "version": "0.1.0",
  "identifier": "com.murmur.app",
  "build": {
    "frontendDist": "../dist",
    "devUrl": "http://localhost:1420",
    "beforeDevCommand": "npm run dev",
    "beforeBuildCommand": "npm run build"
  },
  "app": {
    "macOSPrivateApi": true,
    "withGlobalTauri": false,
    "windows": [
      { "label": "settings", "title": "Murmur", "width": 760, "height": 560, "visible": false, "resizable": true },
      { "label": "hud", "url": "hud.html", "width": 260, "height": 72, "x": 40, "y": 40,
        "transparent": true, "decorations": false, "alwaysOnTop": true,
        "skipTaskbar": true, "shadow": false, "focus": false, "resizable": false, "visible": false }
    ],
    "security": { "csp": null }
  },
  "bundle": { "active": true, "targets": "app", "icon": ["icons/icon.icns", "icons/icon.png"] }
}
```

In `src-tauri/Cargo.toml`, ensure the tray feature:

```toml
[dependencies]
tauri = { version = "2", features = ["tray-icon"] }
```

- [ ] **Step 3: Implement the Accessory app + tray in `lib.rs`**

Replace `src-tauri/src/lib.rs`:

```rust
mod windows;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let quit = MenuItem::with_id(app, "quit", "Quit Murmur", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "settings" => windows::show_settings(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        windows::show_settings(tray.app_handle());
                    }
                })
                .build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Murmur");
}
```

Create `src-tauri/src/windows.rs`:

```rust
use tauri::{AppHandle, Manager};

pub fn show_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

pub fn show_hud(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("hud") {
        let _ = w.show();
    }
}

pub fn hide_hud(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("hud") {
        let _ = w.hide();
    }
}
```

- [ ] **Step 4: Add the HUD entry point**

Create `hud.html` at repo root (mirrors `index.html`, different root id + module):

```html
<!doctype html>
<html>
  <head><meta charset="UTF-8" /><title>Murmur HUD</title></head>
  <body style="margin:0;background:transparent;overflow:hidden;">
    <div id="hud"></div>
    <script type="module" src="/src/hud.tsx"></script>
  </body>
</html>
```

Create a placeholder `src/hud.tsx`:

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
ReactDOM.createRoot(document.getElementById("hud")!).render(<div>HUD</div>);
```

Add `hud.html` as a Vite input in `vite.config.ts`:

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "path";

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: {
    rollupOptions: {
      input: { main: resolve(__dirname, "index.html"), hud: resolve(__dirname, "hud.html") },
    },
  },
});
```

- [ ] **Step 5: Run and verify the skeleton**

Run: `cd ~/murmur && npm run tauri dev`
Expected: app compiles; a tray icon appears in the macOS menubar; **no Dock icon** appears; left-clicking the tray (or tray → Settings…) shows the settings window with the default Vite/React page; "Quit Murmur" exits. The HUD window does not appear (hidden).

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A
git commit -m "M0: scaffold Tauri v2 menubar app (accessory, tray, settings + HUD windows)"
```

---

## Task 2: SQLite + settings store

**Files:**
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`, `src-tauri/capabilities/default.json`
- Create: `src/lib/db.ts`
- Test: `src/__tests__/db.smoke.test.ts`

**Interfaces:**
- Produces (Rust): SQL plugin registered with migration v1 creating `transcripts` and `dictionary` tables on `sqlite:murmur.db`; store plugin registered.
- Produces (JS): `src/lib/db.ts` exporting `getDb(): Promise<Database>`, `insertTranscript(raw, clean, app)`, `listTranscripts(limit)`, `deleteTranscript(id)`.

- [ ] **Step 1: Add plugins**

```bash
cd ~/murmur/src-tauri
cargo add tauri-plugin-sql --features sqlite
cargo add tauri-plugin-store
cd ~/murmur
npm install @tauri-apps/plugin-sql @tauri-apps/plugin-store
```

- [ ] **Step 2: Register plugins + migration in `lib.rs`**

Add before `.setup(...)` in the builder chain:

```rust
use tauri_plugin_sql::{Builder as SqlBuilder, Migration, MigrationKind};

let migrations = vec![Migration {
    version: 1,
    description: "create_core_tables",
    sql: "
        CREATE TABLE transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            raw_text TEXT NOT NULL,
            clean_text TEXT NOT NULL,
            app_name TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE dictionary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
    ",
    kind: MigrationKind::Up,
}];

tauri::Builder::default()
    .plugin(SqlBuilder::default().add_migrations("sqlite:murmur.db", migrations).build())
    .plugin(tauri_plugin_store::Builder::new().build())
    // ...existing .setup(...).run(...)
```

- [ ] **Step 3: Grant plugin permissions**

Edit `src-tauri/capabilities/default.json` `permissions` array to include:

```json
"sql:default",
"sql:allow-execute",
"sql:allow-select",
"sql:allow-load",
"store:default"
```

- [ ] **Step 4: Write the failing JS smoke test**

`src/__tests__/db.smoke.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";

vi.mock("@tauri-apps/plugin-sql", () => {
  const rows: any[] = [];
  const fake = {
    execute: vi.fn(async (sql: string, args: any[]) => {
      if (sql.startsWith("INSERT")) rows.push({ id: rows.length + 1, raw_text: args[0], clean_text: args[1], app_name: args[2] });
      return { rowsAffected: 1, lastInsertId: rows.length };
    }),
    select: vi.fn(async () => rows.slice().reverse()),
  };
  return { default: { load: vi.fn(async () => fake) } };
});

import { insertTranscript, listTranscripts } from "../lib/db";

describe("db", () => {
  it("inserts then lists newest-first", async () => {
    await insertTranscript("raw one", "Clean one", "TextEdit");
    const rows = await listTranscripts(10);
    expect(rows[0].clean_text).toBe("Clean one");
  });
});
```

- [ ] **Step 5: Run it — verify it fails**

Run: `cd ~/murmur && npx vitest run src/__tests__/db.smoke.test.ts`
Expected: FAIL — `Cannot find module '../lib/db'`. (Install vitest first if missing: `npm i -D vitest`.)

- [ ] **Step 6: Implement `src/lib/db.ts`**

```ts
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
```

- [ ] **Step 7: Run test — verify it passes**

Run: `npx vitest run src/__tests__/db.smoke.test.ts`
Expected: PASS.

- [ ] **Step 8: Verify migration runs on device**

Run: `npm run tauri dev`. Expected: no migration errors in the terminal; app starts normally. (Table existence is exercised by Task 14.)

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "M0: SQLite migrations (transcripts, dictionary) + settings store + db.ts"
```

---

## Task 3: Keychain secrets module

**Files:**
- Create: `src-tauri/src/secrets.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`
- Test: inline `#[cfg(test)]` in `secrets.rs`

**Interfaces:**
- Produces: tauri commands `secret_set(key: String, value: String)`, `secret_get(key: String) -> Option<String>`, `secret_delete(key: String)`. Internal fns `set/get/delete(account: &str)` over service `com.murmur.app`.

- [ ] **Step 1: Add keyring**

```bash
cd ~/murmur/src-tauri && cargo add keyring --features apple-native
```

- [ ] **Step 2: Write the failing unit test**

Create `src-tauri/src/secrets.rs`:

```rust
use keyring::{Entry, Error, Result};

const SERVICE: &str = "com.murmur.app";

pub fn set(account: &str, value: &str) -> Result<()> {
    Entry::new(SERVICE, account)?.set_password(value)
}

pub fn get(account: &str) -> Result<Option<String>> {
    match Entry::new(SERVICE, account)?.get_password() {
        Ok(s) => Ok(Some(s)),
        Err(Error::NoEntry) => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn delete(account: &str) -> Result<()> {
    match Entry::new(SERVICE, account)?.delete_credential() {
        Ok(()) | Err(Error::NoEntry) => Ok(()),
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub fn secret_set(key: String, value: String) -> std::result::Result<(), String> {
    set(&key, &value).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn secret_get(key: String) -> std::result::Result<Option<String>, String> {
    get(&key).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn secret_delete(key: String) -> std::result::Result<(), String> {
    delete(&key).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_and_delete() {
        let acct = "test-byok-key";
        set(acct, "sk-secret-123").unwrap();
        assert_eq!(get(acct).unwrap().as_deref(), Some("sk-secret-123"));
        delete(acct).unwrap();
        assert_eq!(get(acct).unwrap(), None);
    }
}
```

- [ ] **Step 3: Wire the module + commands into `lib.rs`**

Add `mod secrets;` at the top, and register the commands:

```rust
.invoke_handler(tauri::generate_handler![
    secrets::secret_set, secrets::secret_get, secrets::secret_delete
])
```

- [ ] **Step 4: Run the test — verify it passes**

Run: `cd ~/murmur/src-tauri && cargo test secrets::tests::roundtrip_and_delete`
Expected: PASS. (macOS may show a one-time keychain prompt under `cargo test` — allow it. This is the dev-signing artifact noted in the spec, not a bug.)

- [ ] **Step 5: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M0: Keychain-backed secrets module + commands (for M2 BYOK)"
```

---

## Task 4: Permissions (mic + accessibility) + onboarding gate

**Files:**
- Create: `src-tauri/src/permissions.rs`, `src-tauri/Info.plist`, `src/components/Onboarding.tsx`, `src/lib/ipc.ts`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`, `src/App.tsx`
- Test: `src/__tests__/onboarding.test.tsx`

**Interfaces:**
- Produces (Rust commands): `mic_status() -> String` (`"authorized"|"denied"|"notDetermined"|"restricted"`), `request_mic() -> bool`, `accessibility_trusted() -> bool`, `open_privacy_pane(which: String)` (`"mic"|"accessibility"`).
- Produces (JS): `src/lib/ipc.ts` typed wrappers; `<Onboarding onReady/>` component.

- [ ] **Step 1: Add native deps + Info.plist**

```bash
cd ~/murmur/src-tauri
cargo add objc2-av-foundation --features AVCaptureDevice,AVMediaFormat
cargo add block2
cargo add macos-accessibility-client
cargo add tauri-plugin-opener
cd ~/murmur && npm install @tauri-apps/plugin-opener
```

Create `src-tauri/Info.plist` (Tauri auto-merges it):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSMicrophoneUsageDescription</key>
  <string>Murmur needs the microphone to transcribe your dictation on-device.</string>
</dict>
</plist>
```

- [ ] **Step 2: Implement `permissions.rs`**

```rust
use objc2_av_foundation::{AVAuthorizationStatus, AVCaptureDevice, AVMediaTypeAudio};

pub fn mic_status_str() -> &'static str {
    let status = unsafe { AVCaptureDevice::authorizationStatusForMediaType(AVMediaTypeAudio) };
    match status {
        AVAuthorizationStatus::Authorized => "authorized",
        AVAuthorizationStatus::Denied => "denied",
        AVAuthorizationStatus::Restricted => "restricted",
        _ => "notDetermined",
    }
}

#[tauri::command]
pub fn mic_status() -> String { mic_status_str().to_string() }

#[tauri::command]
pub async fn request_mic() -> bool {
    use block2::RcBlock;
    use std::sync::mpsc;
    let (tx, rx) = mpsc::channel::<bool>();
    let handler = RcBlock::new(move |granted: objc2::runtime::Bool| {
        let _ = tx.send(granted.as_bool());
    });
    unsafe {
        AVCaptureDevice::requestAccessForMediaType_completionHandler(AVMediaTypeAudio, &handler);
    }
    // callback fires on an internal queue; block this worker (command is async => off UI thread)
    rx.recv().unwrap_or(false)
}

#[tauri::command]
pub fn accessibility_trusted() -> bool {
    macos_accessibility_client::accessibility::application_is_trusted()
}

#[tauri::command]
pub fn open_privacy_pane(which: String) {
    let url = match which.as_str() {
        "accessibility" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        _ => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
    };
    let _ = std::process::Command::new("open").arg(url).spawn();
}
```

Add `mod permissions;` and register all four commands in the `generate_handler!` list.

- [ ] **Step 3: Write the failing onboarding component test**

`src/__tests__/onboarding.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";

const invoke = vi.fn();
vi.mock("../lib/ipc", () => ({
  micStatus: () => invoke("mic_status"),
  requestMic: () => invoke("request_mic"),
  accessibilityTrusted: () => invoke("accessibility_trusted"),
  openPrivacyPane: (w: string) => invoke("open_privacy_pane", w),
}));

import { Onboarding } from "../components/Onboarding";

describe("Onboarding", () => {
  beforeEach(() => invoke.mockReset());

  it("calls onReady when both permissions are granted", async () => {
    invoke.mockImplementation((cmd: string) =>
      cmd === "mic_status" ? Promise.resolve("authorized")
      : cmd === "accessibility_trusted" ? Promise.resolve(true)
      : Promise.resolve(true));
    const onReady = vi.fn();
    render(<Onboarding onReady={onReady} />);
    await waitFor(() => expect(onReady).toHaveBeenCalled());
  });

  it("shows a grant button when mic is not granted", async () => {
    invoke.mockImplementation((cmd: string) =>
      cmd === "mic_status" ? Promise.resolve("notDetermined")
      : cmd === "accessibility_trusted" ? Promise.resolve(false)
      : Promise.resolve(true));
    render(<Onboarding onReady={vi.fn()} />);
    expect(await screen.findByRole("button", { name: /allow microphone/i })).toBeTruthy();
  });
});
```

- [ ] **Step 4: Run it — verify it fails**

Run: `npx vitest run src/__tests__/onboarding.test.tsx`
Expected: FAIL — cannot find `../components/Onboarding`.

- [ ] **Step 5: Implement `ipc.ts` + `Onboarding.tsx`**

`src/lib/ipc.ts` (extend across later tasks):

```ts
import { invoke } from "@tauri-apps/api/core";

export const micStatus = () => invoke<string>("mic_status");
export const requestMic = () => invoke<boolean>("request_mic");
export const accessibilityTrusted = () => invoke<boolean>("accessibility_trusted");
export const openPrivacyPane = (which: "mic" | "accessibility") =>
  invoke<void>("open_privacy_pane", { which });
```

`src/components/Onboarding.tsx`:

```tsx
import { useCallback, useEffect, useState } from "react";
import { micStatus, requestMic, accessibilityTrusted, openPrivacyPane } from "../lib/ipc";

export function Onboarding({ onReady }: { onReady: () => void }) {
  const [mic, setMic] = useState<string>("notDetermined");
  const [ax, setAx] = useState<boolean>(false);

  const refresh = useCallback(async () => {
    const [m, a] = await Promise.all([micStatus(), accessibilityTrusted()]);
    setMic(m); setAx(a);
    if (m === "authorized" && a) onReady();
  }, [onReady]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 1500); // re-check after user returns from System Settings
    return () => clearInterval(id);
  }, [refresh]);

  return (
    <div className="p-8 space-y-6">
      <h1 className="text-xl font-semibold">Welcome to Murmur</h1>
      <Row label="Microphone" ok={mic === "authorized"}>
        {mic !== "authorized" && (
          <button onClick={async () => {
            if (mic === "notDetermined") { await requestMic(); } else { await openPrivacyPane("mic"); }
            refresh();
          }}>Allow microphone</button>
        )}
      </Row>
      <Row label="Accessibility (for paste + hotkey)" ok={ax}>
        {!ax && <button onClick={() => openPrivacyPane("accessibility")}>Open Accessibility settings</button>}
      </Row>
    </div>
  );
}

function Row({ label, ok, children }: { label: string; ok: boolean; children?: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between border-b py-3">
      <span>{ok ? "✓ " : "○ "}{label}</span>
      {children}
    </div>
  );
}
```

- [ ] **Step 6: Gate `App.tsx` on onboarding**

```tsx
import { useState } from "react";
import { Onboarding } from "./components/Onboarding";

export default function App() {
  const [ready, setReady] = useState(false);
  if (!ready) return <Onboarding onReady={() => setReady(true)} />;
  return <div className="p-8">Settings (coming next)</div>;
}
```

- [ ] **Step 7: Run tests — verify pass**

Run: `npx vitest run src/__tests__/onboarding.test.tsx`
Expected: PASS (both cases). Install `@testing-library/react`/`jsdom` if needed: `npm i -D @testing-library/react @testing-library/jest-dom jsdom` and set `test.environment: "jsdom"` in `vite.config.ts`.

- [ ] **Step 8: Verify on device**

Run: `npm run tauri dev`. Expected: onboarding lists Microphone + Accessibility. "Allow microphone" triggers the macOS mic prompt; granting flips the row to ✓. "Open Accessibility settings" opens the correct pane; after toggling Murmur on there, the row flips to ✓ within ~1.5s and the settings placeholder renders.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "M0: mic + accessibility permission flow with onboarding gate"
```

---

# M1 — Core Dictation (local-only)

## Task 5: Audio capture + level helpers

**Files:**
- Create: `src-tauri/src/audio.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`
- Test: inline `#[cfg(test)]` in `audio.rs`

**Interfaces:**
- Produces: `pub fn rms(&[f32]) -> f32`, `pub fn peak(&[f32]) -> f32`, `pub fn stereo_to_mono(&[f32]) -> Vec<f32>`. `pub struct Capture { stream, buffer: Arc<Mutex<Vec<f32>>>, level: Arc<Mutex<f32>>, sample_rate: u32, channels: u16 }`. `pub fn start_capture() -> anyhow::Result<Capture>`. `Capture::stop(self) -> Vec<f32>` returns accumulated interleaved samples.

- [ ] **Step 1: Add deps**

```bash
cd ~/murmur/src-tauri && cargo add cpal@0.18 anyhow
```

- [ ] **Step 2: Write failing unit tests for the pure helpers**

In `src-tauri/src/audio.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rms_of_silence_is_zero() { assert_eq!(rms(&[0.0; 16]), 0.0); }
    #[test]
    fn rms_of_constant_is_magnitude() {
        let v = vec![0.5_f32; 100];
        assert!((rms(&v) - 0.5).abs() < 1e-6);
    }
    #[test]
    fn peak_returns_max_abs() { assert!((peak(&[0.1, -0.9, 0.3]) - 0.9).abs() < 1e-6); }
    #[test]
    fn stereo_downmix_averages_frames() {
        assert_eq!(stereo_to_mono(&[1.0, 0.0, 0.0, 1.0]), vec![0.5, 0.5]);
    }
}
```

- [ ] **Step 3: Run — verify fail**

Run: `cargo test audio::tests`
Expected: FAIL — `rms` etc. not found.

- [ ] **Step 4: Implement `audio.rs`**

```rust
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use std::sync::{Arc, Mutex};

pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() { return 0.0; }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0_f32, |m, &s| m.max(s.abs()))
}

pub fn stereo_to_mono(interleaved: &[f32]) -> Vec<f32> {
    interleaved.chunks_exact(2).map(|f| (f[0] + f[1]) * 0.5).collect()
}

pub struct Capture {
    stream: cpal::Stream,
    buffer: Arc<Mutex<Vec<f32>>>,
    pub level: Arc<Mutex<f32>>,
    pub sample_rate: u32,
    pub channels: u16,
}

pub fn start_capture() -> anyhow::Result<Capture> {
    let host = cpal::default_host();
    let device = host.default_input_device()
        .ok_or_else(|| anyhow::anyhow!("no default input device"))?;
    let supported = device.default_input_config()?;
    let sample_rate = supported.sample_rate().0;
    let channels = supported.channels();
    let fmt = supported.sample_format();
    let config: StreamConfig = supported.into();

    let buffer = Arc::new(Mutex::new(Vec::<f32>::new()));
    let level = Arc::new(Mutex::new(0.0_f32));
    let (buf_cb, lvl_cb) = (buffer.clone(), level.clone());
    let err_fn = |e| eprintln!("cpal error: {e}");

    let stream = match fmt {
        SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _: &_| {
                if let Ok(mut l) = lvl_cb.lock() { *l = rms(data); }
                if let Ok(mut b) = buf_cb.lock() { b.extend_from_slice(data); }
            }, err_fn, None)?,
        SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _: &_| {
                let f: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                if let Ok(mut l) = lvl_cb.lock() { *l = rms(&f); }
                if let Ok(mut b) = buf_cb.lock() { b.extend_from_slice(&f); }
            }, err_fn, None)?,
        other => anyhow::bail!("unsupported sample format: {other:?}"),
    };
    stream.play()?;
    Ok(Capture { stream, buffer, level, sample_rate, channels })
}

impl Capture {
    /// Stop capture and return accumulated interleaved samples.
    pub fn stop(self) -> Vec<f32> {
        let _ = self.stream.pause();
        let out = self.buffer.lock().map(|b| b.clone()).unwrap_or_default();
        out
    }
}
```

Add `mod audio;` to `lib.rs`.

- [ ] **Step 5: Run tests — verify pass**

Run: `cargo test audio::tests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: cpal mic capture + rms/peak/mono helpers"
```

---

## Task 6: Linear resampler to 16 kHz

**Files:**
- Create: `src-tauri/src/resample.rs`
- Modify: `src-tauri/src/lib.rs`
- Test: inline `#[cfg(test)]`

**Interfaces:**
- Produces: `pub fn resample_linear(input: &[f32], in_rate: u32, out_rate: u32) -> Vec<f32>`.

- [ ] **Step 1: Write failing tests**

`src-tauri/src/resample.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passthrough_when_rates_match() {
        let v = vec![0.1, 0.2, 0.3];
        assert_eq!(resample_linear(&v, 16000, 16000), v);
    }
    #[test]
    fn downsample_48k_to_16k_thirds_length() {
        let input = vec![0.0_f32; 4800]; // 0.1s @ 48k
        let out = resample_linear(&input, 48000, 16000);
        assert!((out.len() as i32 - 1600).abs() <= 1); // ~0.1s @ 16k
    }
    #[test]
    fn empty_input_yields_empty() {
        assert!(resample_linear(&[], 48000, 16000).is_empty());
    }
}
```

- [ ] **Step 2: Run — verify fail**

Run: `cargo test resample::tests`
Expected: FAIL — function not found.

- [ ] **Step 3: Implement**

```rust
/// Linear-interpolation resampler (mono f32). Adequate for speech → Whisper.
pub fn resample_linear(input: &[f32], in_rate: u32, out_rate: u32) -> Vec<f32> {
    if input.is_empty() || in_rate == out_rate { return input.to_vec(); }
    let ratio = in_rate as f64 / out_rate as f64;
    let out_len = ((input.len() as f64) / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let i0 = src.floor() as usize;
        let i1 = (i0 + 1).min(input.len() - 1);
        let frac = (src - i0 as f64) as f32;
        out.push(input[i0] * (1.0 - frac) + input[i1] * frac);
    }
    out
}
```

Add `mod resample;` to `lib.rs`.

- [ ] **Step 4: Run — verify pass**

Run: `cargo test resample::tests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: linear resampler to 16kHz"
```

---

## Task 7: Whisper model manager (ensure/download)

**Files:**
- Create: `src-tauri/src/model.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`, `src/lib/ipc.ts`, `src/components/Onboarding.tsx`
- Test: inline `#[cfg(test)]` for the path/URL helpers

**Interfaces:**
- Produces (Rust): `pub fn model_path(app: &AppHandle) -> PathBuf` (app-data dir + `models/ggml-base.en.bin`); command `model_ready(app) -> bool`; async command `download_model(app) -> Result<(), String>` that streams `base.en` and emits `model-progress` (f64 0..1) events.
- Produces (JS): `modelReady()`, `downloadModel()`, a `model-progress` listener; an onboarding "Download speech model (~142 MB)" step.

- [ ] **Step 1: Add reqwest + futures-util**

```bash
cd ~/murmur/src-tauri && cargo add reqwest --features stream,rustls-tls --no-default-features
cargo add futures-util
```

- [ ] **Step 2: Write failing test for the model filename helper**

`src-tauri/src/model.rs`:

```rust
pub const MODEL_FILE: &str = "ggml-base.en.bin";
pub const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn url_points_at_base_en() {
        assert!(MODEL_URL.ends_with(MODEL_FILE));
    }
}
```

- [ ] **Step 3: Run — verify fail/pass scaffold**

Run: `cargo test model::tests`
Expected: FAIL (module not yet in `lib.rs`) → after step 4 it PASSES. (This is a trivial guard test; the real verification is the on-device download in Step 6.)

- [ ] **Step 4: Implement the model manager**

```rust
use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager};

fn models_dir(app: &AppHandle) -> PathBuf {
    let dir = app.path().app_data_dir().expect("app data dir").join("models");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn model_path(app: &AppHandle) -> PathBuf { models_dir(app).join(MODEL_FILE) }

#[tauri::command]
pub fn model_ready(app: AppHandle) -> bool {
    let p = model_path(&app);
    std::fs::metadata(&p).map(|m| m.len() > 1_000_000).unwrap_or(false)
}

#[tauri::command]
pub async fn download_model(app: AppHandle) -> Result<(), String> {
    use futures_util::StreamExt;
    let dest = model_path(&app);
    let resp = reqwest::get(MODEL_URL).await.map_err(|e| e.to_string())?;
    let total = resp.content_length().unwrap_or(0);
    let mut stream = resp.bytes_stream();
    let tmp = dest.with_extension("part");
    let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut downloaded: u64 = 0;
    use std::io::Write;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        downloaded += chunk.len() as u64;
        if total > 0 {
            let _ = app.emit("model-progress", downloaded as f64 / total as f64);
        }
    }
    drop(file);
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    let _ = app.emit("model-progress", 1.0_f64);
    Ok(())
}
```

Add `mod model;` and register `model_ready`, `download_model`. Grant network in capabilities if required by your reqwest setup (reqwest used directly in Rust does not need a Tauri http permission).

- [ ] **Step 5: Add the download step to onboarding**

Extend `src/lib/ipc.ts`:

```ts
import { listen } from "@tauri-apps/api/event";
export const modelReady = () => invoke<boolean>("model_ready");
export const downloadModel = () => invoke<void>("download_model");
export const onModelProgress = (cb: (p: number) => void) =>
  listen<number>("model-progress", (e) => cb(e.payload));
```

In `Onboarding.tsx`, add a third `Row` for the model: show progress while downloading, ✓ when `modelReady()` is true, and only call `onReady()` when mic + accessibility + model are all good.

- [ ] **Step 6: Verify on device**

Run: `npm run tauri dev`. In onboarding, click "Download speech model"; expect a progress bar 0→100% and a ✓ when complete. Confirm the file exists:
`ls -lh "$HOME/Library/Application Support/com.murmur.app/models/ggml-base.en.bin"` → ~142 MB.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "M1: whisper model download manager + onboarding step (base.en)"
```

---

## Task 8: Local Whisper STT engine (behind SttEngine trait)

**Files:**
- Create: `src-tauri/src/stt/mod.rs`, `src-tauri/src/stt/local.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`

**Interfaces:**
- Produces: `pub trait SttEngine { fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String>; }`; `pub struct LocalWhisper { model_path: PathBuf }` impl; `pub fn default_engine(model_path: PathBuf) -> Box<dyn SttEngine + Send + Sync>`.

- [ ] **Step 1: Add whisper-rs with Metal**

```bash
cd ~/murmur/src-tauri && cargo add whisper-rs@0.16 --features metal
```

- [ ] **Step 2: Define the trait (`stt/mod.rs`)**

```rust
mod local;
use std::path::PathBuf;

pub trait SttEngine {
    /// 16kHz mono f32 in; transcribed text out. `prompt` biases vocabulary.
    fn transcribe(&self, audio_16k_mono: &[f32], prompt: &str) -> anyhow::Result<String>;
}

pub fn default_engine(model_path: PathBuf) -> Box<dyn SttEngine + Send + Sync> {
    Box::new(local::LocalWhisper::new(model_path))
}
```

- [ ] **Step 3: Implement `stt/local.rs`**

```rust
use super::SttEngine;
use std::path::PathBuf;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct LocalWhisper { model_path: PathBuf }

impl LocalWhisper {
    pub fn new(model_path: PathBuf) -> Self { Self { model_path } }
}

impl SttEngine for LocalWhisper {
    fn transcribe(&self, audio: &[f32], prompt: &str) -> anyhow::Result<String> {
        if audio.is_empty() { return Ok(String::new()); }
        let mut cparams = WhisperContextParameters::default();
        cparams.use_gpu(true); // honored via the `metal` feature
        let ctx = WhisperContext::new_with_params(
            self.model_path.to_str().ok_or_else(|| anyhow::anyhow!("bad model path"))?,
            cparams,
        )?;
        let mut state = ctx.create_state()?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(4);
        params.set_language(Some("en"));
        if !prompt.is_empty() { params.set_initial_prompt(prompt); }
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        state.full(params, audio)?;
        let n = state.full_n_segments()?;
        let mut text = String::new();
        for i in 0..n { text.push_str(&state.full_get_segment_text(i)?); }
        Ok(text.trim().to_string())
    }
}
```

Add `mod stt;` to `lib.rs`.

- [ ] **Step 4: Verify it compiles**

Run: `cargo build`
Expected: builds (first whisper-rs build is slow — it compiles whisper.cpp + Metal shaders). If a pinned method name differs (e.g. `use_gpu`), check `docs.rs/whisper-rs/0.16.0` and adjust.

- [ ] **Step 5: Manual transcription smoke (wired in Task 13)**

No standalone test here — `transcribe` requires the real model + real audio. It is exercised end-to-end in Task 13's verification. (Do not write a fake-model unit test; it would assert nothing.)

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: local Whisper STT engine behind SttEngine trait"
```

---

## Task 9: Rule-based cleanup (behind CleanupEngine trait)

**Files:**
- Create: `src-tauri/src/cleanup/mod.rs`, `src-tauri/src/cleanup/rules.rs`
- Modify: `src-tauri/src/lib.rs`
- Test: inline `#[cfg(test)]` in `rules.rs`

**Interfaces:**
- Produces: `pub trait CleanupEngine { fn clean(&self, raw: &str) -> String; }`; `pub struct RuleCleanup;` impl; `pub fn default_cleanup() -> Box<dyn CleanupEngine + Send + Sync>`.

- [ ] **Step 1: Define trait (`cleanup/mod.rs`)**

```rust
mod rules;
pub trait CleanupEngine { fn clean(&self, raw: &str) -> String; }
pub fn default_cleanup() -> Box<dyn CleanupEngine + Send + Sync> {
    Box::new(rules::RuleCleanup)
}
```

- [ ] **Step 2: Write failing tests (`cleanup/rules.rs`)**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    fn clean(s: &str) -> String { RuleCleanup.clean(s) }
    #[test] fn trims_and_collapses_whitespace() {
        assert_eq!(clean("  hello   world  "), "Hello world.");
    }
    #[test] fn removes_standalone_fillers() {
        assert_eq!(clean("um so uh this is er good"), "So this is good.");
    }
    #[test] fn capitalizes_sentences() {
        assert_eq!(clean("hello. how are you"), "Hello. How are you.");
    }
    #[test] fn keeps_filler_inside_words() {
        assert_eq!(clean("a number of umbrellas"), "A number of umbrellas.");
    }
    #[test] fn empty_stays_empty() { assert_eq!(clean("   "), ""); }
}
```

- [ ] **Step 3: Run — verify fail**

Run: `cargo test cleanup::`
Expected: FAIL — `RuleCleanup` not found.

- [ ] **Step 4: Implement `cleanup/rules.rs`**

```rust
use super::CleanupEngine;

pub struct RuleCleanup;

const FILLERS: &[&str] = &["um", "uh", "er", "erm", "hmm", "uhh", "umm"];

impl CleanupEngine for RuleCleanup {
    fn clean(&self, raw: &str) -> String {
        // 1. tokenize on whitespace, drop standalone filler words (case-insensitive)
        let kept: Vec<&str> = raw
            .split_whitespace()
            .filter(|w| {
                let bare = w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
                !FILLERS.contains(&bare.as_str())
            })
            .collect();
        if kept.is_empty() { return String::new(); }
        let mut text = kept.join(" ");

        // 2. capitalize start of each sentence
        text = capitalize_sentences(&text);

        // 3. ensure terminal punctuation
        if !text.ends_with('.') && !text.ends_with('!') && !text.ends_with('?') {
            text.push('.');
        }
        text
    }
}

fn capitalize_sentences(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut cap_next = true;
    for ch in s.chars() {
        if cap_next && ch.is_alphabetic() {
            out.extend(ch.to_uppercase());
            cap_next = false;
        } else {
            out.push(ch);
            if ch == '.' || ch == '!' || ch == '?' { cap_next = true; }
        }
    }
    out
}
```

Add `mod cleanup;` to `lib.rs`.

- [ ] **Step 5: Run — verify pass**

Run: `cargo test cleanup::`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: rule-based cleanup behind CleanupEngine trait"
```

---

## Task 10: Text insertion (clipboard + ⌘V)

**Files:**
- Create: `src-tauri/src/insert.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`

**Interfaces:**
- Produces: `pub fn insert_text(text: &str) -> Result<(), String>` — saves clipboard, sets text, simulates ⌘V, waits 150ms, restores clipboard.

- [ ] **Step 1: Add deps**

```bash
cd ~/murmur/src-tauri && cargo add arboard@3 enigo@0.6
```

- [ ] **Step 2: Implement `insert.rs`**

```rust
use arboard::{Clipboard, Error as ClipErr};
use enigo::{Direction::{Click, Press, Release}, Enigo, Key, Keyboard, Settings};
use std::{thread, time::Duration};

fn cmd_v() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.key(Key::Meta, Press).map_err(|e| e.to_string())?;
    enigo.key(Key::Unicode('v'), Click).map_err(|e| e.to_string())?;
    enigo.key(Key::Meta, Release).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn insert_text(text: &str) -> Result<(), String> {
    if text.is_empty() { return Ok(()); }
    let mut clip = Clipboard::new().map_err(|e| e.to_string())?;
    let prev = match clip.get_text() {
        Ok(s) => Some(s),
        Err(ClipErr::ContentNotAvailable) => None,
        Err(e) => return Err(e.to_string()),
    };
    clip.set_text(text.to_owned()).map_err(|e| e.to_string())?;
    cmd_v()?;
    thread::sleep(Duration::from_millis(150)); // let target read before restore (race fix)
    match prev {
        Some(p) => { let _ = clip.set_text(p); }
        None => { let _ = clip.clear(); }
    }
    Ok(())
}
```

Add `mod insert;` to `lib.rs`.

- [ ] **Step 3: Verify it compiles**

Run: `cargo build`
Expected: builds.

- [ ] **Step 4: Manual smoke (after Accessibility granted)**

Insertion is verified end-to-end in Task 13 (it needs a focused target app + the pipeline). No unit test — synthetic keystrokes have no deterministic harness.

- [ ] **Step 5: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: clipboard-paste text insertion (save/set/⌘V/restore)"
```

---

## Task 11: Recording HUD overlay

**Files:**
- Create: `src/components/Hud.tsx`
- Modify: `src/hud.tsx`, `src/lib/ipc.ts`, `src-tauri/src/lib.rs` (emit `hud-state` + `vu-level`)
- Test: `src/__tests__/hud.test.tsx`

**Interfaces:**
- Consumes (events): `hud-state` (`"recording"|"transcribing"|"idle"`) and `vu-level` (f32 0..1) emitted from Rust (wired in Task 13).
- Produces: `<Hud/>` rendering a pill with a state label and a level-driven bar.

- [ ] **Step 1: Write the failing component test**

`src/__tests__/hud.test.tsx`:

```tsx
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";

let stateCb: (p: string) => void = () => {};
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "hud-state") stateCb = (p) => cb({ payload: p });
    return () => {};
  }),
}));

import { Hud } from "../components/Hud";

describe("Hud", () => {
  it("shows Recording when state event fires", async () => {
    render(<Hud />);
    stateCb("recording");
    expect(await screen.findByText(/recording/i)).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run — verify fail**

Run: `npx vitest run src/__tests__/hud.test.tsx`
Expected: FAIL — cannot find `../components/Hud`.

- [ ] **Step 3: Implement `Hud.tsx`**

```tsx
import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";

type State = "idle" | "recording" | "transcribing";

export function Hud() {
  const [state, setState] = useState<State>("idle");
  const [level, setLevel] = useState(0);

  useEffect(() => {
    const un1 = listen<State>("hud-state", (e) => setState(e.payload));
    const un2 = listen<number>("vu-level", (e) => setLevel(e.payload));
    return () => { un1.then((f) => f()); un2.then((f) => f()); };
  }, []);

  const label = state === "recording" ? "Recording…"
    : state === "transcribing" ? "Transcribing…" : "";

  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 10, height: 64, padding: "0 16px",
      borderRadius: 16, background: "rgba(20,20,22,0.92)", color: "white",
      fontFamily: "system-ui", fontSize: 13,
    }}>
      <span style={{
        width: 10, height: 10, borderRadius: "50%",
        background: state === "recording" ? "#ff5d5d" : "#8a8a8a",
      }} />
      <span>{label}</span>
      <div style={{ flex: 1, height: 6, background: "rgba(255,255,255,0.15)", borderRadius: 3 }}>
        <div style={{ width: `${Math.min(100, level * 250)}%`, height: "100%",
          background: "#6ee7a8", borderRadius: 3, transition: "width 80ms linear" }} />
      </div>
    </div>
  );
}
```

Update `src/hud.tsx`:

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { Hud } from "./components/Hud";
ReactDOM.createRoot(document.getElementById("hud")!).render(<Hud />);
```

- [ ] **Step 4: Run — verify pass**

Run: `npx vitest run src/__tests__/hud.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "M1: recording HUD overlay (state + level)"
```

---

## Task 12: Hotkey (hold-to-talk + double-tap toggle)

**Files:**
- Create: `src-tauri/src/hotkey.rs`
- Modify: `src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`
- Test: inline `#[cfg(test)]` for the double-tap timing logic

**Interfaces:**
- Consumes: a `PttSink` callback `start()` / `stop()` (the pipeline implements this in Task 13).
- Produces: `pub fn register(app: &AppHandle)` registering `Cmd+Shift+D`; on `Pressed` calls a shared handler that starts capture, on `Released` stops; a pure `DoubleTap` helper deciding toggle vs hold. `pub const DEFAULT_SHORTCUT`.
- Pure helper: `pub struct DoubleTap { last_press_ms: Option<u64>, latched: bool }` with `fn on_press(&mut self, now_ms: u64) -> PressAction` where `enum PressAction { StartHold, ToggleOn, ToggleOff }` and `fn on_release(&mut self) -> ReleaseAction { Stop, Ignore }`.

- [ ] **Step 1: Add the plugin**

```bash
cd ~/murmur/src-tauri && cargo add tauri-plugin-global-shortcut
cd ~/murmur && npm install @tauri-apps/plugin-global-shortcut
```

- [ ] **Step 2: Write failing tests for the double-tap state machine**

`src-tauri/src/hotkey.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lone_press_then_release_is_hold() {
        let mut d = DoubleTap::default();
        assert_eq!(d.on_press(1000), PressAction::StartHold);
        assert_eq!(d.on_release(), ReleaseAction::Stop);
    }
    #[test]
    fn quick_second_tap_latches_toggle_on() {
        let mut d = DoubleTap::default();
        d.on_press(1000); d.on_release();
        // second press within 400ms => toggle ON (stay recording, ignore release)
        assert_eq!(d.on_press(1300), PressAction::ToggleOn);
        assert_eq!(d.on_release(), ReleaseAction::Ignore);
    }
    #[test]
    fn press_while_latched_toggles_off() {
        let mut d = DoubleTap::default();
        d.on_press(1000); d.on_release(); d.on_press(1300); d.on_release();
        assert_eq!(d.on_press(5000), PressAction::ToggleOff);
    }
}
```

- [ ] **Step 3: Run — verify fail**

Run: `cargo test hotkey::tests`
Expected: FAIL — types not found.

- [ ] **Step 4: Implement the state machine + registration**

```rust
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use std::sync::Mutex;

pub const DOUBLE_TAP_MS: u64 = 400;

#[derive(Debug, PartialEq)] pub enum PressAction { StartHold, ToggleOn, ToggleOff }
#[derive(Debug, PartialEq)] pub enum ReleaseAction { Stop, Ignore }

#[derive(Default)]
pub struct DoubleTap { last_release_ms: Option<u64>, latched: bool }

impl DoubleTap {
    pub fn on_press(&mut self, now_ms: u64) -> PressAction {
        if self.latched { self.latched = false; return PressAction::ToggleOff; }
        if let Some(prev) = self.last_release_ms {
            if now_ms.saturating_sub(prev) <= DOUBLE_TAP_MS {
                self.latched = true;
                return PressAction::ToggleOn;
            }
        }
        PressAction::StartHold
    }
    pub fn on_release(&mut self) -> ReleaseAction {
        if self.latched { return ReleaseAction::Ignore; }
        self.last_release_ms = Some(now_ms());
        ReleaseAction::Stop
    }
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// The pipeline implements this to receive start/stop edges.
pub trait PttSink: Send + Sync {
    fn start(&self, app: &AppHandle);
    fn stop(&self, app: &AppHandle);
}

pub fn register(app: &AppHandle, sink: std::sync::Arc<dyn PttSink>) -> tauri::Result<()> {
    let shortcut = Shortcut::new(Some(Modifiers::SUPER | Modifiers::SHIFT), Code::KeyD);
    let state = std::sync::Arc::new(Mutex::new(DoubleTap::default()));
    let sink2 = sink.clone();
    app.plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_handler(move |app, sc, event| {
                if sc != &shortcut { return; }
                let mut st = state.lock().unwrap();
                match event.state() {
                    ShortcutState::Pressed => match st.on_press(now_ms()) {
                        PressAction::StartHold | PressAction::ToggleOn => {
                            let _ = app.emit("hud-state", "recording");
                            sink2.start(app);
                        }
                        PressAction::ToggleOff => { sink2.stop(app); }
                    },
                    ShortcutState::Released => {
                        if st.on_release() == ReleaseAction::Stop { sink2.stop(app); }
                    }
                }
            })
            .build(),
    )?;
    app.global_shortcut().register(shortcut)?;
    Ok(())
}
```

Add `mod hotkey;` to `lib.rs`.

- [ ] **Step 5: Run — verify pass**

Run: `cargo test hotkey::tests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: global hotkey with hold + double-tap toggle state machine"
```

---

## Task 13: Pipeline orchestration (end-to-end dictation)

**Files:**
- Create: `src-tauri/src/pipeline.rs`
- Modify: `src-tauri/src/lib.rs`, `src/lib/ipc.ts`
- Test: inline `#[cfg(test)]` for the assemble-result helper

**Interfaces:**
- Consumes: `audio::start_capture/Capture::stop`, `resample::resample_linear`, `stt::default_engine`, `cleanup::default_cleanup`, `insert::insert_text`, `model::model_path`, `windows::{show_hud,hide_hud}`, `hotkey::{register, PttSink}`.
- Produces: `pub struct Pipeline` implementing `PttSink`; on `start()` begins capture + HUD; on `stop()` runs resample→stt→cleanup→insert on a worker thread, emits `vu-level`, `hud-state`, and `dictation-complete { raw, clean, app }`. `pub fn init(app: &AppHandle)` constructs the Pipeline, registers the hotkey, and spawns the level-meter ticker.

- [ ] **Step 1: Write failing test for the result payload helper**

`src-tauri/src/pipeline.rs`:

```rust
use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct DictationResult { pub raw: String, pub clean: String, pub app: Option<String> }

/// Pure helper: decide whether a result is insertable (non-empty clean text).
pub fn is_insertable(r: &DictationResult) -> bool { !r.clean.trim().is_empty() }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn empty_clean_is_not_insertable() {
        assert!(!is_insertable(&DictationResult{ raw:"um".into(), clean:"".into(), app:None }));
    }
    #[test] fn real_text_is_insertable() {
        assert!(is_insertable(&DictationResult{ raw:"hi".into(), clean:"Hi.".into(), app:None }));
    }
}
```

- [ ] **Step 2: Run — verify fail**

Run: `cargo test pipeline::tests`
Expected: FAIL — module not in `lib.rs`.

- [ ] **Step 3: Implement the pipeline**

```rust
use crate::{audio, cleanup, hotkey::{self, PttSink}, insert, model, resample, stt, windows};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

pub struct Pipeline {
    capture: Arc<Mutex<Option<audio::Capture>>>,
}

impl Pipeline {
    fn new() -> Self { Self { capture: Arc::new(Mutex::new(None)) } }
}

impl PttSink for Pipeline {
    fn start(&self, app: &AppHandle) {
        match audio::start_capture() {
            Ok(cap) => {
                // level-meter ticker
                let level = cap.level.clone();
                let app2 = app.clone();
                let cap_flag = self.capture.clone();
                std::thread::spawn(move || {
                    while cap_flag.lock().unwrap().is_some() {
                        let l = *level.lock().unwrap();
                        let _ = app2.emit("vu-level", l);
                        std::thread::sleep(std::time::Duration::from_millis(60));
                    }
                });
                *self.capture.lock().unwrap() = Some(cap);
                windows::show_hud(app);
            }
            Err(e) => { let _ = app.emit("dictation-error", e.to_string()); }
        }
    }

    fn stop(&self, app: &AppHandle) {
        let cap = self.capture.lock().unwrap().take();
        let Some(cap) = cap else { return; };
        let (sample_rate, channels) = (cap.sample_rate, cap.channels);
        let interleaved = cap.stop();
        let app = app.clone();
        // heavy work off the event thread
        std::thread::spawn(move || {
            let _ = app.emit("hud-state", "transcribing");
            let mono = if channels >= 2 { audio::stereo_to_mono(&interleaved) } else { interleaved };
            let audio16k = resample::resample_linear(&mono, sample_rate, 16000);

            let engine = stt::default_engine(model::model_path(&app));
            let raw = match engine.transcribe(&audio16k, "") {
                Ok(t) => t,
                Err(e) => { let _ = app.emit("dictation-error", e.to_string());
                            let _ = app.emit("hud-state", "idle");
                            windows::hide_hud(&app); return; }
            };
            let clean = cleanup::default_cleanup().clean(&raw);
            let result = DictationResult { raw: raw.clone(), clean: clean.clone(), app: None };

            // always surface + persist, even if not inserted
            let _ = app.emit("dictation-complete", result.clone());
            if is_insertable(&result) {
                if let Err(e) = insert::insert_text(&clean) {
                    let _ = app.emit("dictation-error", e);
                }
            } else {
                let _ = app.emit("dictation-empty", ());
            }
            let _ = app.emit("hud-state", "idle");
            windows::hide_hud(&app);
        });
    }
}

pub fn init(app: &AppHandle) {
    let pipeline: Arc<dyn PttSink> = Arc::new(Pipeline::new());
    if let Err(e) = hotkey::register(app, pipeline) {
        eprintln!("hotkey registration failed: {e}");
    }
}
```

Add `mod pipeline;` and call `pipeline::init(app.handle());` at the end of `.setup(...)`. Add the `Serialize` derive dep: `cargo add serde --features derive` (already present via tauri; ensure it's a direct dep).

- [ ] **Step 4: Run — verify unit test passes + builds**

Run: `cargo test pipeline::tests && cargo build`
Expected: PASS (2 tests) and a successful build.

- [ ] **Step 5: END-TO-END manual verification (the milestone gate)**

1. `npm run tauri dev`; complete onboarding (mic + accessibility granted, model downloaded).
2. Open TextEdit, click into a document.
3. Hold **⌘⇧D**, say "hello world this is a test of murmur", release.
4. Expected: HUD appears showing "Recording…" with a moving level bar; on release it shows "Transcribing…", then within ~1–3s the cleaned text ("Hello world this is a test of murmur.") is pasted at the cursor; HUD hides; your prior clipboard contents are intact (copy something first, dictate, then ⌘V elsewhere to confirm it was restored).
5. Double-tap ⌘⇧D to latch hands-free; speak; double-tap again to stop+insert.
6. Say nothing and release: nothing is inserted (no garbage).

- [ ] **Step 6: Commit**

```bash
cd ~/murmur && git add -A && git commit -m "M1: end-to-end dictation pipeline (capture→whisper→cleanup→paste)"
```

---

## Task 14: History persistence + menubar recent list

**Files:**
- Create: `src/components/HistoryList.tsx`
- Modify: `src/App.tsx`, `src/lib/ipc.ts`, `src/lib/db.ts` (reuse Task 2)
- Test: `src/__tests__/history.test.tsx`

**Interfaces:**
- Consumes: `dictation-complete` event payload `{ raw, clean, app }`; `src/lib/db.ts` (`insertTranscript`, `listTranscripts`, `deleteTranscript`).
- Produces: a `useDictationHistory()` effect that writes each completed dictation to SQLite and refreshes; `<HistoryList/>` showing recent items with copy + delete.

- [ ] **Step 1: Write the failing test**

`src/__tests__/history.test.tsx`:

```tsx
import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

let completeCb: (p: any) => void = () => {};
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (name: string, cb: (e: { payload: any }) => void) => {
    if (name === "dictation-complete") completeCb = (p) => cb({ payload: p });
    return () => {};
  }),
}));
const rows: any[] = [];
vi.mock("../lib/db", () => ({
  insertTranscript: vi.fn(async (raw, clean, app) => { rows.unshift({ id: rows.length+1, raw_text: raw, clean_text: clean, app_name: app, created_at: "now" }); }),
  listTranscripts: vi.fn(async () => rows.slice()),
  deleteTranscript: vi.fn(async () => {}),
}));

import { HistoryList } from "../components/HistoryList";

describe("HistoryList", () => {
  it("appends a completed dictation", async () => {
    render(<HistoryList />);
    completeCb({ raw: "raw", clean: "Hello there.", app: "TextEdit" });
    await waitFor(() => expect(screen.getByText("Hello there.")).toBeTruthy());
  });
});
```

- [ ] **Step 2: Run — verify fail**

Run: `npx vitest run src/__tests__/history.test.tsx`
Expected: FAIL — cannot find `../components/HistoryList`.

- [ ] **Step 3: Implement `HistoryList.tsx`**

```tsx
import { useEffect, useState, useCallback } from "react";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { insertTranscript, listTranscripts, deleteTranscript, type Transcript } from "../lib/db";

export function HistoryList() {
  const [rows, setRows] = useState<Transcript[]>([]);
  const refresh = useCallback(async () => setRows(await listTranscripts(50)), []);

  useEffect(() => {
    refresh();
    const un = listen<{ raw: string; clean: string; app: string | null }>(
      "dictation-complete",
      async (e) => { await insertTranscript(e.payload.raw, e.payload.clean, e.payload.app); refresh(); },
    );
    return () => { un.then((f) => f()); };
  }, [refresh]);

  return (
    <div className="p-4 space-y-2">
      <h2 className="font-semibold">Recent dictations</h2>
      {rows.length === 0 && <p className="text-sm opacity-60">No dictations yet. Hold ⌘⇧D to start.</p>}
      {rows.map((r) => (
        <div key={r.id} className="flex items-start justify-between gap-3 border-b py-2">
          <span className="text-sm">{r.clean_text}</span>
          <div className="flex gap-2 shrink-0">
            <button onClick={() => writeText(r.clean_text)} title="Copy">⧉</button>
            <button onClick={async () => { await deleteTranscript(r.id); refresh(); }} title="Delete">✕</button>
          </div>
        </div>
      ))}
    </div>
  );
}
```

Install the clipboard plugin for the copy button:

```bash
cd ~/murmur/src-tauri && cargo add tauri-plugin-clipboard-manager
cd ~/murmur && npm install @tauri-apps/plugin-clipboard-manager
```

Register it in `lib.rs` (`.plugin(tauri_plugin_clipboard_manager::init())`) and add `clipboard-manager:allow-write-text` to capabilities.

- [ ] **Step 4: Mount it in the settings view**

In `App.tsx`, replace the settings placeholder with `<HistoryList />` (and keep room for real settings later).

- [ ] **Step 5: Run — verify pass**

Run: `npx vitest run src/__tests__/history.test.tsx`
Expected: PASS.

- [ ] **Step 6: Verify on device**

Run: `npm run tauri dev`. Dictate something (Task 13 flow), open Settings from the tray, confirm the dictation appears in "Recent dictations"; the copy button puts it on the clipboard; delete removes it; restarting the app still shows prior rows (persisted in SQLite).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "M1: dictation history persistence + recent list in settings"
```

---

## Milestone exit criteria

M0+M1 are done when, on a clean machine:
1. Launching Murmur shows a menubar icon and no Dock icon.
2. First run walks the user through mic + accessibility grants and a one-time model download.
3. Holding ⌘⇧D records (HUD shows live level), releasing transcribes on-device and pastes cleaned text at the cursor in any focused app, with the prior clipboard restored.
4. Double-tap ⌘⇧D toggles hands-free dictation.
5. Silence/failed transcription inserts nothing and signals empty.
6. Every dictation is saved to searchable history and survives restart.
7. `cargo test` and `npx vitest run` both pass.

---

## Self-Review

**Spec coverage** (against `2026-06-27-murmur-dictation-app-design.md`):
- §3 platform/stack (Tauri, macOS, local whisper, hold+toggle, Keychain, SQLite) → Tasks 1–14. ✓
- §4.1 native modules: hotkey→T12, audio→T5, stt→T8, cleanup→T9, insertion→T10, secrets→T3, store→T2. `context` (frontmost app) is M5 per spec, intentionally absent here. ✓
- §4.2 UI surfaces: menubar→T1/T14, HUD→T11, settings shell→T4/T14, onboarding→T4/T7. ✓
- §5 data flow → T13 (raw emitted+persisted before insertion; clipboard restore). ✓
- §6 AI pipeline: trait abstraction (`SttEngine`/`CleanupEngine`)→T8/T9; `initial_prompt` plumbed (empty in M1, dictionary feeds it in M3). ✓
- §7 error handling: no-mic/no-ax→T4; model missing→T7; empty/garbled→T9/T13; crash safety (persist raw)→T13/T14. Ollama/cloud fallbacks are M2, not here. ✓
- §8 milestones: this plan is exactly M0+M1. ✓
- §9 testing: Rust unit tests (helpers/engines/state machine), Vitest+RTL (onboarding/HUD/history), manual E2E checklist. ✓

**Placeholder scan:** no TBD/TODO; every code step contains real code; manual-verification steps used only where unit tests would assert nothing (native side-effects), with exact expected behavior. ✓

**Type consistency:** `SttEngine::transcribe(&[f32], &str)`, `CleanupEngine::clean(&str)->String`, `DictationResult { raw, clean, app }`, `DoubleTap`/`PressAction`/`ReleaseAction`, `insert_text(&str)`, `model_path(&AppHandle)` are referenced consistently across T8/T9/T10/T12/T13. Event names (`hud-state`, `vu-level`, `dictation-complete`, `model-progress`) match between Rust emit and JS listen. ✓

**Known verification points carried from research (confirm at implementation, not blockers):**
- `WhisperContextParameters::use_gpu` builder name on whisper-rs 0.16 (T8) — check docs.rs if it doesn't compile.
- global-shortcut modifier-release timing for hold-to-talk on macOS (T12) — validate in the T13 on-device smoke.
- `keyring` repeated dev-signing keychain prompts (T3) — expected with ad-hoc signing; resolved by Developer ID signing in M7.
