#!/bin/bash
# Runs inside the builder VM (--net, NAMESERVER; shares: tests = host-tests/, out): builds small X11 test clients
# for the guest (argb-window, xgrab, xdraw, xpump). Log: /out/xtest-build.txt.
exec > /out/xtest-build.txt 2>&1
printf 'nameserver %s\n' "${NAMESERVER:-1.1.1.1}" > /etc/resolv.conf
[ -f /usr/include/X11/Xlib.h ] || dnf install -y --setopt=install_weak_deps=False libX11-devel
for t in argb-window xgrab xdraw xpump; do gcc -O2 -o "/out/$t" "/tests/$t.c" -lX11 && echo "built $t"; done
