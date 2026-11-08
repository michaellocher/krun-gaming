#!/bin/bash
# Runs inside the builder VM (--net, NAMESERVER; shares: patches = guest-patches/gamescope, out): rebuilds Fedora's
# gamescope source package with our patches added (rpmbuild, Fedora's own spec and flags), RPMs to /out.
# Log: /out/gamescope-build.txt.
set -euo pipefail
exec > /out/gamescope-build.txt 2>&1
printf 'nameserver %s\n' "${NAMESERVER:-1.1.1.1}" > /etc/resolv.conf
dnf install -y --setopt=install_weak_deps=False rpm-build dnf-plugins-core
V=${GAMESCOPE_VERSION:-3.16.29}
W=/root/gamescope-rpm
rm -rf "$W" && mkdir -p "$W" && cd "$W"
dnf download --source "gamescope-$V"
rpm -i --define "_topdir $W" gamescope-"$V"-*.src.rpm
spec=$W/SPECS/gamescope.spec
n=100
for p in /patches/*.patch; do
  cp "$p" "$W/SOURCES/"
  # our patches after Fedora's: numbered from 100, applied by the spec's %autosetup -p1
  sed -i "0,/^Patch[0-9]*:/s//Patch$n: $(basename "$p")\n&/" "$spec"
  n=$((n + 1))
done
grep -n -E "^Patch|autosetup|%patch" "$spec"
sed -i 's/^Release: *\(.*\)$/Release: \1.krun/' "$spec"
dnf builddep -y "$spec"
rpmbuild --define "_topdir $W" -bb --nocheck "$spec"
cp "$W"/RPMS/*/gamescope-[0-9]*.rpm /out/
ls -la /out/*.rpm
echo "gamescope-build: ok"
