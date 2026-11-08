#!/bin/bash
# Runs inside the builder VM (--net, NAMESERVER, MESA_COMMIT, STAMP; shares: patches = guest-patches/mesa, tests =
# host-tests, out): the guest's Venus Vulkan driver (libvulkan_virtio.so) from the same Mesa commit as the host's
# KosmicKrisp plus our guest patches, instead of Fedora's package: native aarch64 (Steam, gamescope), x86_64 and i686
# for the games under FEX, cross-compiled with clang against a sysroot of Fedora's x86 packages; plus share-image, the
# self-test venus-install.sh runs. Output: /out/<arch>/libvulkan_virtio.so (+ glibc.txt: newest GLIBC_ symbol
# version it needs), /out/share-image, /out/stamp = $STAMP last, only when everything succeeded. Log:
# /out/venus-build.txt.
set -euo pipefail
exec > /out/venus-build.txt 2>&1
: "${MESA_COMMIT:?}" "${STAMP:?}"
rm -f /out/stamp
printf 'nameserver %s\n' "${NAMESERVER:-1.1.1.1}" > /etc/resolv.conf
retry() { local i; for i in 1 2 3 4; do "$@" && return 0; echo "retry $i: $*"; sleep $((i * 5)); done; return 1; }
DEPS="libdrm-devel wayland-devel libX11-devel libxcb-devel libxshmfence-devel libXrandr-devel libXext-devel
  libXfixes-devel expat-devel zlib-devel libzstd-devel systemd-devel libffi-devel"
# shellcheck disable=SC2086 # word lists
retry dnf install -y -q --setopt=install_weak_deps=False git meson ninja-build gcc gcc-c++ clang lld llvm pkgconf \
  python3-mako python3-pyyaml python3-packaging glslang bison flex wayland-protocols-devel vulkan-headers \
  vulkan-loader-devel file $DEPS
S=/root/mesa
[ -d "$S/.git" ] || { git init -q "$S" && git -C "$S" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git; }
retry git -C "$S" fetch -q --depth 1 origin "$MESA_COMMIT"
git -C "$S" checkout -q -f --detach FETCH_HEAD && git -C "$S" clean -qfdx
[ "$(git -C "$S" rev-parse HEAD)" = "$MESA_COMMIT" ]
for p in /patches/*.patch; do git -C "$S" apply "$p" && echo "applied $(basename "$p")"; done

OPTS=(--buildtype=release -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms=x11,wayland -Dopengl=false
  -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled -Dgbm=disabled -Dllvm=disabled -Dvideo-codecs=
  -Dvulkan-layers= -Dtools= -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled)
build() { # build ARCH FILE-PATTERN [meson args...]: FILE-PATTERN = what file(1) must say about the result
  local arch=$1 want=$2 b=/root/venus-$1 lib; shift 2
  lib=$b/src/virtio/vulkan/libvulkan_virtio.so
  meson setup --wipe "$b" "$S" "${OPTS[@]}" "$@" || { tail -40 "$b/meson-logs/meson-log.txt"; return 1; }
  ninja -C "$b" src/virtio/vulkan/libvulkan_virtio.so
  file -L "$lib" | grep -q "$want" || { file -L "$lib"; echo "$arch: wrong architecture"; return 1; }
  mkdir -p "/out/$arch" && install -m 755 "$lib" "/out/$arch/"
  llvm-objdump -T "$lib" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 > "/out/$arch/glibc.txt"
  echo "$arch: $(sha256sum < "$lib" | cut -c1-16), needs $(cat "/out/$arch/glibc.txt")"
}

build "$(uname -m)" 'ARM aarch64'

# one sysroot of Fedora's x86_64 packages plus their i686 multilib builds (Fedora has no i686 repo of its own)
R=/root/x86-root
rm -rf "$R"
# usr-merge layout first, else Fedora's filesystem package fails to unpack over a /lib64 directory
mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/usr/lib" "$R/usr/lib64"
for d in bin sbin lib lib64; do ln -s "usr/$d" "$R/$d"; done
# both arches by their ISA provides (a bare name may be satisfied by the i686 package of the same transaction; the
# i686 names differ, e.g. zlib-devel is zlib-ng-compat-devel)
isa() { for d in glibc-devel libstdc++-devel libatomic $DEPS; do printf '%s(%s) ' "$d" "$1"; done; }
# shellcheck disable=SC2046
retry dnf install -y -q --forcearch=x86_64 --installroot="$R" --use-host-config --setopt=install_weak_deps=False \
  --setopt=tsflags=noscripts gcc $(isa x86-64) $(isa x86-32)
# the i686 packages' own pkg-config requirements (pkgconfig(...) provides have no arch, dnf meets them with x86_64
# packages): add the i686 build of every package providing a missing .pc until pkg-config resolves everything
for _ in 1 2 3 4 5 6; do
  missing=$(for pc in "$R"/usr/lib/pkgconfig/*.pc; do
    PKG_CONFIG_SYSROOT_DIR=$R PKG_CONFIG_LIBDIR=$R/usr/lib/pkgconfig:$R/usr/share/pkgconfig \
      pkg-config --cflags --libs "$(basename "$pc" .pc)" 2>&1 | sed -n "s/^Package '\([^']*\)', required by.*/\1/p"
  done | sort -u)
  [ -z "$missing" ] && break
  echo "i686 pkg-config missing: $missing"
  pkgs=$(for m in $missing; do
    dnf repoquery -q --forcearch=x86_64 --installroot="$R" --use-host-config --qf '%{name}\n' \
      --whatprovides "pkgconfig($m)" | head -1
  done | sort -u)
  # shellcheck disable=SC2046
  retry dnf install -y -q --forcearch=x86_64 --installroot="$R" --use-host-config --setopt=install_weak_deps=False \
    --setopt=tsflags=noscripts $(for p in $pkgs; do printf '%s(x86-32) ' "$p"; done)
done
[ -z "$missing" ] || { echo "i686 pkg-config still missing: $missing"; exit 1; }
# the unversioned links clang's driver links against (Fedora keeps them in GCC's own directory)
for libdir in lib64 lib; do
  for l in libstdc++.so.6 libgcc_s.so.1 libatomic.so.1; do
    [ -e "$R/usr/$libdir/${l%.so.*}.so" ] || ln -s "$l" "$R/usr/$libdir/${l%.so.*}.so"
  done
done
cross() { # cross ARCH LIBDIR CPU-FAMILY FILE-PATTERN CLANG-FLAGS: a meson cross file for the sysroot, then build
  local arch=$1 libdir=$2 family=$3 want=$4 flags=$5
  cat > "/root/$arch.cross" << EOF
[binaries]
c = ['clang', $flags, '--sysroot=$R']
cpp = ['clang++', $flags, '--sysroot=$R']
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'
[built-in options]
c_link_args = ['-fuse-ld=lld', '-L$R/usr/$libdir']
cpp_link_args = ['-fuse-ld=lld', '-L$R/usr/$libdir']
[properties]
sys_root = '$R'
pkg_config_libdir = '$R/usr/$libdir/pkgconfig:$R/usr/share/pkgconfig'
[host_machine]
system = 'linux'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
  build "$arch" "$want" --cross-file "/root/$arch.cross"
}
cross x86_64 lib64 x86_64 'x86-64' "'--target=x86_64-redhat-linux'"
cross i686 lib x86 'Intel 80386' "'--target=x86_64-redhat-linux', '-m32'"

gcc -O2 -o /out/share-image /tests/share-image.c -lvulkan
echo "$STAMP" > /out/stamp
echo "venus-build: ok"
