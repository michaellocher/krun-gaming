#!/bin/sh
# Installed as /usr/local/bin/Xwayland-zink and started by gamescope via WLR_XWAYLAND. Only Xwayland gets zink (GL on
# Venus): that gives glamor and with it DRI3 for X11 clients. gamescope itself must not see the override — with it,
# its own KMS framebuffers fail (drmModeAddFB2WithModifiers: EINVAL) and it never sets a mode.
export MESA_LOADER_DRIVER_OVERRIDE=zink __GLX_VENDOR_LIBRARY_NAME=mesa
exec /usr/bin/Xwayland "$@"
