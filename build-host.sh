#!/bin/bash
# Builds the host GPU path into $CACHE/prefix-$VULKAN_DRIVER: a Vulkan-on-Metal driver, virglrenderer from UTM's fork
# at UTM's own pin (utmapp/UTM patches/sources), libkrun v1.19.8 with the virtio-gpu patches in host-patches/, and the
# vm-gpu launcher. Usage: VULKAN_DRIVER=kosmickrisp|moltenvk bash build-host.sh   (needs Xcode, Homebrew, rustup)
#
# Why these pieces (see README):
# - UTM's virglrenderer fork emulates VK_EXT_external_memory_dma_buf, VK_KHR_external_memory_fd and
#   VK_EXT_image_drm_format_modifier for the guest (what Mesa's WSI needs), backing allocations with POSIX shm
#   imported into the driver with VK_EXT_external_memory_host; Venus runs behind the render server in thread mode.
# - Vulkan driver: KosmicKrisp (Mesa upstream, Metal 4, macOS 26+, default) or UTM's MoltenVK fork, which can import
#   host memory for device-local images (stock MoltenVK cannot) but fails on gamescope's shaders (SPIRV-Cross).
# - libkrun v1.19.8 has the 16K blob alignment fix; host-patches/libkrun (from steamac, no upstream equivalent yet):
#   0007 maps Venus blobs through the shm fds, 0008 implements SET_SCANOUT_BLOB, 0009 signals Venus fences.
set -euo pipefail
DRIVER=${VULKAN_DRIVER:-kosmickrisp}
CACHE=${KRUN_GAMING_CACHE:-$HOME/.local/share/krun-gaming} # not ~/Library/Caches: macOS may purge it
PREFIX=$CACHE/prefix-$DRIVER SRC=$CACHE/src DIR=$(cd "$(dirname "$0")" && pwd)
MESA_COMMIT=${MESA_COMMIT:-c0235eff650720faff05452a06a0a09479b3621f} # mesa main, 2026-11-07
MOLTENVK_COMMIT=b5680e33d7dca891667adea0b4c35ffe905d1a66 # utmapp/UTM patches/sources, 2026-11-08
VIRGL_COMMIT=b6c4d36e12409fa92eeef4d40322c75292f10bb9    # utmapp/UTM patches/sources, 2026-11-08
LIBKRUN_REF=v1.19.8
mkdir -p "$PREFIX/lib/pkgconfig" "$SRC"

brew install meson ninja pkgconf libepoxy lld xz dtc libkrunfw e2fsprogs libslirp
[ "$DRIVER" = kosmickrisp ] && brew install llvm libclc spirv-llvm-translator spirv-tools cmake vulkan-loader vulkan-headers
ICD_JSON=""
rustup target add aarch64-unknown-linux-musl
# code generators need PyYAML, Mako and packaging, which Homebrew does not package
[ -x "$CACHE/venv/bin/python3" ] || python3 -m venv "$CACHE/venv"
"$CACHE/venv/bin/pip" install -q pyyaml mako packaging meson
export PATH="$CACHE/venv/bin:$PATH"

fetch() { # fetch DIR REPO COMMIT: shallow checkout of one commit
  [ -d "$1/.git" ] || { git init -q "$1" && git -C "$1" remote add origin "$2"; }
  git -C "$1" fetch -q --depth 1 origin "$3" && git -C "$1" checkout -q -f --detach FETCH_HEAD
}
vulkan_pc() { # vulkan_pc LIBNAME INCLUDE_DIR: virglrenderer links the driver directly (vulkan-dload=false), as UTM
  cat > "$PREFIX/lib/pkgconfig/vulkan.pc" << EOF
Name: vulkan
Description: $DRIVER as the Vulkan driver
Version: 1.4.$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\).*/\1/p' "$2/vulkan/vulkan_core.h")
Libs: -L$PREFIX/lib -l$1
Cflags: -I$2
EOF
}

