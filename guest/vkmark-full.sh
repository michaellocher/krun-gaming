#!/bin/sh
# Runs inside the guest: the default vkmark scene set, headless at 1280x720, results to /out/vkmark-full.txt.
mkdir -p /out && mount -t virtiofs out /out
vkmark --winsys headless --size 1280x720 > /out/vkmark-full.txt 2>&1
echo "rc=$?" >> /out/vkmark-full.txt
