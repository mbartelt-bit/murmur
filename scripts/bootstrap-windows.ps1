# Murmur - Windows build bootstrap
#
# Installs the host toolchain needed to build Murmur on Windows 10/11:
#   Node.js 22 (CI-pinned major), Rust (stable, MSVC), VS 2022 Build Tools
#   (C++ workload = MSVC linker + Windows SDK), CMake (whisper.cpp),
#   LLVM (libclang for bindgen).
#
# Library deps are NOT handled here - `npm ci` and cargo pull those from
# lockfiles. This script only covers what a package manager can't: the
# compilers. Verified end-to-end on Windows 10 Home (2026-07-25).
# Idempotent: re-run safely; anything present is skipped.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
# Needs:  winget (App Installer - preinstalled on current Win 10/11), ~8 GB disk.
#         A normal (non-admin) prompt is fine, but expect UAC prompts: winget,
#         the Node MSI, and the VS installer each elevate themselves.

$ErrorActionPreference = 'Stop'
# PS 5.1's Invoke-WebRequest redraws its progress bar on every buffer read,
# slowing downloads 10-100x. Kill it for the whole script.
$ProgressPreference = 'SilentlyContinue'

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                "$env:USERPROFILE\.cargo\bin"
}

# PS 5.1 never throws on a native exe's non-zero exit ($ErrorActionPreference
# does not apply) - so every winget call must be followed by this.
function Assert-Winget {
    if ($LASTEXITCODE -ne 0) {
        throw ('winget failed with exit code 0x{0:X8} - see its output above. If it requested a reboot, reboot and re-run this script.' -f $LASTEXITCODE)
    }
}

function Step($name, $check, $install) {
    Write-Host "== $name" -ForegroundColor Cyan
    Update-Path
    if (& $check) { Write-Host "   already present, skipping" -ForegroundColor DarkGray; return }
    & $install
    Update-Path
    if (-not (& $check)) {
        throw "${name}: still not detected after the install step. If the output above shows a successful install, open a NEW terminal and re-run (PATH changes don't reach an already-open shell); otherwise fix the error reported above and re-run."
    }
    Write-Host "   OK" -ForegroundColor Green
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

# -- Node.js 22 --------------------------------------------------------------
# CI pins node-version: 22 (.github/workflows/ci.yml). winget only carries
# newer LTS lines, so fetch the v22 MSI from nodejs.org directly.
Step 'Node.js 22' {
    $n = Get-Command node -ErrorAction SilentlyContinue
    $n -and ((& node --version) -match '^v22\.')
} {
    $html = Invoke-WebRequest -Uri 'https://nodejs.org/dist/latest-v22.x/' -UseBasicParsing
    if ($html.Content -notmatch 'node-v(22\.\d+\.\d+)-x64\.msi') { throw 'could not resolve latest v22 MSI' }
    $ver = $Matches[1]
    $msi = Join-Path $env:TEMP "node-v$ver-x64.msi"
    Write-Host "   downloading node v$ver..."
    Invoke-WebRequest -Uri "https://nodejs.org/dist/v$ver/node-v$ver-x64.msi" -OutFile $msi -UseBasicParsing
    # Per-machine MSI: /qn suppresses the UI that would raise the UAC prompt,
    # so msiexec must be launched elevated explicitly (-Verb RunAs) or the
    # install dies with 1603/1925 from a non-admin shell.
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "node MSI failed: exit $($p.ExitCode)" }
}

