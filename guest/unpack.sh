#!/bin/sh
# Runs in the bootstrap VM (root = unpacked base layer on virtiofs): unpacks the layers into the ext4 image as root,
# so the files keep their owners (a host-side mke2fs -d would make everything owned by the Mac user).
set -eu
mkdir -p /mnt/root /layers
mount -t ext4 /dev/vda /mnt/root
mount -t virtiofs layers /layers
for t in /layers/*.tar; do tar --numeric-owner --xattrs --xattrs-include='*' -xpf "$t" -C /mnt/root; done
cp /etc/resolv.conf /mnt/root/etc/resolv.conf
mkdir -p /mnt/root/opt/spike && cp /opt/spike/*.sh /mnt/root/opt/spike/
sync
umount /mnt/root
echo "unpacked into /dev/vda"
