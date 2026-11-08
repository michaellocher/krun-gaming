#!/bin/bash
# Runs inside the guest (launcher --display; shares: out, vkd3d = vkd3d-build.sh install dir): vkd3d-proton's D3D12
# test suite on Venus (Apple GPU via KosmicKrisp). VKD3D_TEST_FILTER/MATCH/EXCLUDE pass through; GDB=1 runs it under
# gdb and prints a backtrace on a crash. Output in /out/vkd3d-test.txt, summary line at the end.
mkdir -p /out /vkd3d && mount -t virtiofs out /out && mount -t virtiofs vkd3d /vkd3d
export LD_LIBRARY_PATH=/vkd3d/lib64:/vkd3d/lib VKD3D_TEST_PLATFORM=other VKD3D_DEBUG=${VKD3D_DEBUG:-warn}
cd /tmp
if [ "${GDB:-0}" = 1 ]; then
  timeout "${TEST_SECONDS:-900}" $(command -v gdb || echo gdb.minimal) -q -batch -ex run -ex 'thread apply all bt 12' /vkd3d/bin/d3d12 > /out/vkd3d-test.txt 2>&1
else
  timeout "${TEST_SECONDS:-900}" stdbuf -oL -eL /vkd3d/bin/d3d12 > /out/vkd3d-test.txt 2>&1
fi
echo "rc=$?" >> /out/vkd3d-test.txt
