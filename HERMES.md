# Murmur — Build Handoff (for the Hermes agent on a fresh Mac)

You are setting up **Murmur** — a macOS menubar voice-dictation app (hold a hotkey, speak, it
transcribes and pastes the text at your cursor) — on this machine, from a clean checkout, for the
person you're working with. This file is self-contained: everything you need is here or in
`docs/HANDOFF.md` (architecture + deep gotchas). Written 2026-07-23 against `main` @ `d2e2a41`.

**Definition of done:** a signed `Murmur.app` in `/Applications`, onboarding completed (permissions
granted, an STT engine connected), and one successful end-to-end dictation: hold the hotkey → speak
→ text pastes into a real app (e.g. Notes).

---

## 0. Ground rules for the agent

- **This is a macOS-only app.** If this machine is not a Mac, stop and report that.
- **Apple Silicon is the happy path.** On an Intel Mac the local-Whisper Metal build may fail or be
  slow — that's fine: skip the local model and use the **Groq cloud engine** (free tier, no credit
  card) in step 6 instead.
- **Never run `npm run tauri dev` as a long-running agent process.** It launches a GUI app attached
  to your terminal, which also breaks macOS permission attribution. Always build the signed bundle
  (step 5) and `open` it.
- **Several steps pop GUI dialogs only the human can click** (Keychain "Always Allow", microphone /
  Accessibility / Input Monitoring prompts). They're marked **[HUMAN]** below — pause and ask her to
  click, then continue.
- Use **her** accounts everywhere (GitHub, Groq). Do not ask for or store anyone else's credentials.

## 1. Prerequisites / toolchain

Check what exists before installing (`which brew git node cargo cmake`). Install what's missing:

```bash
# Xcode Command Line Tools (compilers, codesign, git) — [HUMAN] clicks the install dialog
xcode-select --install

# Homebrew — https://brew.sh (the standard one-liner); then:
brew install cmake gh node        # cmake is REQUIRED (whisper.cpp build); node = LTS is fine

# Rust (rustup, stable)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. "$HOME/.cargo/env"
```

## 2. Clone

The repo is **public**: `https://github.com/mbartelt-bit/murmur`. No GitHub account or auth is
needed to clone and build:

```bash
git clone https://github.com/mbartelt-bit/murmur.git ~/murmur
cd ~/murmur
npm ci
```

(A GitHub account is only needed if she later wants to push changes back — then `gh auth login`
with her account and ask Matt for collaborator access, or fork and PR.)

## 3. Sanity check the checkout (optional but cheap)

```bash
cd ~/murmur/src-tauri && . "$HOME/.cargo/env" && cargo test    # expect ~38 tests green (slow first time — compiles whisper.cpp)
cd ~/murmur && npx vitest run                                  # expect ~24 tests green
```

## 4. Create the local code-signing cert (one-time, machine-local)

