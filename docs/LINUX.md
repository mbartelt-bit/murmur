# Murmur on Omarchy / Hyprland

Murmur can run natively on Linux. The desktop integration currently targets
**Omarchy with Hyprland Lua configuration (0.55+)**, using CPU Whisper,
PipeWire through ALSA, the desktop Secret Service keyring, and Wayland clipboard/input.
Other compositors need their own global key bindings and overlay rules.

## Install from source

On Omarchy, install the host dependencies in a terminal:

```sh
omarchy pkg add rust cmake clang base-devel webkit2gtk-4.1 alsa-lib \
  libayatana-appindicator librsvg openssl xdotool wl-clipboard
```

Node.js/npm and Python 3 are also required (already supplied by Omarchy).
Then, inside the checkout:

```sh
npm ci
npm run build
cargo build --release --features custom-protocol --manifest-path src-tauri/Cargo.toml
python3 scripts/install-omarchy.py
murmur
```

The first build compiles Whisper and WebKit bindings and can take several minutes.
The `custom-protocol` feature embeds the built interface so the installed app
does not need Vite or a localhost development server.
The installer requires a running Hyprland desktop, checks that Ctrl+Alt+D is free,
and saves timestamped backups before changing existing text configuration.
It installs only into your user directories:

- `~/.local/share/murmur/murmur`: release executable and icon
- `~/.local/bin/murmur`: command-line launcher
- `~/.local/share/applications/com.murmur.app.desktop`: app-menu entry
- `~/.config/hypr/murmur.lua`: shortcuts and non-focusing HUD rules
- `~/.config/systemd/user/murmur.service`: starts with the desktop session

The installer adds `require("hypr.murmur")` to your user Hyprland configuration,
validates it, then enables and starts the user service. Omarchy package files are
never modified. XDG config/data directory overrides are respected.
To upgrade, rebuild and run the same installer again.

Open Murmur from the app menu, select **Local**, and download the English base
model (~142 MB). No account or API key is needed for local transcription and rule
cleanup. Models, settings, and history live under
the standard XDG user directories: models and settings under
`${XDG_DATA_HOME:-~/.local/share}/com.murmur.app/`, and the history database under
`${XDG_CONFIG_HOME:-~/.config}/com.murmur.app/murmur.db`.
Cloud engines remain optional; their keys are saved in the unlocked desktop
Secret Service keyring, not in configuration files.

## Dictate

Focus a text field in the destination application. Hold **Ctrl+Alt+D**, speak,
and release D to transcribe and paste. Double-tap the shortcut to latch recording;
press it again to stop. Fn on a PC keyboard is usually handled by firmware and is
not the macOS globe-key recording trigger.

Close the settings window to keep Murmur running. Use the tray menu or app menu
to reopen it. The indicator floats near the bottom of the screen without taking
keyboard focus. Paste uses Hyprland's explicit-modifier key dispatch, with
Ctrl+Shift+V in recognized terminals (including
Omarchy's Foot) and Ctrl+V in other apps. Applications with custom paste bindings
may need manual paste from History. The previous clipboard representation is
restored after pasting unless you changed it in the meantime.

You can edit both recording bindings in `~/.config/hypr/murmur.lua`. The settings
UI documents the installed default; it does not rewrite compositor shortcuts.

## Troubleshooting

On Wayland, Murmur defaults `__NV_DISABLE_EXPLICIT_SYNC=1` before starting WebKit
to avoid the NVIDIA "Missing acquire timeline" / protocol-error crash
([WebKit issue 280210](https://bugs.webkit.org/show_bug.cgi?id=280210)).
An explicitly set environment value takes precedence. This affects only Murmur.

```sh
murmur --status
systemctl --user status murmur
journalctl --user -u murmur -n 60 --no-pager
hyprctl configerrors
```

Select the intended default microphone in Omarchy's audio controls. The app uses
ALSA's default input (PipeWire on Omarchy). If you change microphones, start a new
recording. The app must run in your desktop user session; do not launch with sudo.

`murmur --ptt-press` and `murmur --ptt-release` send recording edges to the running
app through a user-only socket in `$XDG_RUNTIME_DIR/murmur.sock`. They do not start
a second app or require access to `/dev/input`. `murmur --show-settings` opens the
existing app. `--background` starts without showing settings.

## Tests

```sh
npx vitest run
npm run build
cargo test --release --manifest-path src-tauri/Cargo.toml
# Optional live desktop keyring verification:
cargo test --release --manifest-path src-tauri/Cargo.toml roundtrip_and_delete -- --ignored
```

The real-model smoke test is opt-in: supply `MURMUR_TEST_MODEL` and
`MURMUR_TEST_AUDIO` (whisper.cpp's JFK sample converted to 16 kHz mono f32le),
then run `cargo test --release --manifest-path src-tauri/Cargo.toml
transcribes_real_sample_locally -- --ignored`.
Linux CI checks compilation and automated tests; it does not establish that
another compositor's global shortcuts or paste support work.

## Remove desktop integration

Stop and disable it with `systemctl --user disable --now murmur`. Remove the
`require("hypr.murmur")` line and the user files listed above, then run
`hyprctl reload` and `systemctl --user daemon-reload`. Keep `com.murmur.app` if you
want to preserve your history, settings, and model.
