#!/bin/bash
# Runs inside the guest (--slirp): installs Valve's native ARM64 Linux Steam client for user "gamer" the way Steam's
# own updater does: read the official manifest (client-update.steamstatic.com/steam_client_linuxarm64), download
# every package, check its sha256 against the manifest, unzip into ~/.local/share/Steam. The bootstrapper's i386
# updater is not used. Output to /out/steam-arm64-install.txt.
set -euo pipefail
mkdir -p /out && mount -t virtiofs out /out 2> /dev/null || true
exec > /out/steam-arm64-install.txt 2>&1
/spike/net-up.sh > /dev/null 2>&1
rpm -q unzip > /dev/null 2>&1 || dnf install -y -q unzip

id gamer > /dev/null 2>&1 || useradd -m -u 1000 gamer
CDN=https://client-update.steamstatic.com
ROOT=/home/gamer/.local/share/Steam DL=/var/tmp/steam-arm64
mkdir -p "$ROOT" "$DL"
curl -fsSL -o "$DL/manifest.vdf" "$CDN/steam_client_linuxarm64"
grep -m1 '"version"' "$DL/manifest.vdf"

# "file" and "sha2" lines of each package block, in order (zipvz/sha2vz are the alternative LZMA variant)
awk -F'"' '$2 == "file" { f = $4 } $2 == "sha2" && f { print f, $4; f = "" }' "$DL/manifest.vdf" > "$DL/packages"
total=0
while read -r file sha; do
  [ -f "$DL/$file" ] || curl -fsSL -o "$DL/$file" "$CDN/$file"
  echo "$sha  $DL/$file" | sha256sum -c --quiet -
  unzip -o -q "$DL/$file" -d "$ROOT"
  total=$((total + $(stat -c %s "$DL/$file")))
done < "$DL/packages"
echo "$(wc -l < "$DL/packages") packages, $((total / 1048576)) MB, all sha256 ok"
cp "$DL/manifest.vdf" "$ROOT/package/steam_client_linuxarm64.manifest" 2> /dev/null || true
rm -rf "$DL"
/spike/steam-fixup.sh "$ROOT" # Windows separators in the zips, exec bits
chown -R gamer: /home/gamer

ls "$ROOT"
file "$ROOT/steamrtarm64/steam" 2> /dev/null || ls -la "$ROOT/steamrtarm64" | head
du -sh "$ROOT"
fstrim / 2> /dev/null || true
