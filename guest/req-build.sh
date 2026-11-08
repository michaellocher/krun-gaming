#!/bin/bash
# Runs inside the builder VM (--net, NAMESERVER; shares: tests = host-tests/, out): compiles the Vulkan requirement
# checks (dxvk-, vkd3d-requirements.c) for the guest. Run them there with req-run.sh. Log: /out/req-build.txt.
exec > /out/req-build.txt 2>&1
printf 'nameserver %s\n' "${NAMESERVER:-1.1.1.1}" > /etc/resolv.conf
[ -f /usr/include/vulkan/vulkan.h ] && [ -e /usr/lib64/libvulkan.so ] ||
  dnf install -y --setopt=install_weak_deps=False vulkan-headers vulkan-loader-devel
for t in dxvk vkd3d; do gcc -O2 -o "/out/$t-req" "/tests/$t-requirements.c" -lvulkan && echo "built $t-req"; done
gcc -O2 -o /out/venus-upload /tests/venus-upload.c -lvulkan && echo "built venus-upload"
gcc -O2 -pthread -o /out/tso-litmus /tests/tso-litmus.c && echo "built tso-litmus"
gcc -O2 -o /out/external-image /tests/external-image.c -lvulkan && echo "built external-image"
gcc -O2 -o /out/share-image /tests/share-image.c -lvulkan && echo "built share-image"
