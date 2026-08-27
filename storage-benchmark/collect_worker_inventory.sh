#!/usr/bin/env bash
set -euo pipefail

echo "=== worker inventory ==="
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname=$(hostname)"
echo "kernel=$(uname -r)"
echo "default_interface=$(ip -o -4 route show default | awk 'NR==1 {print $5}')"

echo "--- operating system ---"
sed -n '1,12p' /etc/os-release

echo "--- GPU and topology ---"
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
nvidia-smi topo -m

echo "--- EFA and Lustre modules ---"
for module in efa lustre kefalnd nvidia_fs; do
  if modinfo "${module}" >/dev/null 2>&1; then
    echo "module=${module} present"
    modinfo "${module}" | awk '/^(filename|version|license):/ {print}'
  else
    echo "module=${module} missing"
  fi
done

echo "--- devices and LNet ---"
echo "efa_uverbs=$(find /dev/infiniband -maxdepth 1 -name 'uverbs*' 2>/dev/null | wc -l)"
echo "nvidia_devices=$(find /dev -maxdepth 1 -name 'nvidia[0-9]*' 2>/dev/null | wc -l)"
command -v lfs >/dev/null 2>&1 && lfs --version || true
command -v lnetctl >/dev/null 2>&1 && sudo lnetctl net show || true
command -v lctl >/dev/null 2>&1 && sudo lctl list_nids || true

echo "--- GPUDirect Storage ---"
if command -v gdscheck >/dev/null 2>&1; then
  sudo gdscheck -p
elif [[ -x /usr/local/cuda/gds/tools/gdscheck ]]; then
  sudo /usr/local/cuda/gds/tools/gdscheck -p
else
  echo "gdscheck missing on host"
fi

if command -v gdsio >/dev/null 2>&1; then
  echo "gdsio=$(command -v gdsio)"
elif [[ -x /usr/local/cuda/gds/tools/gdsio ]]; then
  echo "gdsio=/usr/local/cuda/gds/tools/gdsio"
else
  echo "gdsio missing on host"
fi

echo "--- runtime ---"
docker --version 2>/dev/null || true
nvidia-container-cli --version 2>/dev/null || true
