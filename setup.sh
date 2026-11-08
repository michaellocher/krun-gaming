#!/bin/bash
# Builds everything from scratch into $KRUN_GAMING_CACHE (default ~/.local/share/krun-gaming), each step skipped when
# its output exists: host stack (KosmicKrisp, UTM virglrenderer, libkrun, launcher), guest disk (Fedora 44 +
# gamescope), guest kernel (7.3.3 + Asahi TSO + own virtio-gpu patch), FEX with the x86 rootfs overlay, patched
# gamescope, our Venus driver (guest-patches/mesa), Valve's ARM64 Steam client. Then: sh run-session.sh
# Usage: bash setup.sh   (needs Xcode, Homebrew, rustup, Node 26)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
export KRUN_GAMING_CACHE=${KRUN_GAMING_CACHE:-$HOME/.local/share/krun-gaming}
C=$KRUN_GAMING_CACHE VM=$C/prefix-kosmickrisp/vm-gpu
log() { printf '\n=== %s (%s)\n' "$1" "$(date +%H:%M:%S)"; }

guest() { # guest SCRIPT [launcher options]: run a guest/ script on the own kernel with libslirp network
  local script=$1; shift
  "$VM" --slirp --kernel "$C/kernel/Image" --ram 4096 --vcpus 4 --disk "root:$C/guest.img" --root-disk /dev/vda \
    --share "spike:$DIR/guest" --share "out:$C/out" "$@" - \
    /bin/sh -c "mkdir -p /spike && mount -t virtiofs spike /spike && /spike/$script"
}

builder() { # builder PATCHES OUT SCRIPT [launcher options]: run a guest/ script in the builder VM (Fedora, network)
  local patches=$1 out=$2 script=$3 ns; shift 3
  [ -f "$C/builder.img" ] || node "$DIR/prepare-guest.ts" --name builder --provision provision-builder.sh --size 24G
  ns=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)
  "$VM" --net --ram 8192 --vcpus 8 --disk "root:$C/builder.img" --root-disk /dev/vda --share "spike:$DIR/guest" \
    --share "patches:$patches" --share "tests:$DIR/host-tests" --share "out:$out" --env "NAMESERVER=${ns:-1.1.1.1}" \
    "$@" - /bin/sh -c "for t in spike patches tests out; do mkdir -p /\$t; mount -t virtiofs \$t /\$t; done; /spike/$script"
}

mkdir -p "$C/out"
[ -x "$VM" ] || { log "host stack"; VULKAN_DRIVER=kosmickrisp bash "$DIR/build-host.sh"; }
[ -f "$C/guest.img" ] || { log "guest disk"; node "$DIR/prepare-guest.ts"; }
[ -f "$C/kernel/Image" ] || { log "guest kernel"; sh "$DIR/kernel/build.sh"; }
if [ ! -f "$C/.fex-installed" ]; then
  log "FEX + x86 overlay"
  guest fex-install.sh && cat "$C/out/fex-install.txt"
  guest x86-overlay-install.sh && cat "$C/out/x86-overlay-install.txt"
  rm -f "$C/.venus-installed" # the overlay came with Fedora's x86 Venus driver again
  touch "$C/.fex-installed"
fi
if [ ! -f "$C/.gamescope-installed" ]; then
  log "gamescope with guest-patches/gamescope (built in the builder VM)"
  rm -rf "$C/gamescope-rpm" && mkdir -p "$C/gamescope-rpm"
  builder "$DIR/guest-patches/gamescope" "$C/gamescope-rpm" gamescope-build.sh
  tail -1 "$C/gamescope-rpm/gamescope-build.txt"
  rpm=$(ls "$C"/gamescope-rpm/gamescope-[0-9]*.krun.*.rpm)
  # the guest sees the RPM through the out share; NetworkManager: Steam's network status (steam-run.sh); PipeWire:
  # sound (steam-loop.sh)
  cp "$rpm" "$C/out/" && guest pkg-add.sh \
    --env "PKGS=/out/$(basename "$rpm") NetworkManager python3 pipewire pipewire-pulseaudio wireplumber pipewire-alsa" \
    --env DNF_ACTION=install && cat "$C/out/pkg-add.txt"
  grep -q 'gamescope-.*krun' "$C/out/pkg-add.txt" && touch "$C/.gamescope-installed"
fi
# our guest Venus driver: rebuilt and reinstalled whenever the Mesa commit (the host's), the guest patches or the
# build or its self-test change
MESA_COMMIT=${MESA_COMMIT:-$(sed -n 's/^MESA_COMMIT=${MESA_COMMIT:-\([0-9a-f]*\)}.*/\1/p' "$DIR/build-host.sh")}
VENUS=$MESA_COMMIT-$(cat "$DIR"/guest-patches/mesa/*.patch "$DIR/guest/venus-build.sh" "$DIR/host-tests/share-image.c" |
  shasum -a 256 | cut -c1-12)
if [ "$(cat "$C/out/venus/stamp" 2> /dev/null)" != "$VENUS" ]; then
  log "Venus driver from Mesa $MESA_COMMIT + guest-patches/mesa (built in the builder VM)"
  rm -rf "$C/venus-new" && mkdir -p "$C/venus-new"
  builder "$DIR/guest-patches/mesa" "$C/venus-new" venus-build.sh --env "MESA_COMMIT=$MESA_COMMIT" \
    --env "STAMP=$VENUS" || true
  tail -4 "$C/venus-new/venus-build.txt"
  [ "$(cat "$C/venus-new/stamp" 2> /dev/null)" = "$VENUS" ] || { echo "venus build failed"; exit 1; }
  rm -rf "$C/out/venus" && mv "$C/venus-new" "$C/out/venus"
fi
if [ "$(cat "$C/.venus-installed" 2> /dev/null)" != "$VENUS" ]; then
  log "Venus driver into the guest"
  guest venus-install.sh || true
  cat "$C/out/venus-install.txt"
  grep -q "^venus-install: ok ($VENUS)" "$C/out/venus-install.txt" || { echo "venus install failed"; exit 1; }
  echo "$VENUS" > "$C/.venus-installed"
fi
if [ ! -f "$C/.steam-installed" ]; then
  log "Steam ARM64 client + its system libraries"
  guest steam-arm64-install.sh && tail -3 "$C/out/steam-arm64-install.txt"
  guest provision-steam.sh && tail -4 "$C/out/provision-steam.txt"
  touch "$C/.steam-installed"
fi
log "done: $VM, $(du -h "$C/guest.img" | cut -f1) guest disk"
