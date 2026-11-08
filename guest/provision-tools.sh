#!/bin/sh
# Optional, runs inside the guest (with --net): test tools for the GPU path (vkcube, vulkaninfo, vkmark). Debugging
# adds gdb-minimal temporarily; remove it again with `dnf remove gdb-minimal` and trim with `fstrim /`.
set -eu
dnf install -y vulkan-tools vkmark
dnf clean all
fstrim -v /
