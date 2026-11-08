# AGENTS.md

Guidance for coding agents working in this repository.

## What this is

Windows games from Steam on an Apple Silicon Mac in a libkrun microVM. Steam, gamescope, FEX and Proton run in a
Fedora 44 guest. Vulkan reaches the Mac through Venus → virglrenderer → KosmicKrisp (Metal). Overview:
[README.md](README.md); research log with every measurement: [notes/LAB-NOTES.md](notes/LAB-NOTES.md).

## Layout

- **Host (macOS):**
  - `build-host.sh`: KosmicKrisp, virglrenderer, libkrun, launcher.
  - The launcher: `vm-gpu.m`, `input-mac.m`, `net-slirp.c`.
  - `setup.sh`, `run-session.sh`, `guest-cmd.sh`.
- **Guest (Linux):** `guest/*.sh`, `guest/*.py`, `guest/*.c`. Shared into the VM as `/spike` via virtiofs. The cache's `out/` directory appears as `/out`.
- **Disks:** `prepare-guest.ts` builds the guest and builder disks without Docker.
- **Kernel:** `kernel/` (build script, config fragments, patches).
- **Patches:** `host-patches/<project>/`, `guest-patches/<project>/`, `kernel/patches/`.
- **Tests and repros:** `host-tests/`, compiled in the builder VM (`guest/req-build.sh`, `guest/xtest-build.sh`).
- **Build output and cache:** `~/.local/share/krun-gaming` (`KRUN_GAMING_CACHE`).

## Build and run

```bash
bash setup.sh                       # everything; each step skipped when its output exists
sh run-session.sh                   # Steam session in a Mac window (DEBUG=1: lit-frame snapshots)
sh guest-cmd.sh 'cmd'               # run a shell snippet in the running guest as the Steam user
sh guest-cmd.sh --root 'cmd'        # ... as root
```

With `DEBUG=1`, the last lit frame is written to `~/.local/share/krun-gaming/out/lit.ppm` once a second. Convert it with
`sips -s format png lit.ppm --out lit.png`.

## Diagnostics

- `guest/thread-cpu.sh [seconds]`: top CPU threads in the guest from `/proc`, because the guest has no `top`. Run it with `guest-cmd.sh`.
- `guest/x-tree.py`: the X window tree (ids, visuals, geometry) of the running session.
- `host-tests/`: the repros behind the results in the lab notes. Build them in the builder VM with `guest/req-build.sh` and `guest/xtest-build.sh`.

## Hard rules

- **Never edit `guest/*.sh` while a session VM runs.** Bash reads scripts lazily from the virtiofs share, so an edit
  crashes the running session. Stop the session first.
- **Verify by pixels**, not by proxies: look at the `lit.ppm` snapshot, not just logs or exit codes.
- **Evidence:** every claim in README/CHANGELOG needs a measured result with a date. Put the details in
  `notes/LAB-NOTES.md`.
- **Patches** live in `host-patches/`, `guest-patches/` and `kernel/patches/`, and the build scripts apply them.
  Every own patch gets a line in `NOTICE.md`.
- **No GitHub Actions** or other CI. Run checks locally.
- **Only a `main` branch.**

## Git

Conventional Commits with short English messages (`fix: …`, `docs: …`, `chore: …`). No `Co-Authored-By` or other
attribution trailers.
