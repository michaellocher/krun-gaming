#!/bin/sh
# Runs inside the builder disk on first setup: toolchain for building the guest kernel (deletable afterwards).
set -eu
dnf install -y --setopt=install_weak_deps=False gcc make flex bison bc perl-interpreter python3 diffutils \
  findutils xz tar patch hostname elfutils-libelf-devel openssl-devel
gcc --version | head -1
dnf clean all
