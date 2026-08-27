#!/usr/bin/env bash
set -euo pipefail

NVIDIA_FS_VERSION=${NVIDIA_FS_VERSION:-2.24.2}
SOURCE_DIR=${SOURCE_DIR:-/opt/gds-nvidia-fs-v${NVIDIA_FS_VERSION}}

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if modinfo nvidia_fs >/dev/null 2>&1; then
  echo "nvidia_fs is already installed: $(modinfo -F version nvidia_fs)"
  modprobe nvidia_fs
  exit 0
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential \
  git \
  "linux-headers-$(uname -r)"

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone --branch "v${NVIDIA_FS_VERSION}" --depth 1 \
    https://github.com/NVIDIA/gds-nvidia-fs.git "${SOURCE_DIR}"
fi

pushd "${SOURCE_DIR}/src" >/dev/null
export NVFS_MAX_PEER_DEVS=128
export NVFS_MAX_PCI_DEPTH=16
make clean
make
install -D -m 0644 nvidia-fs.ko \
  "/lib/modules/$(uname -r)/extra/nvidia-fs.ko"
popd >/dev/null

depmod -a
modprobe nvidia_fs

echo "NVIDIA_FS_READY version=$(modinfo -F version nvidia_fs) kernel=$(uname -r)"
lsmod | grep '^nvidia_fs'
