#!/bin/sh
# Runs inside the guest (--slirp): fills the overlay upper dir for FEX's read-only x86 rootfs (fex-setup.sh mounts it)
# with single files from Fedora's current x86_64 and i686 packages:
# - mesa-vulkan-drivers: the Venus ICD (the rootfs' Mesa predates the 16K blob alignment)
# - gamescope: its WSI layer (Venus presents through it; Xwayland has no DRI3 without glamor)
# and hides every other x86 Vulkan driver of the rootfs (see below).
# Output to /out/x86-overlay-install.txt.
set -eu
mkdir -p /out && mount -t virtiofs out /out
exec > /out/x86-overlay-install.txt 2>&1
/spike/net-up.sh > /dev/null 2>&1
UPPER=/var/lib/krun-gaming/fex-overlay/upper
rm -rf /tmp/x86pkgs "$UPPER"; mkdir -p /tmp/x86pkgs "$UPPER"; cd /tmp/x86pkgs
rpm -q cpio > /dev/null 2>&1 || dnf install -y -q cpio

take() { # take PACKAGE FILE-PATTERN...: extract matching files of the x86_64 and i686 builds into the overlay
  pkg=$1; shift
  dnf download -q --forcearch=x86_64 "$pkg"
  dnf download -q --forcearch=i686 "$pkg" 2> /dev/null || echo "($pkg: no i686 build)"
  for r in "$pkg"-[0-9]*.x86_64.rpm "$pkg"-[0-9]*.i686.rpm; do
    [ -f "$r" ] || continue
    (cd "$UPPER" && rpm2cpio "/tmp/x86pkgs/$r" | cpio -idm --quiet "$@")
    rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$r"
  done
}
take mesa-vulkan-drivers './usr/lib64/libvulkan_virtio.so' './usr/lib/libvulkan_virtio.so' \
  './usr/share/vulkan/icd.d/virtio_icd.*.json'
take gamescope './usr/lib64/libVkLayer_FROG_gamescope_wsi_*.so' './usr/lib/libVkLayer_FROG_gamescope_wsi_*.so' \
  './usr/share/vulkan/implicit_layer.d/VkLayer_FROG_gamescope_wsi.*.json'

# hide the rootfs' other Vulkan drivers (overlayfs whiteouts): the loader opens every ICD it finds, and under FEX that
# made each x86 Vulkan process start 8.2 s instead of 3.4 s (lavapipe's LLVM alone), measured 2026-11-08 — long
# enough that Wine's explorer.exe missed its start window and games quit with "The explorer process failed to start"
LOWER=/tmp/x86-lower
mkdir -p "$LOWER" && mount -t erofs -o loop,ro /usr/share/fex-emu/RootFS/default.erofs "$LOWER"
for j in "$LOWER"/usr/share/vulkan/icd.d/*.json; do
  case "${j##*/}" in virtio_icd.*) ;; *) mknod "$UPPER/usr/share/vulkan/icd.d/${j##*/}" c 0 0 ;; esac
done
umount "$LOWER"
echo "hidden ICDs: $(find "$UPPER/usr/share/vulkan/icd.d" -type c | wc -l)"

find "$UPPER" -type f | xargs ls -la
rm -rf /tmp/x86pkgs
dnf clean all -q
