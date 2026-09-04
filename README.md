# Murmur

Voice dictation that stays out of the way. On macOS it lives in the menubar: hold a hotkey, speak,
and Murmur transcribes (local Whisper or a BYOK cloud provider), cleans the text up, and pastes it at
your cursor — no Dock icon, keys in the Keychain, history in local SQLite. **iOS and Android are in
progress**: the provider-agnostic pipeline now lives in the Rust crate `crates/murmur-core` and
reaches Swift and Kotlin through UniFFI, with app shells building on both platforms.

## Desktop (macOS)

```bash
npm ci && . "$HOME/.cargo/env"
APPLE_SIGNING_IDENTITY="Murmur Dev" npm run tauri build -- --debug
open target/debug/bundle/macos/Murmur.app
```

Build a **signed** bundle, not `npm run tauri dev` — macOS attributes an unsigned dev binary's
permissions to the launching terminal, which breaks the mic and the hotkey event tap.
[`docs/HANDOFF.md`](docs/HANDOFF.md) is the real entry point: architecture, the signing cert, the
permission gotchas, and the full test/build gate. [`HERMES.md`](HERMES.md) walks a fresh Mac from
clone to first dictation.

## Mobile (iOS + Android)

```bash
scripts/build-core-mobile.sh ios      # MurmurCore.xcframework + Swift bindings
scripts/build-core-mobile.sh android  # jniLibs/*.so + Kotlin bindings
```

Then `xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'platform=iOS
Simulator,name=iPhone 17' test`, or `cd android && ./gradlew assembleDebug testDebugUnitTest`.

- [`apple/README.md`](apple/README.md) — iOS app, XcodeGen project, why the framework must exist
  before the first build
- [`android/README.md`](android/README.md) — Gradle module, prerequisites, emulator run
- [`scripts/README.md`](scripts/README.md) — what the build script produces
- Design spec: [`docs/superpowers/specs/2026-09-03-murmur-mobile-design.md`](docs/superpowers/specs/2026-09-03-murmur-mobile-design.md)
- MM0 plan: [`docs/superpowers/plans/2026-09-03-murmur-mobile-mm0.md`](docs/superpowers/plans/2026-09-03-murmur-mobile-mm0.md)
