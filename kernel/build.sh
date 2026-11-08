#!/bin/sh
# Builds the guest kernel without Docker: inside a builder microVM (own disk, compilers), on ext4.
# Linux 7.3.3 (kernel.org; virtio-gpu blob alignment is upstream since 7.2) + patches/ = Apple TSO memory model for
# FEX, straight from Asahi Linux (AsahiLinux/linux bits/220-tso, on 7.3) + config = libkrunfw's aarch64 config
# (containers/libkrunfw main) + config/10-krun-gaming.config. Output: <cache>/kernel/Image
# Usage: sh kernel/build.sh   (first run creates <cache>/builder.img via prepare-guest.ts)
set -eu
KVER=7.3.3
KSHA256=79c66dde66cd96877fcde8f7d36aec946b1f423d2b97b5a7b1751b75c764f3d1
KURL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KVER.tar.xz
CACHE=${KRUN_GAMING_CACHE:-$HOME/.local/share/krun-gaming} # not ~/Library/Caches: macOS may purge it
here=$(cd "$(dirname "$0")" && pwd) spike=$(cd "$(dirname "$0")/.." && pwd)
VM=$CACHE/${KRUN_GAMING_PREFIX:-prefix-kosmickrisp}/vm-gpu
mkdir -p "$CACHE/kernel-src" "$CACHE/kernel"

tarball=$CACHE/kernel-src/linux-$KVER.tar.xz
if ! echo "$KSHA256  $tarball" | shasum -a 256 -c - > /dev/null 2>&1; then
  curl -fL --retry 3 -o "$tarball.part" "$KURL"
  echo "$KSHA256  $tarball.part" | shasum -a 256 -c -
  mv "$tarball.part" "$tarball"
fi
[ -f "$CACHE/builder.img" ] || node "$spike/prepare-guest.ts" --name builder --provision provision-builder.sh --size 24G

"$VM" --ram 6144 --vcpus 8 --disk "root:$CACHE/builder.img" --root-disk /dev/vda \
  --share "kernel:$here" --share "cache:$CACHE/kernel-src" --share "out:$CACHE/kernel" --share "spike:$spike/guest" \
  --env KVER=$KVER - /bin/sh -c 'for t in kernel cache out spike; do mkdir -p /$t; mount -t virtiofs $t /$t; done; /spike/kernel-build.sh'
[ -f "$CACHE/kernel/Image" ] || { echo "no kernel Image built (the launcher does not pass the guest's exit code)" >&2; exit 1; }
file "$CACHE/kernel/Image"
