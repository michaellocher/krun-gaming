#!/bin/sh
# Runs inside the builder VM: builds the guest kernel on the builder's ext4 disk (case-sensitive) and writes the raw
# arm64 Image to /out. Mounts: /kernel = spike kernel/ (patches, config), /cache = tarball dir, /out = output dir.
set -eu
: "${KVER:?}"
src=/build/linux-$KVER obj=/build/obj-$KVER
make_args="-C $src O=$obj ARCH=arm64 KBUILD_BUILD_USER=krun-gaming KBUILD_BUILD_HOST=krun-gaming"

stamp=$(cat /cache/linux-$KVER.tar.xz /kernel/patches/*.patch | sha256sum | cut -d' ' -f1)
if [ "$(cat "$src/.stamp" 2>/dev/null || true)" != "$stamp" ]; then
  rm -rf "$src" "$obj"; mkdir -p /build
  tar -C /build -xf /cache/linux-$KVER.tar.xz
  for p in /kernel/patches/*.patch; do echo ">> $(basename "$p")"; patch -d "$src" -p1 -F0 --no-backup-if-mismatch < "$p"; done
  echo "$stamp" > "$src/.stamp"
fi
mkdir -p "$obj"
cp /kernel/config/00-libkrunfw-aarch64.config "$obj/.config"
"$src/scripts/kconfig/merge_config.sh" -m -O "$obj" "$obj/.config" /kernel/config/10-krun-gaming.config > "$obj/merge.log"
make $make_args olddefconfig > /dev/null
i=0 # everything built in: libkrun loads a bare Image without modules
while grep -qE '^CONFIG_[A-Za-z0-9_]+=m$' "$obj/.config" && [ $i -lt 10 ]; do
  sed -i -E 's/^(CONFIG_[A-Za-z0-9_]+)=m$/\1=y/' "$obj/.config"; make $make_args olddefconfig > /dev/null; i=$((i + 1))
done
missing=$(grep -E '^CONFIG_' /kernel/config/10-krun-gaming.config | grep -v -x -F -f "$obj/.config" || true)
[ -z "$missing" ] || { echo "config lost required options:"; echo "$missing"; exit 1; }
make $make_args -j"$(nproc)" Image
cp "$obj/arch/arm64/boot/Image" /out/Image.tmp && mv -f /out/Image.tmp /out/Image
cp "$obj/.config" /out/kernel.config
echo ">> $(cat "$obj/include/config/kernel.release")"