if [ "$DRIVER" = kosmickrisp ]; then # built as in Mesa's docs/drivers/kosmickrisp.rst, release instead of debug
  K=$SRC/mesa
  fetch "$K" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_COMMIT"
  for p in "$DIR"/host-patches/mesa/*.patch; do git -C "$K" apply "$p"; done
  PATH="/opt/homebrew/opt/llvm/bin:$PATH" meson setup --wipe "$K/build-kk" "$K" --prefix "$PREFIX" --libdir=lib \
    --buildtype=release -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false \
    -Dzstd=disabled --prefer-static
  PATH="/opt/homebrew/opt/llvm/bin:$PATH" ninja -C "$K/build-kk" install
  # an ICD exports only vk_icdGetInstanceProcAddr: virglrenderer links the Khronos loader (Homebrew vulkan-loader's
  # vulkan.pc), and the launcher points the loader at KosmicKrisp's ICD json (VK_DRIVER_FILES)
  rm -f "$PREFIX/lib/pkgconfig/vulkan.pc"
  ICD_JSON=$PREFIX/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
else # UTM's MoltenVK, built the way UTM's scripts/build_dependencies.sh does
  M=$SRC/moltenvk-utm
  fetch "$M" https://github.com/utmapp/MoltenVK.git "$MOLTENVK_COMMIT"
  if [ ! -f "$M/Package/Release/MoltenVK/dylib/macOS/libMoltenVK.dylib" ]; then
    (cd "$M" && env -i PATH="$PATH" HOME="$HOME" LANG=en_US.UTF-8 ./fetchDependencies --macos &&
      env -i PATH="$PATH" HOME="$HOME" LANG=en_US.UTF-8 make macos)
  fi
  cp "$M/Package/Release/MoltenVK/dylib/macOS/libMoltenVK.dylib" "$PREFIX/lib/"
  install_name_tool -id @rpath/libMoltenVK.dylib "$PREFIX/lib/libMoltenVK.dylib"
  codesign -s - -f "$PREFIX/lib/libMoltenVK.dylib"
  vulkan_pc MoltenVK "$M/External/Vulkan-Headers/include"
fi

export LIBRARY_PATH="$PREFIX/lib:/opt/homebrew/lib" CPATH=/opt/homebrew/include
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
V=$SRC/virglrenderer-utm
fetch "$V" https://github.com/utmapp/virglrenderer.git "$VIRGL_COMMIT" && git -C "$V" clean -qfdx
for p in "$DIR"/host-patches/virglrenderer/*.patch; do git -C "$V" apply "$p"; done
meson setup --wipe "$V/build" "$V" --prefix "$PREFIX" --libdir=lib --buildtype=release -Dvenus=true \
  -Dvulkan-dload=false -Drender-server-mode=thread -Drender-server-worker=thread -Dneptune=false -Dvtest=false \
  -Dtests=false -Dvideo=false -Dcheck-gl-errors=false
ninja -C "$V/build" install

L=$SRC/libkrun-display
[ -e "$L/.git" ] || git clone -q https://github.com/containers/libkrun.git "$L"
git -C "$L" fetch -q --tags origin
git -C "$L" checkout -q -f "$LIBKRUN_REF" && git -C "$L" clean -qfdx -e /target
for p in "$DIR"/host-patches/libkrun/*.patch; do git -C "$L" apply "$p"; done
CLANG="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib"
export LIBCLANG_PATH=$CLANG RUSTFLAGS="-C link-arg=-Wl,-rpath,$CLANG" CARGO_PROFILE_RELEASE_STRIP=false
make -C "$L" BLK=1 NET=1 GPU=1 INPUT=1 SND=1 # INPUT: virtio-input (v1.19.8 already has the select/subsel fixes), SND: virtio-snd (CoreAudio, 0010)
make -C "$L" BLK=1 NET=1 GPU=1 INPUT=1 SND=1 PREFIX="$PREFIX" install

# launcher: VM + display window (vm-gpu.m) + keyboard/mouse (input-mac.m) + networking via libslirp (net-slirp.c)
SLIRP=$(PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig pkg-config --cflags --libs slirp) # bash: splits unquoted
cc -O2 -Wall $SLIRP -c -o "$PREFIX/net-slirp.o" "$DIR/net-slirp.c"
cc -O2 -Wall -I"$PREFIX/include" -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -Wl,-rpath,/opt/homebrew/lib \
  -fobjc-arc -DVK_DRIVER_JSON="\"$ICD_JSON\"" $SLIRP \
  -o "$PREFIX/vm-gpu" "$DIR/vm-gpu.m" "$DIR/input-mac.m" "$PREFIX/net-slirp.o" -lkrun -framework Cocoa -framework IOSurface \
  -framework QuartzCore
install_name_tool -change libkrun.1.dylib @rpath/libkrun.1.dylib "$PREFIX/vm-gpu" # libkrun records a bare name
codesign -s - -f --entitlements "$DIR/hvf.entitlements" "$PREFIX/vm-gpu"
# guest LD_PRELOAD shim for the Steam UI (guest/angle-argb-visual.c): aarch64 Linux, built here (the guest has no
# compiler). Lands in guest/, the VM's /spike share.
clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fuse-ld=lld -fno-builtin -Wall \
  -o "$DIR/guest/angle-argb-visual.so" "$DIR/guest/angle-argb-visual.c"
otool -L "$PREFIX/lib/libvirglrenderer.1.dylib" | grep -i -E "molten|kosmic"
echo "$DRIVER + UTM virglrenderer ${VIRGL_COMMIT:0:8} + libkrun $LIBKRUN_REF: $PREFIX/vm-gpu"
