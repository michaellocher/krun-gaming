#!/bin/sh
# Runs inside the guest as root (share out holds venus/ from venus-build.sh): replaces Fedora's Venus driver with ours
# — native in /usr/lib64, x86_64 and i686 in FEX's rootfs overlay (x86-overlay-install.sh) — after checking each
# library's architecture build and that the rootfs' glibc is new enough for it. The ICD files stay Fedora's (same
# library paths). The first replaced Fedora file is kept as <file>.fedora.
#   install (default): then runs share-image (in-process and across processes); on failure everything goes back to
#     Fedora's driver and the script fails. Log: /out/venus-install.txt.
#   heal: only puts our driver back where a package update replaced it (steam-run.sh at every session start);
#     silent when nothing changed. Log: /out/venus-heal.txt.
set -eu
MODE=${1:-install}
mkdir -p /out && { mountpoint -q /out || mount -t virtiofs out /out; }
exec > "/out/venus-$MODE.txt" 2>&1
V=/out/venus UPPER=/var/lib/krun-gaming/fex-overlay/upper
[ -f "$V/stamp" ] || { echo "no complete build in $V (venus-build.sh)"; exit 1; }

# the x86 rootfs' own glibc (the overlay adds no libc): mounted by fex-setup.sh in a session, else mount it here
LOWER=/run/fex-rootfs-lower TMP=
if ! mountpoint -q "$LOWER"; then
  TMP=$(mktemp -d) LOWER=$TMP
  mount -t erofs -o loop,ro /usr/share/fex-emu/RootFS/default.erofs "$LOWER"
fi
cleanup() { [ -z "$TMP" ] || { umount "$TMP" && rmdir "$TMP"; }; }
trap cleanup EXIT
glibc_of() { grep -ao 'GLIBC_2\.[0-9]*' "$1" | sort -uV | tail -1; }

# arch, target, libc it runs against, ELF machine (bytes 18-19)
TARGETS="aarch64 /usr/lib64/libvulkan_virtio.so /usr/lib64/libc.so.6 b700
x86_64 $UPPER/usr/lib64/libvulkan_virtio.so $LOWER/usr/lib64/libc.so.6 3e00
i686 $UPPER/usr/lib/libvulkan_virtio.so $LOWER/usr/lib/libc.so.6 0300"

check() { # check ARCH LIBC MACHINE: our build for ARCH fits
  lib=$V/$1/libvulkan_virtio.so
  [ "$(od -An -tx1 -j18 -N2 "$lib" | tr -d ' \n')" = "$3" ] || { echo "$1: $lib is not an $1 ELF"; return 1; }
  need=$(cat "$V/$1/glibc.txt") have=$(glibc_of "$2")
  [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -1)" = "$have" ] ||
    { echo "$1: needs $need, $2 has $have"; return 1; }
}
put() { # put ARCH TARGET: install ours unless already there (atomic rename: running processes keep the old file)
  lib=$V/$1/libvulkan_virtio.so
  cmp -s "$lib" "$2" && return 0
  [ -e "$2.fedora" ] || [ ! -e "$2" ] || cp -p "$2" "$2.fedora"
  mkdir -p "$(dirname "$2")" && cp "$lib" "$2.new" && chmod 755 "$2.new" && mv -f "$2.new" "$2"
  echo "$1: installed $(sha256sum < "$2" | cut -c1-16) to $2"
}
restore() {
  echo "$TARGETS" | while read -r _ target _ _; do
    [ -e "$target.fedora" ] && cp -p "$target.fedora" "$target.new" && mv -f "$target.new" "$target" &&
      echo "restored Fedora's $target"
  done
}

echo "$TARGETS" | while read -r arch target libc machine; do check "$arch" "$libc" "$machine"; done
echo "$TARGETS" | while read -r arch target _ _; do put "$arch" "$target"; done
# the VM can end without a clean shutdown (session time limit, window closed): unsynced writes were lost once
sync
[ "$MODE" = heal ] && exit 0
if "$V/share-image" && "$V/share-image" fork; then
  echo "venus-install: ok ($(cat "$V/stamp"))"
else
  echo "share-image failed: back to Fedora's driver"
  restore
  sync
  exit 1
fi
