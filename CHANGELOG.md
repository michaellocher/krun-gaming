# Changelog

## 0.1.0 (draft, not tagged)

Windows games from Steam on an M1 Mac in a libkrun microVM: Fedora 44 guest, gamescope, Valve's ARM64 Steam client,
Proton under FEX, DXVK/vkd3d-proton on Venus → KosmicKrisp → Metal. Details and evidence: [lab notes](notes/LAB-NOTES.md).

### Works (measured 2026-11-08, M1 Pro 16 GB)

- `bash setup.sh` builds everything from scratch; `sh run-session.sh` opens Steam Big Picture under gamescope in a
  Mac window at 2560x1440 (1 guest pixel per Retina pixel).
- Steam UI idle: host ~83 % CPU, ~3 GB RSS. Navigating: ~50 fps with Chromium's GPU compositing (was ~20 fps in
  software); an LD_PRELOAD shim gives ANGLE's Vulkan configs the ARGB visual of Chromium's windows
  (`guest/angle-argb-visual.c`).
- **D3D11**: Banished at 60 fps (display rate), 2560x1440, menu and gameplay; host ~62 % CPU, 3.2 GB.
- **D3D12**: vkd3d-proton v3.1 test suite 544/588 without a failed check, host stable; stream output (transform feedback) captured
  (all stream-output tests pass); InfraSpace (Unity, `-force-d3d12`) renders its menus.
- **Shared textures between processes** (Wine's D3DKMT shared resources, e.g. Media Foundation video): InfraSpace's
  intro video after "Start Game" plays (moving frames and subtitles, D3D11 default mode; was black). Exportable
  device-local memory is shared as KosmicKrisp's MTLHeap inside the host process (`host-patches/virglrenderer/0004`),
  and our own guest Venus driver allows optimal-tiled opaque-fd images (`guest-patches/mesa/0001`).
  `host-tests/share-image.c`: export → import → copy gives the cleared colour, in one process and across two.
- `setup.sh` builds that Venus driver from the host's Mesa commit for aarch64, x86_64 and i686 (cross-compiled,
  architecture and glibc checked), installs it with the share-image self-test (Fedora's driver back on failure), and
  every session start puts it back if a package update replaced it.
- Keyboard and absolute mouse (virtio-input); one cursor (gamescope's).
- Sound: virtio-snd → CoreAudio, PipeWire in the guest; plays on the Mac's default output device.

### Own patches

Listed in [NOTICE](NOTICE.md): kernel (virtio-gpu modifiers and blobs, config: HZ=1000 + preemption), libkrun
(virtio-snd CoreAudio backend), virglrenderer (linear features, shm import, shared fence table, MTLHeap sharing),
guest Venus driver (optimal-tiled opaque-fd images), KosmicKrisp (memory
type, fill mode, D3D12 stage 1 and transform feedback), gamescope (wl_shm refresh, absolute pointer), Proton fixes at session start (Wine
service and explorer timeouts under FEX).

### Known limits

- D3D12: some edge-case suite tests still fail (texture reinterpretation, border colours, tessellation edge
  cases, 16 KB suballocation alignment).
- Steam UI: Valve's own GL composer in the webhelper still runs on llvmpipe (guest ~330 % while navigating) and
  its frames reach Xwayland by CPU copy (moving it to the GPU through the new texture sharing is not done yet).
- x86 processes start slowly under FEX (Vulkan setup ~3.4 s each); a game's first launch takes 1-2 minutes.
- Steam downloads through the VM's user-mode network (libslirp) reached 8-14 Mbit/s.
- Capture (microphone) is not implemented.
