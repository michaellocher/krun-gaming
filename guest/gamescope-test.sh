#!/bin/sh
# Runs inside the guest: gamescope on the virtio-gpu display (DRM backend, Vulkan composition on Venus) with an app
# inside via Xwayland, for ~15 s (GAMESCOPE_SECONDS). Default app: native vkcube; "x86" runs the x86 vkcube from FEX's
# rootfs (Vulkan thunk). Log to /out/gamescope.txt.
mkdir -p /out && mount -t virtiofs out /out
export XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=noop WLR_LIBINPUT_NO_DEVICES=1 # no virtio-input yet
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
rm -rf /tmp/.X11-unix /tmp/.X*-lock # left behind by earlier sessions (another user): Xwayland refuses to start
APP="vkcube --wsi xcb"
if [ "${1:-}" = x86 ]; then
  . /spike/fex-setup.sh
  APP="$FEX_ROOTFS/usr/bin/vkcube --wsi xcb" # x86 Venus driver from the rootfs overlay (fex-setup.sh)
fi
timeout "${GAMESCOPE_SECONDS:-15}" gamescope --backend drm -W 1280 -H 720 -- $APP > /out/gamescope.txt 2>&1
echo "rc=$?" >> /out/gamescope.txt
