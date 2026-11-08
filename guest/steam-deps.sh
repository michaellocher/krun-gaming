#!/bin/bash
# Runs inside the guest (--slirp): which system libraries Valve's native ARM64 client needs that the guest lacks —
# ldd over every ELF in steamrtarm64 (with its own bundled libs on the path), then the Fedora packages providing them.
# INSTALL=1 installs those packages. Output to /out/steam-deps.txt.
mkdir -p /out && mount -t virtiofs out /out
exec > /out/steam-deps.txt 2>&1
/spike/net-up.sh > /dev/null 2>&1
R=/home/gamer/.local/share/Steam/steamrtarm64
export LD_LIBRARY_PATH=$R:$R/libs
missing=$(find "$R" -maxdepth 2 -type f \( -name '*.so*' -o -perm -u+x \) -print0 |
  xargs -0 -n 50 ldd 2> /dev/null | awk '/not found/ { print $1 }' | sort -u)
echo "missing libraries:"; echo "$missing"
pkgs=$(for l in $missing; do dnf -q repoquery --whatprovides "$l()(64bit)" --qf '%{name}\n' 2> /dev/null | head -1; done | sort -u)
echo "fedora packages:"; echo "$pkgs"
if [ "${INSTALL:-0}" = 1 ] && [ -n "$pkgs" ]; then
  dnf install -y -q $pkgs 2>&1 | tail -2
  dnf clean all -q; fstrim / 2> /dev/null
  echo "still missing:"
  find "$R" -maxdepth 2 -type f \( -name '*.so*' -o -perm -u+x \) -print0 |
    xargs -0 -n 50 ldd 2> /dev/null | awk '/not found/ { print $1 }' | sort -u
fi
