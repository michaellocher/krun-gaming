#!/bin/bash
# Runs inside the guest (launcher --slirp --display): Valve's native ARM64 Steam client (steam-arm64-install.sh) in
# Big Picture mode inside gamescope, as user "gamer" (Steam refuses root). Runs STEAM_SECONDS (default 1800).
# Logs to /out/steam-*.txt.
mkdir -p /out && mount -t virtiofs out /out
# our Venus driver back where a package update put Fedora's (setup.sh, venus-install.sh); log /out/venus-heal.txt
/spike/venus-install.sh heal || echo "venus heal failed, see venus-heal.txt" >&2
/spike/net-up.sh > /out/steam-net.txt 2>&1
# Our own FEX (binfmt + Fedora rootfs): the ARM64 client still runs x86 helpers (install-script evaluator; without
# it launches stall in ProcessingInstallScript). Games run under Valve's FEX compat tool with its own rootfs.
# SYSTEM_FEX=0 drops ours (inside Steam's runtime container it cannot see its rootfs).
if [ "${SYSTEM_FEX:-1}" = 1 ]; then
  . /spike/fex-setup.sh
else
  [ -f /proc/sys/fs/binfmt_misc/FEX-x86_64 ] && echo -1 > /proc/sys/fs/binfmt_misc/FEX-x86_64
  [ -f /proc/sys/fs/binfmt_misc/FEX-x86 ] && echo -1 > /proc/sys/fs/binfmt_misc/FEX-x86
fi

# libinput (in gamescope) only takes input devices udev has tagged (ID_INPUT_*); no systemd here, so run udevd
/usr/lib/systemd/systemd-udevd --daemon 2> /out/steam-udev.txt && udevadm trigger && udevadm settle -t 5
# sound devices: Fedora leaves them root-only and grants the seat user access through logind (uaccess), which is not
# running here; give them to the audio group and put gamer in it (PipeWire in steam-loop.sh)
chgrp audio /dev/snd/* 2> /dev/null && chmod 660 /dev/snd/* && usermod -aG audio gamer
ls /dev/input >> /out/steam-udev.txt 2>&1
# Steam in SteamOS mode (-steamos3) reads network state from NetworkManager over the system bus ("not connected"
# and stalled downloads without it). NM adopts the static eth0 from net-up.sh; no connectivity probes, our resolv.conf
mkdir -p /run/dbus /etc/NetworkManager/conf.d
rm -f /run/dbus/pid /run/dbus/system_bus_socket # /run is on the disk here (no tmpfs): left from the last boot
dbus-daemon --system --fork 2> /out/steam-dbus.txt
printf '[main]\ndns=none\nno-auto-default=*\n[connectivity]\nenabled=false\n' > /etc/NetworkManager/conf.d/krun.conf
# NM's own profile for eth0 (same static setup as net-up.sh): an adopted "external" connection counts as local only
mkdir -p -m 700 /etc/NetworkManager/system-connections
printf '[connection]\nid=eth0\ntype=ethernet\ninterface-name=eth0\n[ipv4]\nmethod=manual\naddress1=10.0.2.15/24,10.0.2.2\nignore-auto-dns=true\n[ipv6]\nmethod=disabled\n' \
  > /etc/NetworkManager/system-connections/eth0.nmconnection
chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection
NetworkManager --no-daemon > /out/steam-nm.txt 2>&1 &
# eth0 is already up (net-up.sh), which NM adopts as "external" (= local only); activate its own profile instead
for _ in $(seq 1 20); do nmcli -t general status > /dev/null 2>&1 && break; sleep 0.25; done
nmcli connection up eth0 >> /out/steam-nm.txt 2>&1
nmcli -t general status >> /out/steam-nm.txt 2>&1
# FEX reserves large address ranges for every x86 process; the default heuristic overcommit made Wine's services
# fail with ERROR_NOT_ENOUGH_MEMORY (error 8) under gamescope, so explorer.exe found no RpcSs and games no desktop
echo 1 > /proc/sys/vm/overcommit_memory
chmod 666 /dev/dri/* /dev/input/event* 2> /dev/null # single-user VM: the gamer user drives KMS, GPU and input
export HOME=/home/gamer XDG_RUNTIME_DIR=/run/user/1000
# Proton warns "Low /proc/sys/vm/max_map_count: 65530 will prevent some games from working": SteamOS' value
echo 2147483642 > /proc/sys/vm/max_map_count
mkdir -p -m 700 "$XDG_RUNTIME_DIR" && chown gamer: "$XDG_RUNTIME_DIR"
if [ "${SYSTEM_FEX:-1}" = 1 ]; then
  mkdir -p "$HOME/.fex-emu" && cp /.fex-emu/Config.json "$HOME/.fex-emu/" && chown -R gamer: "$HOME/.fex-emu"
else
  rm -f "$HOME/.fex-emu/Config.json" # would point Valve's FEX at our rootfs path, which its container lacks
fi
install -m 755 /spike/taskset-wrapper.sh /usr/local/bin/taskset # webhelper on Vulkan, see the script
install -m 755 /spike/xwayland-zink.sh /usr/local/bin/Xwayland-zink # DRI3 for X11 clients, see the script
rm -rf /tmp/.X11-unix /tmp/.X*-lock # left behind by earlier sessions (another user): Xwayland refuses to start
# live logs for the host: Steam's log directory copied to /out/steam-logs every 15 s
( while sleep 15; do
    cp -r "$HOME/.local/share/Steam/logs/." /out/steam-logs/ 2> /dev/null
    cp /tmp/taskset-wrapper.log /out/steam-logs/ 2> /dev/null
    cat /sys/kernel/debug/dri/0/state > /out/steam-logs/kms-state.txt 2> /dev/null
    dmesg | grep -a -i -E "drm|virtio_gpu|fb" | tail -200 > /out/steam-logs/dmesg-drm.txt
  done ) &
# command channel for fast iterations without restarting Steam: the host drops /out/cmd/run.sh, it runs within ~1 s
# as gamer with the Steam process's X/Wayland environment; output in /out/cmd/out.txt, then run.sh is removed
mkdir -p /out/cmd && rm -f /out/cmd/run.sh
( while sleep 1; do
    if [ -f /out/cmd/run-root.sh ]; then # guest-cmd.sh --root: diagnostics that need root (e.g. gamescope's fds)
      mv /out/cmd/run-root.sh /tmp/cmd-root.sh
      timeout -s KILL "${CMD_SECONDS:-60}" bash /tmp/cmd-root.sh > /out/cmd/out.tmp 2>&1
      mv /out/cmd/out.tmp /out/cmd/out.txt
      continue
    fi
    [ -f /out/cmd/run.sh ] || continue
    mv /out/cmd/run.sh /tmp/cmd.sh
    pid=$(grep -lx steam /proc/[0-9]*/comm 2> /dev/null | head -1 | cut -d/ -f3) # no pgrep in the guest
    envs=$([ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ" |
      grep -E '^(DISPLAY|XAUTHORITY|WAYLAND_DISPLAY|GAMESCOPE_WAYLAND_DISPLAY|XDG_RUNTIME_DIR)=')
    { echo "# $(date +%T) steam pid ${pid:-none}"; timeout -s KILL "${CMD_SECONDS:-60}" runuser -u gamer -- env $envs bash /tmp/cmd.sh; } \
      > /out/cmd/out.tmp 2>&1
    mv /out/cmd/out.tmp /out/cmd/out.txt
  done ) &