# -- VS 2022 Build Tools (MSVC + Windows SDK) --------------------------------
# Rust's x86_64-pc-windows-msvc target needs link.exe; whisper.cpp needs cl.exe.
# ~6 GB, the long pole of this script (10-30 min depending on connection).
Step 'VS 2022 Build Tools (C++ workload)' {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    (Test-Path $vswhere) -and (& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath)
} {
    # If ANY VS instance already exists, winget no-ops ("no applicable
    # upgrade") and the --override never reaches the VS bootstrapper - the
    # C++ workload would never be added. Modify the existing install instead.
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
    $existing = $null
    if (Test-Path $vswhere) { $existing = & $vswhere -products '*' -latest -property installationPath }
    if ($existing -and (Test-Path $vsInstaller)) {
        Write-Host "   existing VS install found - adding C++ workload via vs_installer modify"
        $p = Start-Process $vsInstaller -ArgumentList "modify --installPath `"$existing`" --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --norestart --wait" -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "vs_installer modify failed: exit $($p.ExitCode)" }
    } else {
        winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget `
            --accept-source-agreements --accept-package-agreements --disable-interactivity `
            --override '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        Assert-Winget
    }
}

# -- CMake -------------------------------------------------------------------
# whisper-rs builds whisper.cpp at compile time; cmake is its host prereq
# (same requirement as `brew install cmake` on macOS - docs/HANDOFF.md).
Step 'CMake' {
    [bool](Get-Command cmake -ErrorAction SilentlyContinue)
} {
    winget install --id Kitware.CMake -e --source winget `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    Assert-Winget
}

# -- Rust (stable, MSVC host) ------------------------------------------------
Step 'Rust (rustup + stable toolchain)' {
    [bool](Get-Command rustc -ErrorAction SilentlyContinue)
} {
    winget install --id Rustlang.Rustup -e --source winget `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    Assert-Winget
}

# -- LLVM (libclang for bindgen) ---------------------------------------------
# whisper-rs-sys generates C bindings with bindgen, which needs libclang.dll.
# GitHub's windows runners have LLVM preinstalled, so CI green does NOT prove
# a clean PC builds - without this you get "Unable to find libclang" from the
# whisper-rs-sys build script. LIBCLANG_PATH is persisted at User scope,
# pointing at wherever libclang.dll actually is (never assumed blindly).
function Find-Libclang {
    $roots = @()
    foreach ($k in @('HKLM:\SOFTWARE\LLVM\LLVM', 'HKLM:\SOFTWARE\WOW6432Node\LLVM\LLVM')) {
        try { $v = (Get-ItemProperty $k -ErrorAction Stop).'(default)'; if ($v) { $roots += $v } } catch {}
    }
    $roots += "$env:ProgramFiles\LLVM"
    $roots += "${env:ProgramFiles(x86)}\LLVM"
    foreach ($root in $roots) {
        if ($root -and (Test-Path (Join-Path $root 'bin\libclang.dll'))) { return (Join-Path $root 'bin') }
    }
    return $null
}
Step 'LLVM (libclang)' {
    $lc = [Environment]::GetEnvironmentVariable('LIBCLANG_PATH', 'User')
    $lc -and (Test-Path (Join-Path $lc 'libclang.dll'))
} {
    $bin = Find-Libclang
    if (-not $bin) {
        winget install --id LLVM.LLVM -e --source winget `
            --accept-source-agreements --accept-package-agreements --disable-interactivity
        Assert-Winget
        $bin = Find-Libclang
    }
    if (-not $bin) { throw 'libclang.dll not found after LLVM install - locate your LLVM bin directory and set the LIBCLANG_PATH user environment variable to it, then re-run.' }
    [Environment]::SetEnvironmentVariable('LIBCLANG_PATH', $bin, 'User')
}

# -- WebView2 runtime --------------------------------------------------------
# Tauri's renderer. Preinstalled on current Win 10/11; install only if absent.
# Detection per Microsoft's documented procedure: pv value (non-empty and not
# 0.0.0.0) under HKLM (incl. WOW6432Node) or HKCU - per-user installs only
# register under HKCU, and a bare key with pv=0.0.0.0 means NOT installed.
Step 'WebView2 runtime' {
    $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $found = $false
    foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid")) {
        try {
            $pv = (Get-ItemProperty $k -ErrorAction Stop).pv
            if ($pv -and $pv -ne '0.0.0.0') { $found = $true; break }
        } catch {}
    }
    $found
} {
    winget install --id Microsoft.EdgeWebView2Runtime -e --source winget `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    Assert-Winget
}

# -- Summary -----------------------------------------------------------------
Update-Path
Write-Host "`n== Toolchain versions" -ForegroundColor Cyan
node --version; npm --version
cmake --version | Select-Object -First 1
rustc --version

Write-Host @'

Bootstrap complete. Open a NEW terminal (PATH changed), then:

  npm ci            # JS deps from lockfile
  npx vitest run    # frontend tests
  npm run build     # tsc + vite -> dist/  (MUST precede any cargo step:
                    #   tauri::generate_context! embeds ../dist at compile time)
  cargo test --manifest-path src-tauri/Cargo.toml
  cargo build --manifest-path src-tauri/Cargo.toml

First cargo build compiles whisper.cpp - expect 10+ minutes.
'@ -ForegroundColor Green

