# Murmur

Hold a key, speak, and transcribed + cleaned-up text pastes at your cursor. A local-first
voice dictation tray app — on-device Whisper by default, bring-your-own-key cloud STT optional.

Tauri 2 + React + TypeScript. macOS, Linux on Omarchy/Hyprland, and a Windows port in progress
(W0 — compiles and tests green on both platforms, see
[docs/superpowers/plans/2026-07-25-murmur-windows-port.md](docs/superpowers/plans/2026-07-25-murmur-windows-port.md)).
Deep architecture + gotchas: [docs/HANDOFF.md](docs/HANDOFF.md).

## Linux / Omarchy

See [the Linux installation guide](docs/LINUX.md) for native local dictation,
Wayland paste, and a desktop launcher with Ctrl+Alt+D push-to-talk.

## Build prerequisites

Library dependencies come from lockfiles (`npm ci`, cargo) — nothing to chase manually.
The host toolchain is what you need up front:

| Tool | Version | Why |
|---|---|---|
| Node.js | 22.x (CI pin) | Vite/TypeScript frontend |
| Rust | stable | Tauri backend |
| CMake | any recent | whisper-rs compiles whisper.cpp at build time |
| LLVM (libclang) | any recent | bindgen generates whisper's C bindings — Windows needs `LIBCLANG_PATH` set (macOS gets it from Xcode CLT) |
| C++ toolchain | per-OS, below | linker + native compile |

> CI green does **not** prove a clean machine builds: GitHub runners preinstall
> LLVM and CMake. The bootstrap script installs everything explicitly.

**Windows:** run the bootstrap script — it installs everything above (Node 22 straight
from nodejs.org since winget lacks v22, the rest via winget; the VS 2022 Build Tools C++
workload ≈ 6 GB is the C++ toolchain) and verifies each step. A non-admin prompt is fine;
expect UAC prompts as the installers elevate themselves:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
```

**macOS:** Xcode Command Line Tools (`xcode-select --install`), then
`brew install cmake node@22` (keg-only — follow brew's printed PATH caveat), and Rust
via the official installer (matches [docs/HANDOFF.md](docs/HANDOFF.md), which sources
`$HOME/.cargo/env`; homebrew's `rustup` formula is keg-only and won't be on PATH):

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
```

## Build & test

Same order as CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) — and the order matters:
`tauri::generate_context!` embeds `../dist` at compile time, so the frontend **must** be built
before any cargo step.

```sh
npm ci
npx vitest run                                    # frontend tests
npm run build                                     # tsc + vite -> dist/
cargo test  --manifest-path src-tauri/Cargo.toml  # Rust tests (compiles whisper.cpp; first run 10+ min)
cargo build --features custom-protocol --manifest-path src-tauri/Cargo.toml
```

Dev loop: `npm run tauri dev`. On macOS, permission-sensitive features (mic, input
monitoring) need a signed bundle instead — see [docs/HANDOFF.md](docs/HANDOFF.md).

Packaged builds: macOS `npm run tauri build` produces the `.app` bundle. Windows
packaging (NSIS installer, signing) is milestone W4 of the port plan — until then, use
`npm run tauri build -- --no-bundle` for a bare `.exe`.

## Recommended IDE Setup

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)
