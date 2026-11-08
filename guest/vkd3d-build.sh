#!/bin/bash
# Runs inside the builder VM (--net, libkrunfw kernel; shares: spike, cache = source dir, out = install dir): builds
# vkd3d-proton (D3D12 on Vulkan, what Proton uses) natively for aarch64 Linux with its D3D12 test suite, to test DX12
# on Venus without Wine. Tag: VKD3D_TAG (default v3.1). Log: /out/build.txt.
set -eu
exec > /out/build.txt 2>&1
# TSI (--net): the host's resolver, passed as NAMESERVER (no ip tool in the builder for slirp's net-up.sh)
printf 'nameserver %s\n' "${NAMESERVER:-1.1.1.1}" > /etc/resolv.conf
TAG=${VKD3D_TAG:-v3.1}
command -v meson glslangValidator git x86_64-w64-mingw32-widl > /dev/null ||
  dnf install -y --setopt=install_weak_deps=False meson ninja-build gcc-c++ glslang git mingw-w64-tools
# Fedora ships widl (IDL -> C headers) only with a mingw prefix; the 64-bit one generates the same headers here
ln -sf "$(command -v x86_64-w64-mingw32-widl)" /usr/local/bin/widl
SRC=/cache/vkd3d-proton-$TAG
[ -d "$SRC" ] || git clone -q --recursive --depth 1 --shallow-submodules --branch "$TAG" \
  https://github.com/HansKristian-Work/vkd3d-proton.git "$SRC"
B=/root/vkd3d-build # ext4, not virtiofs: faster and no permission surprises
meson setup --wipe "$B" "$SRC" --buildtype release --prefix /out -Denable_tests=true
ninja -C "$B" install
mkdir -p /out/bin && cp "$B/tests/d3d12" /out/bin/
ls -la /out/bin /out/lib* && echo "vkd3d-build: ok"
