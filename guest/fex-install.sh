#!/bin/sh
# Runs inside the guest (launcher --slirp): installs FEX with Fedora's x86 rootfs and thunks, then checks that x86
# code runs and whether FEX uses the hardware TSO mode (Apple memory model via PR_SET_MEM_MODEL, Asahi patches).
# Output to /out/fex-install.txt.
mkdir -p /out && mount -t virtiofs out /out
/spike/net-up.sh > /dev/null 2>&1
{
  dnf install -y -q fex-emu fex-emu-rootfs-fedora fex-emu-thunks 2>&1 | tail -2
  rpm -q fex-emu fex-emu-rootfs-fedora fex-emu-thunks
  dnf clean all -q
  echo "--- rootfs"
  ls -la /usr/share/fex-emu/RootFS/ 2>&1 | head
  echo "--- x86 test"
  FEXBash -c 'uname -m; ls /usr/lib/ld-linux.so.2 /usr/lib64/ld-linux-x86-64.so.2' 2>&1 | tail -4
  echo "--- TSO"
  FEX_LOGLEVEL=debug FEXBash -c 'true' 2>&1 | grep -i -E 'tso|memory model|mem_model' | head -5
  df -h / | tail -1
  fstrim / 2>&1
} > /out/fex-install.txt 2>&1
