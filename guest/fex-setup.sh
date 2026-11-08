#!/bin/sh
# Source inside the guest (no systemd): mounts Fedora's x86 rootfs for FEX — the read-only erofs image with an overlay
# that holds the current x86 Venus driver (x86-mesa-install.sh) — and registers FEX for x86 binaries via
# binfmt_misc with the entries the fex-emu package ships in /usr/lib/binfmt.d.
ROOTFS=/run/fex-rootfs LOWER=/run/fex-rootfs-lower OVERLAY=/var/lib/krun-gaming/fex-overlay
if ! mountpoint -q "$ROOTFS"; then
  mkdir -p "$ROOTFS" "$LOWER" "$OVERLAY/upper" "$OVERLAY/work"
  mount -t erofs -o loop,ro /usr/share/fex-emu/RootFS/default.erofs "$LOWER"
  mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$OVERLAY/upper,workdir=$OVERLAY/work" "$ROOTFS"
fi
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
for f in /usr/lib/binfmt.d/FEX-*.conf; do
  name=$(cut -d: -f2 "$f")
  [ -e "/proc/sys/fs/binfmt_misc/$name" ] || cat "$f" > /proc/sys/fs/binfmt_misc/register
done
export FEX_ROOTFS="$ROOTFS"
# no thunks: FEX's Vulkan thunk cannot follow function pointers from implicit layers (gamescope WSI, device select);
# x86 apps use the x86 Venus driver from the rootfs overlay instead, as on Asahi/Fedora
mkdir -p "${HOME:-/root}/.fex-emu"
cat > "${HOME:-/root}/.fex-emu/Config.json" << EOF
{ "Config": { "RootFS": "$ROOTFS" } }
EOF
