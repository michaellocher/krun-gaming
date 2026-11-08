#!/bin/sh
# Host side of the command channel in guest/steam-run.sh: runs a shell snippet in the running guest (as gamer) with
# the Steam client's DISPLAY/XAUTHORITY/WAYLAND_DISPLAY, and prints its output.
# Usage: sh guest-cmd.sh [--root] 'xprop -root | grep GAMESCOPE'   (--root: as root, without Steam's environment)
C=${KRUN_GAMING_CACHE:-$HOME/.local/share/krun-gaming}/out/cmd
TARGET=run.sh
[ "$1" = --root ] && TARGET=run-root.sh && shift
mkdir -p "$C" && rm -f "$C/out.txt"
# the guest has no pgrep: find the steam client via /proc and take over its display environment
cat > "$C/run.tmp" << 'EOF'
for p in /proc/[0-9]*; do
  [ "$(cat "$p/comm" 2> /dev/null)" = steam ] && [ -O "$p" ] && { pid=${p#/proc/}; break; }
done
if [ -n "$pid" ]; then
  eval "$(tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^(DISPLAY|XAUTHORITY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR)=' |
    sed 's/^/export /')"
fi
echo "# steam pid ${pid:-none} DISPLAY=${DISPLAY:-}"
EOF
printf '%s\n' "$1" >> "$C/run.tmp" && mv "$C/run.tmp" "$C/$TARGET"
i=0
until [ -f "$C/out.txt" ]; do
  i=$((i + 1)); [ $i -gt "${TIMEOUT:-100}" ] && { echo "guest-cmd: no answer (is steam-run.sh running?)" >&2; exit 1; }
  sleep 0.1
done
cat "$C/out.txt"
