#!/bin/bash
# Runs inside the guest (launcher --display; share out holds req-build.sh's binaries): DXVK and vkd3d-proton
# requirement checks against Venus, i.e. what Windows games see. Output: /out/req-guest.txt (external-image:
# /out/external-image.txt).
mkdir -p /out && mount -t virtiofs out /out
{ for t in dxvk vkd3d; do echo "== $t"; /out/$t-req; done; } > /out/req-guest.txt 2>&1
/out/external-image > /out/external-image.txt 2>&1
