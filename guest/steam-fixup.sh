#!/bin/bash
# Source or run inside the guest: after unzipping Valve's client packages, do what Steam's updater does — turn entries
# whose names carry Windows separators ("steamrtarm64\libs\libcurl.so") into real paths, and mark ELF binaries and
# shell scripts executable (the zips carry no Unix modes). Usage: steam-fixup.sh STEAM_ROOT
set -euo pipefail
ROOT=${1:?steam root}
cd "$ROOT"
moved=0
while IFS= read -r -d '' f; do
  name=${f#./}
  target=${name//\\//}
  mkdir -p "$(dirname "$target")"
  if [ -d "$name" ]; then mkdir -p "$target" && rmdir "$name" 2> /dev/null || true; else mv -f "$name" "$target"; fi
  moved=$((moved + 1))
done < <(find . -name '*\\*' -print0 | sort -rz) # deepest first
exe=0
while IFS= read -r -d '' f; do
  magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
  if [ "$magic" = 7f454c46 ] || [ "${magic:0:4}" = 2321 ]; then # ELF, or "#!"
    chmod +x "$f" && exe=$((exe + 1))
  fi
done < <(find . -type f -size +0 -print0)
echo "fixup: $moved paths with backslashes moved, $exe files made executable"
# Bundled libraries ship unversioned (steamrtarm64/libavcodec.so) but reference each other by SONAME
# (libavutil.so.59); Steam's x86 launch scripts create these links, nothing does for the ARM64 client.
links=0
for dir in steamrtarm64; do
  missing=$(cd "$dir" && { LD_LIBRARY_PATH=. ldd ./*.so* 2> /dev/null || true; } | awk '/not found/ { print $1 }' | sort -u)
  for soname in $missing; do
    base=${soname%.so.*}.so
    [ -e "$dir/$base" ] && [ ! -e "$dir/$soname" ] && ln -s "$base" "$dir/$soname" && links=$((links + 1))
  done
done
echo "fixup: $links SONAME links created"

# ~/.steam links that Valve's steam.sh creates on first start (we skip the bootstrapper, see steam-arm64-install.sh);
# the ARM64 client launches every game through ~/.steam/sdkarm64/steam-launch-wrapper
H=$(dirname "$(dirname "$(dirname "$ROOT")")") # <home>/.local/share/Steam -> <home>
C=$H/.steam
mkdir -p "$C"
ln -fsn "$ROOT" "$C/root"; ln -fsn "$ROOT" "$C/steam"
ln -fsn "$ROOT/linux32" "$C/sdk32"; ln -fsn "$ROOT/linux64" "$C/sdk64"; ln -fsn "$ROOT/linuxarm64" "$C/sdkarm64"
ln -fsn "$ROOT/ubuntu12_32" "$C/bin32"; ln -fsn "$ROOT/ubuntu12_64" "$C/bin64"; ln -fsn "$C/bin32" "$C/bin"
ln -fsn "$C/steam.pid" "$H/.steampid"; ln -fsn "$C/sdk32/steam" "$H/.steampath"
chown -h "$(stat -c %U "$ROOT")": "$C" "$C"/* "$H/.steampid" "$H/.steampath" 2> /dev/null || true
echo "fixup: ~/.steam links in $C"