Murmur must be signed with a stable local identity so macOS permission grants survive rebuilds
(ad-hoc builds reset Mic/Accessibility grants on every rebuild). Create a self-signed cert named
**"Murmur Dev"** on THIS machine:

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
security find-identity -p codesigning | grep -i murmur   # verify it's there
```

The cert does NOT need to be trusted as a root — untrusted is fine for TCC. The **first build** will
pop a Keychain dialog: **[HUMAN]** clicks **"Always Allow"** (once, forever).

## 5. Build the signed app + install

```bash
cd ~/murmur && . "$HOME/.cargo/env"
APPLE_SIGNING_IDENTITY="Murmur Dev" npm run tauri build -- --debug
# first build is long (whisper.cpp compile). Then:
cp -R src-tauri/target/debug/bundle/macos/Murmur.app /Applications/
open /Applications/Murmur.app
```

Install to `/Applications` (not just `open` from `target/`) so cleanup tools that wipe build dirs
can't delete the app she's using. Rebuild + reinstall later with the same three lines; grants persist
because the cert is stable. For an optimized build drop `--debug` (slower compile, faster app) —
the bundle then lands in `target/release/bundle/macos/`.

## 6. First run — onboarding (mostly [HUMAN])

Murmur has **no Dock icon** — look for the menubar icon (top-right). Onboarding asks for, in order:

1. **Microphone** — click "Allow microphone" in the app; a system prompt appears → Allow.
2. **Accessibility** — needed to paste at the cursor. System Settings toggle; the app deep-links there.
3. **Input Monitoring** — needed for the fn-key push-to-talk. Same dance.
4. **STT engine** — pick ONE:
   - **Groq (recommended, free, no card):** in the app, "Get your API key ↗" opens Groq's site —
     she signs up with her Google/GitHub account, creates an API key, pastes it in the app. It
     validates live (✓ Connected) and stores the key in HER macOS Keychain. **Never send API keys
     over email/text — she creates her own.**
   - **Local Whisper (offline, $0, Apple Silicon):** the app downloads a 142MB model. No account.
5. After granting permissions, use the **Restart Murmur** button (or quit from the menubar and
   `open /Applications/Murmur.app`) — grants are only re-read at launch.

One macOS setting worth fixing now: **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**,
otherwise holding fn pops the emoji picker instead of dictating.

## 7. Verify end-to-end

**[HUMAN]:** open Notes, click into a note, **hold the fn (globe) key**, say a sentence, release.
The text should paste at the cursor. (Alternative hotkey: **⌃⌥D**, configurable in settings.)

If it "works" but pastes `You.` or `you` — that's Whisper's output for **silence**: the mic feed is
blocked, not the paste. See troubleshooting. To inspect what was captured:

```bash
sqlite3 ~/Library/Application\ Support/com.murmur.app/murmur.db \
  "select id,created_at,raw_text from transcripts order by id desc limit 5;"
```

The app also writes a startup permission snapshot to
`~/Library/Application Support/com.murmur.app/diag.log` — read it before guessing at permission state.

## 8. Troubleshooting (known failure modes — check these before debugging code)

| Symptom | Cause | Fix |
|---|---|---|
| Transcripts are all `You.` / `you` | Mic blocked (hardened-runtime entitlement or TCC) | Entitlement is already in the repo (`src-tauri/entitlements.plist`); reset TCC: `tccutil reset Microphone com.murmur.app`, relaunch, re-grant via the in-app button |
| Permission shows enabled but doesn't work | Stale TCC row from an old build identity | `tccutil reset Accessibility com.murmur.app` (also `ListenEvent` = Input Monitoring), relaunch, re-grant |
| Toggling in System Settings has no effect | Grants read only at launch | Relaunch the app |
| Mic can't be added manually in Settings | macOS requires the app to *request* it | `tccutil reset Microphone com.murmur.app` → relaunch → click "Allow microphone" in-app |
| Holding fn opens emoji picker | 🌐-key setting | System Settings → Keyboard → "Press 🌐 key to" → Do Nothing |
| Port 1420 in use (only if you ran dev) | stray dev server | `lsof -ti tcp:1420 \| xargs kill -9; pkill -f target/debug/murmur` |
| Cert missing (`security find-identity` empty) | new machine / keychain reset | Re-run step 4 |
| Random login-password prompt at launch | Keychain item owned by an old build identity | `security delete-generic-password -s com.murmur.app -a groq_api_key`, re-enter the key in the app |

## 9. If you go beyond building — developing on this machine

- Read `docs/HANDOFF.md` first: full architecture map, per-file responsibilities, and hard-won
  gotchas (cpal `Stream` is `!Send`; HUD window must not import settings CSS; keyring pinned to v3;
  event names must match across Rust and JS; cloud cleanup always falls back to rule cleanup).
- Product spec + roadmap: `docs/superpowers/specs/2026-06-27-murmur-dictation-app-design.md`.
- Branch for changes; `main` is the shared trunk with Matt's machine — push feature branches, don't
  force-push main.
- CI-equivalent before any push: `cargo test` (src-tauri), `npx vitest run`, `npm run build`,
  `cargo build`.