mkdir -p /out/steam-logs
mount -t debugfs none /sys/kernel/debug 2> /dev/null # KMS state for the live logs
[ -n "$DRM_DEBUG" ] && echo "$DRM_DEBUG" > /sys/module/drm/parameters/debug # e.g. 0x06: driver + KMS messages
STEAM=$HOME/.local/share/Steam/steamrtarm64/steam
ls -la "$STEAM" > /out/steam-launcher.txt 2>&1

# Wine's services.exe gives a starting service 10 s; x86 processes under FEX need longer, so RpcSs failed, explorer.exe
# quit and games waited forever for a desktop. Raise the limit in every Proton prefix and in Proton's template
# prefix (default_pfx), which new games' prefixes are copied from (README: Banished under gamescope).
S=$HOME/.local/share/Steam/steamapps
for reg in "$S"/compatdata/*/pfx/system.reg "$S"/common/Proton*/files/share/default_pfx/system.reg; do
  [ -f "$reg" ] && runuser -u gamer -- python3 /spike/wine-services-timeout.py "$reg" 120000 >> /out/steam-wine.txt 2>&1
done
# the same for explorer.exe: Wine waits a fixed 10 s for it to start, it needs ~15 s under FEX
for so in "$S"/common/Proton*/files/lib/wine/x86_64-unix/win32u.so; do
  [ -f "$so" ] && runuser -u gamer -- python3 /spike/wine-desktop-timeout.py "$so" >> /out/steam-wine.txt 2>&1
done

