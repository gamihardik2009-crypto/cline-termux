# Cline for Termux (Android)

`cline` — the Cline CLI (AI coding assistant) — packaged for **Termux on Android (ARM64 / aarch64)**, with no proot, no Node.js, and no manual runtime configuration.

## What this is

Cline's official CLI is a standalone Bun-compiled Linux/glibc binary. Termux uses Android's Bionic libc, so the binary cannot run there directly. This package bundles a small compatibility layer (the open-source [bun-termux](https://github.com/Happ1ness-dev/bun-termux) wrapper + shim) that runs the official Cline binary through Termux's glibc runtime. You just install and type `cline`.

## Requirements

- Android with **Termux** (from F-Droid or GitHub; not the Play Store build)
- **aarch64 / ARM64** device (almost all modern Android phones)
- Internet connection for installation

## Installation

Open Termux and run:

```bash
pkg install -y git && git clone https://github.com/gamihardik2009-crypto/cline-termux.git && cd cline-termux && bash install.sh
```

Or, if you already have the repo on your phone:

```bash
cd cline-termux
bash install.sh
```

The installer automatically:

1. Verifies you are on Termux + aarch64 (fails clearly otherwise)
2. Configures the official Termux **glibc repository** on fresh installs — it installs the `glibc-repo` package via `pkg`, or (when the main mirror is unconfigured) writes `$PREFIX/etc/apt/sources.list.d/glibc.list` directly with the official repo line — then installs the glibc runtime (`glibc-runner`) if the loader is not already present. Existing configurations are never overwritten unnecessarily.
3. Downloads the official Cline CLI binary from the npm registry (~50 MB) and verifies its SHA-256 checksum
4. Installs everything under `$PREFIX/lib/cline` and puts `cline` on your `$PATH`

## Usage

```bash
cline --version     # 3.0.61
cline --help
cline doctor
cd ~/my-project
cline               # start the interactive agent
```

Works from any directory. Your shell may need `hash -r` (or a new shell) if `cline` was just installed.

## Cline data location

Cline stores its data in `~/.cline` (inside Termux). Uninstalling this package does **not** delete it. To also remove user data: `bash uninstall.sh --purge-data`.

## Updating

Cline can check for updates online, but its self-update path assumes npm/Node-based installs and does not replace its own executable when installed as a standalone binary. **To update this package:** `git pull` in this repo (or re-clone it) and re-run `bash install.sh` — it downloads the newer pinned Cline version. Do not run `cline update` expecting it to modify the installation.

## Uninstall

```bash
cd cline-termux
bash uninstall.sh
```

## TTY requirement

Interactive commands (e.g. `cline config`, the agent UI) need a real TTY. Run them from a normal Termux shell session, not through pipes or some remote one-shot commands.

## Known limitations

- **Authenticated agent runs were not verified** during packaging (no API credentials were used). Basic HTTPS networking through the runtime was verified working.
- `cline doctor` reports `hub healthy no` until a hub is configured — this is normal.
- First launch of some commands can take a few seconds (large 151 MB binary loading).

## Performance notes

Every `cline` invocation re-parses the ~151 MB self-contained binary, so on
mid-range phones (e.g. MT6765-class) even quick commands like `cline --version`
take roughly **6–15 seconds**, mostly CPU-bound. This is inherent to how the
official Cline binary is built, not something the compatibility layer adds
(our wrapper overhead is ~0.1 s). Tips:

- The launcher sets `CLINE_NO_AUTO_UPDATE=1`, which skips Cline's startup
  update check — one less network round-trip per launch.
- Keep the phone cool and avoid battery-saver modes; startup is CPU-bound.
- Prefer keeping long sessions in one `cline` run instead of restarting.
- Don't kill backgrounded Termux sessions (Android may freeze/reload them,
  forcing a full restart of the CLI).


## License information

See `LICENSES/`:

- **Cline CLI** — Apache 2.0 (bundled binary; official npm `@cline/cli-linux-arm64`)
- **Bun runtime** — MIT (embedded in the Cline binary), with JavaScriptCore LGPL-2 components per Bun's own license statement
- **bun-termux wrapper/shim** — MIT (Happ1ness-dev)
- **glibc** — installed on-device via Termux's `glibc-runner` package (LGPL, from the Termux glibc repository); not redistributed by this package

## How it works (for the curious)

```
cline (launcher script, $PREFIX/bin/cline)
  └─ bun-termux wrapper        (native Termux binary)
       └─ userland exec → glibc ld.so + bun-shim.so (LD_PRELOAD)
            └─ official Cline ELF (Bun-compiled, glibc)
                 └─ Android/Termux
```

You never need to touch any of this; the `cline` command handles it.
