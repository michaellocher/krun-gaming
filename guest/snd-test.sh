#!/bin/sh
# Runs inside the guest (launcher --display: virtio-snd): lists the sound devices and times a 2 x 1.5 s sine on the
# raw ALSA device, then through PipeWire's PulseAudio server if PW=1. Output to /out/snd-test.txt.
mkdir -p /out && mount -t virtiofs out /out
exec > /out/snd-test.txt 2>&1
ls /dev/snd; aplay -l
s=$(date +%s.%N)
speaker-test -D hw:0,0 -c 2 -r 48000 -F S16_LE -t sine -l 1 -p 50000 2>&1 | tail -4
echo "rc=$? alsa took $(echo "$(date +%s.%N) - $s" | awk '{print $1 - $3}') s"
if [ "${PW:-0}" = 1 ]; then # as in steam-run.sh: udev (WirePlumber's ALSA monitor), a session bus
  /usr/lib/systemd/systemd-udevd --daemon && udevadm trigger && udevadm settle -t 5
  export XDG_RUNTIME_DIR=/run/user/0; mkdir -p -m 700 $XDG_RUNTIME_DIR
  dbus-run-session -- sh -c '
    pipewire & sleep 1; wireplumber 2> /dev/null & sleep 2; pipewire-pulse & sleep 2
    wpctl status 2>&1 | sed -n "/Sinks:/,/Sources:/p" | head -4
    s=$(date +%s.%N)
    speaker-test -D pipewire -c 2 -t sine -l 1 2>&1 | tail -2
    echo "rc=$? pipewire took $(echo "$(date +%s.%N) - $s" | awk "{print \$1 - \$3}") s"'
fi
