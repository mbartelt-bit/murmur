#!/usr/bin/env python3
"""Install a built Murmur release for the current Omarchy user (no root)."""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

repo = Path(__file__).resolve().parent.parent
home = Path.home()
config = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
data = Path(os.environ.get('XDG_DATA_HOME', home / '.local/share'))
binary = repo / 'src-tauri/target/release/murmur'
if not binary.is_file():
    sys.exit('Build first: npm ci && npm run build && cargo build --release --features custom-protocol --manifest-path src-tauri/Cargo.toml')
# Reject a development build before touching desktop integration.
subprocess.run([str(binary), '--check-install'], check=True)
if not (config / 'hypr/hyprland.lua').is_file():
    sys.exit('This installer requires Omarchy with Hyprland Lua configuration.')
for command in ['hyprctl', 'wl-copy', 'wl-paste', 'systemctl']:
    if not shutil.which(command):
        sys.exit(f'Missing dependency: {command}')
# Never shadow an unrelated shortcut. Existing Murmur bindings are safe to refresh.
binds = json.loads(subprocess.check_output(['hyprctl', 'binds', '-j']))
for bind in binds:
    if bind.get('modmask') == 12 and bind.get('key', '').lower() == 'd':
        if not bind.get('description', '').startswith('Murmur'):
            sys.exit('Ctrl+Alt+D is already assigned. Choose another binding before installing.')

stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() != content:
        shutil.copy2(path, path.with_name(path.name + '.bak.' + stamp))
    path.write_text(content)
    path.chmod(mode)

appdir = data / 'murmur'
appdir.mkdir(parents=True, exist_ok=True)
# Replace atomically so an existing running executable can be upgraded.
shutil.copy2(binary, appdir / 'murmur.new')
(appdir / 'murmur.new').chmod(0o755)
(appdir / 'murmur.new').replace(appdir / 'murmur')
shutil.copy2(repo / 'src-tauri/icons/icon.png', appdir / 'icon.png')
import shlex
write(home / '.local/bin/murmur', '#!/bin/sh\nexec ' + shlex.quote(str(appdir / 'murmur')) + ' "$@"\n', 0o755)
write(data / 'applications/com.murmur.app.desktop', f'''[Desktop Entry]
Type=Application
Name=Murmur
Comment=Local voice dictation — hold Ctrl+Alt+D
Exec="{appdir / 'murmur'}" --show-settings
Icon={appdir / 'icon.png'}
Terminal=false
Categories=AudioVideo;Audio;Utility;
StartupWMClass=murmur
''')
# Keep all integration in one user-owned Lua module; package defaults stay untouched.
module = config / 'hypr/murmur.lua'
write(module, '''-- Murmur integration, installed by scripts/install-omarchy.py
local murmur = os.getenv("HOME") .. "/.local/bin/murmur"
local down = false
hl.unbind("CTRL + ALT + D")
o.bind("CTRL + ALT + D", "Murmur — hold to dictate", function()
  if not down then
    down = true
    hl.dispatch(hl.dsp.exec_cmd(string.format("%q --ptt-press", murmur)))
  end
end)
-- Match release even when Ctrl/Alt were released before D. Let normal D releases through.
o.bind("D", "Murmur — finish dictation", function()
  if down then
    down = false
    hl.dispatch(hl.dsp.exec_cmd(string.format("%q --ptt-release", murmur)))
  end
end, { release = true, ignore_mods = true, non_consuming = true })
o.window({ title = "^Murmur HUD$" }, {
  float = true, pin = true, no_focus = true, no_follow_mouse = true,
  no_anim = true, no_blur = true, no_shadow = true, border_size = 0,
  size = { 260, 72 }, move = { "(monitor_w - window_w) / 2", "monitor_h - window_h - 80" },
})
''')
main = config / 'hypr/hyprland.lua'
source = main.read_text()
if 'require("hypr.murmur")' not in source:
    write(main, source.rstrip() + '\n\n-- Local voice dictation\nrequire("hypr.murmur")\n')
subprocess.run(['hyprctl', 'reload'], check=True)
errors = subprocess.check_output(['hyprctl', 'configerrors'], text=True).strip()
if errors:
    sys.exit('Hyprland reported errors; backups were saved. Resolve before starting Murmur:\n' + errors)
write(config / 'systemd/user/murmur.service', f'''[Unit]
Description=Murmur local voice dictation
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart="{appdir / 'murmur'}" --background
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
''')
subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
subprocess.run(['systemctl', '--user', 'enable', 'murmur.service'], check=True)
subprocess.run(['systemctl', '--user', 'restart', 'murmur.service'], check=True)
# systemctl returns before the process has reserved its control socket. Wait
# before telling the user to launch it, avoiding a second process winning startup.
for _ in range(100):
    if subprocess.run([str(appdir / 'murmur'), '--status'],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        break
    time.sleep(0.1)
else:
    sys.exit('Murmur did not start. Check: journalctl --user -u murmur -n 60')
print('Installed Murmur. Open it from the app menu. Hold Ctrl+Alt+D to dictate.')
