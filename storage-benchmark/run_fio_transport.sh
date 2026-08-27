#!/usr/bin/env bash
set -euo pipefail

LABEL=${1:?usage: run_fio_transport.sh LABEL [MOUNT] [RUNTIME_SECONDS] [NUM_JOBS] [SIZE_PER_JOB]}
MOUNT=${2:-/fsx-efa}
RUNTIME_SECONDS=${3:-90}
NUM_JOBS=${4:-8}
SIZE_PER_JOB=${5:-16G}
RESULT_ROOT=${RESULT_ROOT:-/fsx/p5-efa-fsx-contention-lab/results}
DEFAULT_INTERFACE=$(ip -o -4 route show default | awk 'NR==1 {print $5}')
DATA_DIR="${MOUNT}/p5-efa-fsx-contention-lab/${LABEL}"
OUT_DIR="${RESULT_ROOT}/${LABEL}"

if ! mountpoint -q "${MOUNT}"; then
  echo "Mount is not active: ${MOUNT}" >&2
  exit 1
fi

if [[ -e "${OUT_DIR}/complete" ]]; then
  echo "Refusing to overwrite completed result: ${OUT_DIR}" >&2
  exit 1
fi

mkdir -p "${DATA_DIR}" "${OUT_DIR}"
lfs setstripe -c -1 -S 16M "${DATA_DIR}"

capture_state() {
  local suffix=$1
  date -u +%Y-%m-%dT%H:%M:%SZ > "${OUT_DIR}/timestamp-${suffix}.txt"
  hostname > "${OUT_DIR}/hostname-${suffix}.txt"
  findmnt "${MOUNT}" -o TARGET,SOURCE,FSTYPE,OPTIONS > "${OUT_DIR}/mount-${suffix}.txt"
  lnetctl net show > "${OUT_DIR}/lnet-${suffix}.yaml" 2>&1 || true
  lnetctl peer show -v 4 > "${OUT_DIR}/lnet-peers-${suffix}.yaml" 2>&1 || true
  lnetctl udsp show > "${OUT_DIR}/lnet-udsp-${suffix}.yaml" 2>&1 || true
  lnetctl stats show > "${OUT_DIR}/lnet-stats-${suffix}.yaml" 2>&1 || true
  lctl list_nids > "${OUT_DIR}/nids-${suffix}.txt" 2>&1 || true
  ip -s link show "${DEFAULT_INTERFACE}" > "${OUT_DIR}/ip-${suffix}.txt" 2>&1 || true
  ethtool -S "${DEFAULT_INTERFACE}" > "${OUT_DIR}/ethtool-${suffix}.txt" 2>&1 || true
  rdma statistic show > "${OUT_DIR}/rdma-${suffix}.txt" 2>&1 || true
  {
    for device_path in /sys/class/infiniband/*; do
      [[ -e "${device_path}/device/driver" ]] || continue
      [[ $(basename "$(realpath "${device_path}/device/driver")") == efa ]] || continue
      device=$(basename "${device_path}")
      echo "[${device}]"
      for counter_path in "${device_path}"/ports/1/hw_counters/*; do
        [[ -f "${counter_path}" ]] || continue
        printf '%s=%s\n' "$(basename "${counter_path}")" "$(<"${counter_path}")"
      done
    done
  } > "${OUT_DIR}/efa-hw-counters-${suffix}.txt" 2>&1 || true
}

run_fio() {
  local operation=$1
  fio \
    --name="${LABEL}-${operation}" \
    --directory="${DATA_DIR}" \
    --filename_format='file.$jobnum' \
    --rw="${operation}" \
    --bs=1M \
    --ioengine=libaio \
    --direct=1 \
    --iodepth=32 \
    --numjobs="${NUM_JOBS}" \
    --size="${SIZE_PER_JOB}" \
    --time_based=1 \
    --runtime="${RUNTIME_SECONDS}" \
    --group_reporting=1 \
    --fallocate=none \
    --output-format=json \
    --output="${OUT_DIR}/${operation}.json"
}

capture_state before
run_fio write
sync
run_fio read
capture_state after

python3 - "${LABEL}" "${OUT_DIR}" <<'PY'
import json
import pathlib
import sys

label = sys.argv[1]
out_dir = pathlib.Path(sys.argv[2])
write = json.loads((out_dir / "write.json").read_text())["jobs"][0]["write"]
read = json.loads((out_dir / "read.json").read_text())["jobs"][0]["read"]
summary = {
    "label": label,
    "write_GBps": write["bw_bytes"] / 1e9,
    "read_GBps": read["bw_bytes"] / 1e9,
    "write_iops": write["iops"],
    "read_iops": read["iops"],
    "write_mean_latency_ms": write["lat_ns"]["mean"] / 1e6,
    "read_mean_latency_ms": read["lat_ns"]["mean"] / 1e6,
}
(out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, sort_keys=True))
PY

touch "${OUT_DIR}/complete"
