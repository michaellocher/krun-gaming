#!/bin/sh
# Runs inside the guest on first setup. Stock Fedora 44 Mesa (26.2.x) is enough: its Venus honors the virtio-gpu blob
# alignment (16K host pages) and enables VK_KHR_swapchain without host sync-fd support. Lean dnf defaults (no docs, no
# weak deps), then trim, so the sparse image on the host only holds what is used.
set -eu
printf 'tsflags=nodocs\ninstall_weak_deps=False\n' >> /etc/dnf/dnf.conf
dnf install -y mesa-vulkan-drivers vulkan-loader gamescope util-linux iproute cpio
# Steam client: its update window draws with GLX (Mesa software GL through Xwayland, no DRI3 here), needs fonts and
# an en_US.UTF-8 locale; unzip for the client packages
dnf install -y mesa-libGL mesa-libEGL libglvnd-glx fontconfig dejavu-sans-fonts glibc-langpack-en unzip
rpm -q mesa-vulkan-drivers gamescope
dnf clean all
fstrim -v /
