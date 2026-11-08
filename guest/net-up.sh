#!/bin/sh
# Runs inside the guest (launcher --slirp): static eth0 for libslirp's network, then DNS, HTTPS timing and a download.
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
# IPv4-only guest network: no AAAA queries (each one ran into a 5 s resolver timeout through slirp)
printf 'nameserver 10.0.2.3\noptions no-aaaa\n' > /etc/resolv.conf
ip -br addr show eth0
getent hosts store.steampowered.com
curl -sS -o /dev/null \
  -w 'https %{http_code}: dns %{time_namelookup}s connect %{time_connect}s tls %{time_appconnect}s first byte %{time_starttransfer}s total %{time_total}s\n' \
  https://store.steampowered.com/
curl -sS -o /dev/null -w 'download: %{size_download} bytes at %{speed_download} B/s\n' \
  'https://speed.cloudflare.com/__down?bytes=20000000'
