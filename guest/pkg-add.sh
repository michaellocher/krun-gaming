#!/bin/sh
# Runs inside the guest (--slirp): installs (DNF_ACTION, default install) the packages in PKGS, then trims.
mkdir -p /out && mount -t virtiofs out /out
/spike/net-up.sh > /dev/null 2>&1
{ dnf "${DNF_ACTION:-install}" -y -q $PKGS 2>&1 | tail -2; rpm -q $PKGS; dnf clean all -q; fstrim / ; } > /out/pkg-add.txt 2>&1
