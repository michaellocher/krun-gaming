# Changelog

## 0.1.0 (2026-11-09)

Windows games from Steam on an M1 Mac in a libkrun microVM: Fedora 44 guest, gamescope, Valve's ARM64 Steam client,
Valve's Proton 11.0 (ARM64) with DXVK/vkd3d-proton on Venus → KosmicKrisp → Metal. Details and evidence:
[lab notes](notes/LAB-NOTES.md).

### Works (measured 2026-11-08/09, M1 Pro 16 GB)

- `bash setup.sh` builds everything from an empty cache in 21 minutes (fresh clone of the public repo, 2026-11-09);
  `sh run-session.sh` opens Steam Big Picture under gamescope in a Mac window at 2560x1440 (1 guest pixel per Retina
  pixel). Until Steam's first frame the window shows a loader with the guest's boot stage ("Steam is updating
  itself…" after a fresh install).
- Games run through **Proton 11.0 (ARM64)**, which Valve's ARM64 client now picks for Windows games (native ARM64
  Wine, x86 game code through FEX as Wine's ARM64EC/WoW64 emulator (`libarm64ecfex`, `libwow64fex`); the guest's own aarch64 Venus driver). The older path (x86 Proton under
  Valve's FEX-Emu compat tool) can no longer be installed: Steam answers "Invalid platform" for its runtime.
- **D3D11**: Banished at 60 fps (display rate), 2560x1440 (Proton 11.0 ARM64: 600 frames in 10 s at the main
  menu); Play → game window in ≤ 16 s.
- **D3D12**: vkd3d-proton v3.1 test suite 544/588 without a failed check, host stable; stream output (transform
  feedback) captured (all stream-output tests pass); InfraSpace (Unity, `-force-d3d12`) renders its menus.
- **Shared textures between processes** (Wine's D3DKMT shared resources, e.g. Media Foundation video): InfraSpace's
  intro video after "Start Game" plays (moving frames and subtitles; was black), on Proton 11.0 (ARM64) and on the
  older x86 path. Exportable device-local memory is shared as KosmicKrisp's MTLHeap inside the host process
  (`host-patches/virglrenderer/0004`), and our own guest Venus driver allows optimal-tiled opaque-fd images
  (`guest-patches/mesa/0001`). `host-tests/share-image.c`: export → import → copy gives the cleared colour, in one
  process and across two.
- `setup.sh` builds that Venus driver from the host's Mesa commit for aarch64, x86_64 and i686 (cross-compiled,
  architecture and glibc checked), installs it with the share-image self-test (Fedora's driver back on failure), and
  every session start puts it back if a package update replaced it.
- Steam UI idle: host ~83 % CPU, ~3 GB RSS. Navigating: ~50 fps with Chromium's GPU compositing (was ~20 fps in
  software); an LD_PRELOAD shim gives ANGLE's Vulkan configs the ARGB visual of Chromium's windows
  (`guest/angle-argb-visual.c`).
- Keyboard and absolute mouse (virtio-input); one cursor (gamescope's).
- Sound: virtio-snd → CoreAudio, PipeWire in the guest; plays on the Mac's default output device.
- Microphone: the Mac's default input reaches the guest (CoreAudio input queue → virtio-snd capture → PipeWire);
  `arecord` in the guest recorded speech over the room noise floor.
- Downloads: Steam downloads at the line's full rate (49–53 Mbit/s on a 50 Mbit/s line).

### Own patches

Listed in [NOTICE](NOTICE.md): kernel (virtio-gpu modifiers and blobs, config: HZ=1000 + preemption), libkrun
(virtio-snd CoreAudio backend: playback and capture), virglrenderer (linear features, shm import, shared fence
table, MTLHeap sharing), guest Venus driver (optimal-tiled opaque-fd images), KosmicKrisp (memory type, fill mode,
D3D12 stage 1 and transform feedback), gamescope (wl_shm refresh, absolute pointer), Proton fixes at session start
(Wine service and explorer timeouts).

### Known limits

- D3D12: some edge-case suite tests still fail (texture reinterpretation, border colours, tessellation edge
  cases, 16 KB suballocation alignment).
- Steam UI: Valve's own GL composer in the webhelper still runs on llvmpipe (guest ~330 % while navigating) and
  its frames reach Xwayland by CPU copy.
- A game's static window (e.g. Banished's launcher) can stay behind Steam's loading spinner until it redraws: click
  into the window or press a key. Games that render continuously are not affected.
- Anti-cheat that refuses virtual machines blocks those games.
