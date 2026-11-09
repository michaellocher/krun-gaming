#!/bin/sh
# Host: (re)start the Steam session VM in the background (window + live logs). Stops a running session first.
# Usage: [DISPLAY_SIZE=WxH] [VM_RAM=MiB] [DEBUG=1] sh run-session.sh [gamescope|gamescope-nested|xorg] [extra --env args...]
# Logs: ${KG_LOG:-/tmp/kg-steam.log} (launcher, frame stats), <cache>/out/steam-*.txt; command channel: guest-cmd.sh.
D=$(cd "$(dirname "$0")" && pwd)
C=${KRUN_GAMING_CACHE:-$HOME/.local/share/krun-gaming}
P=$C/prefix-kosmickrisp
# guest resolution; the Mac window shows it at 1 guest pixel per Retina pixel (2560x1440 = 1280x720 points)
SIZE=${DISPLAY_SIZE:-2560x1440}
SESSION=${1:-gamescope}
[ $# -gt 0 ] && shift
pkill -f "$P/vm-gpu --slirp" && sleep 2 # only this cache's session: other caches may run their own VMs
mkdir -p "$C/out/cmd"
find "$C/out/cmd" -type f -delete
# the window's loader shows the guest's startup stage (steam-run.sh writes it) until the first frame
printf 'Starting the VM…\n' > "$C/out/status.txt"
export VM_STATUS_FILE=$C/out/status.txt
# DEBUG=1: per-frame fingerprints in the log and the last lit frame as <cache>/out/lit.ppm (once a second; costs CPU)
[ "${DEBUG:-0}" = 1 ] && export VM_FRAME_STATS=1 VM_SNAPSHOT_LIT=$C/out/lit.ppm
MESA_KK_EXPERIMENTAL=custom_border nohup "$P/vm-gpu" --slirp \
  --display "$SIZE" --kernel "$C/kernel/Image" --ram "${VM_RAM:-6144}" --vcpus 6 --disk "root:$C/guest.img" --root-disk /dev/vda \
  --share "spike:$D/guest" --share "out:$C/out" --env STEAM_SECONDS=7200 --env "SESSION=$SESSION" \
  --env "DISPLAY_W=${SIZE%x*}" --env "DISPLAY_H=${SIZE#*x}" "$@" - \
  /bin/sh -c 'mkdir -p /spike && mount -t virtiofs spike /spike && /spike/steam-run.sh' > "${KG_LOG:-/tmp/kg-steam.log}" 2>&1 &
echo "session $SESSION started (pid $!)"
