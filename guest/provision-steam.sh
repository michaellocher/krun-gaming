#!/bin/bash
# Runs inside the guest (--slirp): system libraries Valve's native ARM64 Steam client loads from the host (found with
# steam-deps.sh: ldd over steamrtarm64), from Fedora 44. libavcodec.so.61/libavutil.so.59 (FFmpeg 7) are not in
# Fedora 44; the client bundles its own video libraries. Output to /out/provision-steam.txt.
mkdir -p /out && mount -t virtiofs out /out
exec > /out/provision-steam.txt 2>&1
/spike/net-up.sh > /dev/null 2>&1
# lsof: Steam checks with it which process owns the webhelper's loopback connection, and rejects it without lsof
# dbus-daemon: a session bus for the client and Chromium (they log errors and lose features without one)
PKGS="gtk2 nss nss-util nspr openal-soft ibus-libs NetworkManager-libnm libssh2 libva libvdpau bzip2-libs lsof dbus-daemon"
dnf install -y -q $PKGS 2>&1 | tail -2
rpm -q $PKGS
ln -sf libbz2.so.1 /usr/lib64/libbz2.so.1.0 # Debian's SONAME for the same library
dnf clean all -q
fstrim / 2> /dev/null
R=/home/gamer/.local/share/Steam/steamrtarm64
echo "still missing:"
LD_LIBRARY_PATH=$R:$R/libs find "$R" -maxdepth 2 -type f \( -name '*.so*' -o -perm -u+x \) -print0 |
  LD_LIBRARY_PATH=$R:$R/libs xargs -0 -n 50 ldd 2> /dev/null | awk '/not found/ { print $1 }' | sort -u
df -h / | tail -1
