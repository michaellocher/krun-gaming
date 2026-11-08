# Third-party code and patches

Pieces come directly from Asahi Linux, UTM and the upstream projects (kernel.org, libkrun/libkrunfw, Mesa); other
third-party work only where nothing upstream exists. Own fixes are kept as local patches. Each patch is under the
license of the project it modifies.

| Here | Source | License |
|---|---|---|
| `kernel/patches/000{1..4}-asahi-*.patch` | [AsahiLinux/linux](https://github.com/AsahiLinux/linux) `bits/220-tso` (04dc351ac671, 3e9371874ed9, d81cd5f767a2, 2f63d6e71840), on Linux 7.3 | GPL-2.0 |
| `kernel/config/00-libkrunfw-aarch64.config` | [containers/libkrunfw](https://github.com/containers/libkrunfw) `config-libkrunfw_aarch64` (main, 5.6.2) | GPL-2.0 |
| KosmicKrisp (built from source, not vendored) | [Mesa](https://gitlab.freedesktop.org/mesa/mesa) main `c0235eff` | MIT |
| virglrenderer, MoltenVK (built from source, not vendored) | UTM forks at UTM's own pins (`utmapp/UTM` `patches/sources`) | MIT / Apache-2.0 |
| `host-patches/libkrun/0007–0009` | [fxgl/steamac](https://github.com/fxgl/steamac) `16d0662` `host/libkrun/patches/` — no upstream equivalent in libkrun yet (checked 2026-11-08: `main` has no shm-fd blob mapping, `SET_SCANOUT_BLOB` only as a constant) | Apache-2.0 |

Own patches (this project):

| Patch | What |
|---|---|
| `host-patches/mesa/0001` | KosmicKrisp: device-local-only memory type for optimal-tiled images (Metal cannot place them in imported host memory) |
| `host-patches/virglrenderer/0001` | Venus: the emulated LINEAR modifier reports the driver's real linear tiling features |
| `host-patches/virglrenderer/0002` | Venus: import shm resources from other contexts as host memory (compositor sampling a client's buffer) |
| `host-patches/virglrenderer/0003` | fence table shared by proxy and in-process render server is refcounted (VMM crash after a guest device loss) |
| `host-patches/virglrenderer/0004` | Venus: exportable device-local memory is shared between guest contexts as the driver's MTLHeap (`VK_EXT_external_memory_metal`) instead of shm, so optimal-tiled images can be shared (Wine's D3DKMT shared textures) |
| `guest-patches/mesa/0001` | Venus (guest driver, built from Mesa `c0235eff` by `guest/venus-build.sh`): allow optimal tiling for opaque-fd images, which 0004 backs on the host |
| `kernel/patches/0005` | virtio-gpu: advertise and accept `DRM_FORMAT_MOD_LINEAR`, list ARGB8888 on the primary plane (unchanged in 7.4-rc1) |
| `kernel/patches/0006` | virtio-gpu: dumb buffers as guest blobs also with 3D enabled (Xorg/modesetting scanout on libkrun) |
| `host-patches/libkrun/0010` | virtio-snd: CoreAudio (AudioQueue) playback backend for macOS hosts; pipewire dependency Linux-only |
| `host-patches/mesa/0002` | KosmicKrisp: `fillModeNonSolid` (wireframe) via Metal's triangle fill mode |
| `host-patches/mesa/0003` | KosmicKrisp: D3D12 stage 1 — transform feedback entry points and query, single-texel buffer alignment, buffer views of unsupported formats |
| `host-patches/mesa/0004` | KosmicKrisp: D3D12 stage 2 — transform feedback capture (port of Honeykrisp's on Mesa's poly GS emulation, passthrough GS for VS-only capture) |
| `guest-patches/gamescope/0001` | gamescope 3.16.29: refresh wl_shm textures on every commit (flicker with Xwayland without glamor) |
| `guest-patches/gamescope/0002` | gamescope 3.16.29: absolute pointer motion (VM tablet-style mouse) |
