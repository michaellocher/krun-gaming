#!/bin/sh
# Installed as /usr/local/bin/taskset in the guest. Steam's steamwebhelper.sh starts the UI process with
# `taskset 0x7c .../steamwebhelper ...`; this inserts extra Chromium switches for it, read at every start from
# /tmp/webhelper-flags (one line, may be absent) — so variants can be tried live: write the file, kill the
# webhelper, Steam restarts it. WEBHELPER_VULKAN=1 adds the ANGLE-on-Vulkan switches. Everything else goes to the
# real taskset unchanged; Valve's files stay untouched.
mask=$1
shift
case "$1" in
  */steamwebhelper)
    prog=$1
    shift
    # The UI presents through Mesa's X11 WSI by CPU copy (no DRI3 in gamescope's Xwayland), not gamescope's WSI layer:
    # with the layer the surface size query fails (VK_ERROR_SURFACE_LOST_KHR) while the window still exists and
    # Chromium's GPU process exits. /tmp/webhelper-wsi = "layer" tries the layer again (live, like the flags).
    if [ "$(cat /tmp/webhelper-wsi 2> /dev/null)" != layer ]; then
      export ENABLE_GAMESCOPE_WSI=0 MESA_VK_WSI_DEBUG=sw
    fi
    # ANGLE's configs carry the visual of Chromium's ARGB windows, else no GPU compositing (see angle-argb-visual.c)
    export LD_PRELOAD=/spike/angle-argb-visual.so${LD_PRELOAD:+:$LD_PRELOAD}
    # /tmp/webhelper-env (optional): extra VAR=value words for experiments
    # shellcheck disable=SC2046 # a word list
    [ -s /tmp/webhelper-env ] && export $(cat /tmp/webhelper-env)
    flags=$(cat /tmp/webhelper-flags 2> /dev/null)
    [ "${WEBHELPER_VULKAN:-0}" = 1 ] && flags="$flags --use-gl=angle --use-angle=vulkan --enable-features=Vulkan"
    echo "$(date +%T) taskset-wrapper: steamwebhelper +[$flags]" >> /tmp/taskset-wrapper.log
    # shellcheck disable=SC2086 # flags are a word list
    exec /usr/bin/taskset "$mask" "$prog" $flags "$@"
    ;;
esac
exec /usr/bin/taskset "$mask" "$@"
