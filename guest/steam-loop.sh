#!/bin/bash
# Runs as the gamer user inside gamescope: Valve's native ARM64 client, restarted whenever it exits (it exits 42
# after a self-update, which steam.sh handles for the x86 client; ending it on purpose restarts it too, for quick
# experiments without a VM restart). touch /tmp/steam-stop to end the session instead.
STEAM=$HOME/.local/share/Steam/steamrtarm64/steam
export CPU_MHZ=${CPU_MHZ:-3200} # the VM's /proc/cpuinfo has no clock; Steam asks for this variable
# STEAM_ZINK=1 (with XWAYLAND_ZINK=1 in steam-run.sh): UI GL on the GPU via zink. Off by default: shared (dma-buf)
# buffers on zink fail on this host (KosmicKrisp has no linear render targets), so the screen stays black. The UI
# uses ANGLE on Vulkan instead (steam-run.sh, taskset-wrapper.sh); games use Vulkan (Venus) directly.
[ "${STEAM_ZINK:-0}" = 1 ] && export MESA_LOADER_DRIVER_OVERRIDE=zink __GLX_VENDOR_LIBRARY_NAME=mesa
# sound: PipeWire with its PulseAudio server (Proton's Wine plays through it) on the virtio-snd card, which the host
# plays through CoreAudio; in this session's D-Bus like Steam. No systemd user session here, so started directly.
if [ -e /dev/snd/pcmC0D0p ] && [ "${SOUND:-1}" = 1 ]; then
  # never suspend the virtio sink: Steam routes each game through a passive loopback (pw-audio-namespace), and a
  # passive stream does not wake a suspended sink, so games stayed silent while the Steam UI was audible
  mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
  cat > "$HOME/.config/wireplumber/wireplumber.conf.d/51-krun-no-suspend.conf" << 'CONF'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = { update-props = { session.suspend-timeout-seconds = 0 } }
  }
]
CONF
  pipewire > /tmp/pipewire.log 2>&1 &
  sleep 0.5
  wireplumber > /tmp/wireplumber.log 2>&1 &
  pipewire-pulse > /tmp/pipewire-pulse.log 2>&1 &
  ( sleep 3; wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 ) &
fi
rm -f /tmp/steam-stop
while true; do
  # /tmp/steam-args (one line, optional) replaces the arguments for the next start, for quick experiments
  args=("$@")
  [ -s /tmp/steam-args ] && read -r -a args < /tmp/steam-args
  echo "steam-loop: starting steam ${args[*]}"
  "$STEAM" "${args[@]}"
  rc=$?
  echo "steam-loop: steam exited with $rc"
  [ -f /tmp/steam-stop ] && exit $rc
  sleep 1
done