# the UI's Chromium on the GPU: ANGLE on Venus (raster + compositing); taskset-wrapper.sh adds these switches
printf '%s\n' "${WEBHELPER_FLAGS---use-gl=angle --use-angle=vulkan --enable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE}" \
  > /tmp/webhelper-flags
chown gamer: /tmp/webhelper-flags

SESSION=${SESSION:-gamescope}
if [ "$SESSION" = xorg ] || [ "$SESSION" = gamescope-nested ]; then
  # Xorg on the virtio-gpu KMS device (modesetting, no GL acceleration: shadow framebuffer). "gamescope-nested"
  # nests gamescope fullscreen in it (SDL backend); "xorg" runs Steam as an ordinary X11 client. The default
  # "gamescope" session below has gamescope own the display (DRM backend), as on a Steam Deck.
  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/10-krun.conf << 'EOF'
Section "Device"
  Identifier "virtio-gpu"
  Driver "modesetting"
  Option "kmsdev" "/dev/dri/card0"
  Option "AccelMethod" "none"
EndSection
EOF
  Xorg :0 -nolisten tcp -ac -novtswitch -sharevts -logfile /out/steam-xorg.log > /out/steam-xorg.txt 2>&1 &
  for _ in $(seq 1 50); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 0.2; done
  # Vulkan on X11 needs DRI3 (glamor, i.e. GL on the GPU) unless Mesa's WSI presents by CPU copy: GPU-rendered frames
  # (the UI's ANGLE-on-Venus, games without gamescope) are copied into the window (wsi_common_x11.c, MESA_VK_WSI_DEBUG)
  # In the gamescope session only gamescope's own window takes that path; Steam and games inside present to gamescope
  # through its WSI layer (GPU buffers), so the variable is dropped for them.
  inner=(/spike/steam-loop.sh ${STEAM_ARGS--gamepadui})
  if [ "$SESSION" = gamescope-nested ]; then
    inner=(gamescope --backend sdl -W "${DISPLAY_W:-1280}" -H "${DISPLAY_H:-720}" -f -e -- \
      env -u MESA_VK_WSI_DEBUG ${INNER_WSI_DEBUG:+MESA_VK_WSI_DEBUG=$INNER_WSI_DEBUG} /spike/steam-loop.sh ${STEAM_ARGS--gamepadui -steamos3 -steampal -steamdeck})
  fi
  runuser -u gamer -- env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY=:0 LANG=en_US.UTF-8 \
    MESA_VK_WSI_DEBUG=sw \
    FEX_ROOTFS="$FEX_ROOTFS" timeout "${STEAM_SECONDS:-1800}" dbus-run-session -- \
    "${inner[@]}" > /out/steam-gamescope.txt 2>&1
  echo "rc=$?" >> /out/steam-gamescope.txt
  cp -r "$HOME/.local/share/Steam/logs" /out/steam-logs 2> /dev/null
  exit 0
fi

# SESSION=gamescope (default): gamescope owns the display (DRM backend), Steam in Steam Deck mode
# RENDER_W/RENDER_H: apps render smaller and gamescope upscales. Not the default: Banished's menu ran at ~16 fps both
# at 2560x1440 and 1280x720 (the limit is the x86 game thread under FEX and Venus, not pixels), measured 2026-11-08
runuser -u gamer -- env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" LIBSEAT_BACKEND=noop \
  LANG=en_US.UTF-8 FEX_ROOTFS="$FEX_ROOTFS" STEAM_ZINK="${STEAM_ZINK:-0}" VN_PERF="${VN_PERF:-}" \
  $([ -n "$GS_WSI_DEBUG" ] && echo MESA_VK_WSI_DEBUG="$GS_WSI_DEBUG") \
  $([ "${XWAYLAND_ZINK:-0}" = 1 ] && echo WLR_XWAYLAND=/usr/local/bin/Xwayland-zink) \
  timeout "${STEAM_SECONDS:-1800}" dbus-run-session -- gamescope --backend drm -W "${DISPLAY_W:-1280}" -H "${DISPLAY_H:-720}" \
  ${RENDER_W:+-w "$RENDER_W"} ${RENDER_H:+-h "$RENDER_H"} ${GAMESCOPE_STEAM_MODE--e} -- \
  /spike/steam-loop.sh -gamepadui -steamos3 -steampal -steamdeck > /out/steam-gamescope.txt 2>&1 # as gamescope-session
echo "rc=$?" >> /out/steam-gamescope.txt
cp -r "$HOME/.local/share/Steam/logs" /out/steam-logs 2> /dev/null
df -h / | tail -1 >> /out/steam-gamescope.txt
