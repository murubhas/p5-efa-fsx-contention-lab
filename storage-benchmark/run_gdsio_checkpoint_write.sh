#!/usr/bin/env bash
set -euo pipefail

LABEL=${1:?usage: run_gdsio_checkpoint_write.sh LABEL [MOUNT] [RUNTIME_SECONDS] [GPU_INDEX] [THREADS] [SIZE_PER_THREAD]}
MOUNT=${2:-/fsx-efa}
RUNTIME_SECONDS=${3:-90}
GPU_INDEX=${4:-0}
THREADS=${5:-4}
SIZE_PER_THREAD=${6:-16G}
START_AT_EPOCH=${START_AT_EPOCH:-0}
RESULT_ROOT=${RESULT_ROOT:-/fsx/p5-efa-fsx-contention-lab/results}
GDS_ROOT=${GDS_ROOT:-/usr/local/cuda-12.8/gds}
GDSIO=${GDS_ROOT}/tools/gdsio
SOURCE_CONFIG=${GDS_ROOT}/cufile.json
HOST=$(hostname)
DATA_DIR=${MOUNT}/p5-efa-fsx-contention-lab/${LABEL}/${HOST}
OUT_DIR=${RESULT_ROOT}/${LABEL}/gds-${HOST}

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

for command in nvidia-smi lnetctl lfs; do
  command -v "${command}" >/dev/null || {
    echo "Required command not found: ${command}" >&2
    exit 1
  }
done

[[ -x ${GDSIO} ]] || { echo "gdsio not found: ${GDSIO}" >&2; exit 1; }
[[ -r ${SOURCE_CONFIG} ]] || { echo "cuFile configuration not found" >&2; exit 1; }
mountpoint -q "${MOUNT}" || { echo "Mount is not active: ${MOUNT}" >&2; exit 1; }
grep -q '@efa' < <(lnetctl net show --net efa 2>/dev/null) || {
  echo "No local EFA LNet NIDs are configured" >&2
  exit 1
}
grep -q '@efa' < <(lnetctl peer show -v 4 2>/dev/null) || {
  echo "No discovered EFA filesystem peer is present" >&2
  exit 1
}
[[ -r /proc/driver/nvidia-fs/version ]] || { echo "nvidia-fs is not loaded" >&2; exit 1; }
[[ ! -e ${OUT_DIR}/complete ]] || {
  echo "Refusing to overwrite completed result: ${OUT_DIR}" >&2
  exit 1
}

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
if (( GPU_INDEX < 0 || GPU_INDEX >= GPU_COUNT )); then
  echo "GPU index ${GPU_INDEX} is outside the available range 0-$((GPU_COUNT - 1))" >&2
  exit 1
fi

mkdir -p "${DATA_DIR}" "${OUT_DIR}"
lfs setstripe -c -1 -S 16M "${DATA_DIR}"

CUFILE_CONFIG=${OUT_DIR}/cufile-failclosed.json
cp "${SOURCE_CONFIG}" "${CUFILE_CONFIG}"
sed -i -E 's/"cufile_stats"[[:space:]]*:[[:space:]]*0/"cufile_stats": 3/' "${CUFILE_CONFIG}"
sed -i -E 's/"allow_compat_mode"[[:space:]]*:[[:space:]]*true/"allow_compat_mode": false/' "${CUFILE_CONFIG}"

capture_state() {
  local suffix=$1
  date -u +%Y-%m-%dT%H:%M:%SZ > "${OUT_DIR}/timestamp-${suffix}.txt"
  lnetctl stats show > "${OUT_DIR}/lnet-stats-${suffix}.yaml" 2>&1 || true
  cat /proc/driver/nvidia-fs/stats > "${OUT_DIR}/nvidia-fs-${suffix}.txt" 2>&1 || true
  {
    for device_path in /sys/class/infiniband/*; do
      [[ -e ${device_path}/device/driver ]] || continue
      [[ $(basename "$(realpath "${device_path}/device/driver")") == efa ]] || continue
      device=$(basename "${device_path}")
      echo "[${device}]"
      for counter_path in "${device_path}"/ports/1/hw_counters/*; do
        [[ -f ${counter_path} ]] || continue
        printf '%s=%s\n' "$(basename "${counter_path}")" "$(<"${counter_path}")"
      done
    done
  } > "${OUT_DIR}/efa-hw-counters-${HOST}-${suffix}.txt"
}

disable_stats() {
  echo 0 > /sys/module/nvidia_fs/parameters/rw_stats_enabled 2>/dev/null || true
  echo 0 > /sys/module/nvidia_fs/parameters/peer_stats_enabled 2>/dev/null || true
}
trap disable_stats EXIT

if [[ ${START_AT_EPOCH} != 0 ]]; then
  python3 - "${START_AT_EPOCH}" <<'PY'
import sys
import time

start_at = float(sys.argv[1])
time.sleep(max(0.0, start_at - time.time()))
PY
fi

echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled
echo 1 > /sys/module/nvidia_fs/parameters/peer_stats_enabled
echo 1 > /proc/driver/nvidia-fs/stats
capture_state before

CUFILE_ENV_PATH_JSON="${CUFILE_CONFIG}" \
  CUFILE_FORCE_COMPAT_MODE=false \
  "${GDSIO}" \
  -D "${DATA_DIR}" \
  -d "${GPU_INDEX}" \
  -w "${THREADS}" \
  -s "${SIZE_PER_THREAD}" \
  -i 1M \
  -x 0 \
  -I 1 \
  -T "${RUNTIME_SECONDS}" \
  > "${OUT_DIR}/write-gpu-${GPU_INDEX}.txt" 2>&1

grep -q 'XferType: GPUD' "${OUT_DIR}/write-gpu-${GPU_INDEX}.txt" || {
  echo "Checkpoint writer did not report XferType: GPUD" >&2
  cat "${OUT_DIR}/write-gpu-${GPU_INDEX}.txt" >&2
  exit 1
}

capture_state after

python3 - "${LABEL}" "${HOST}" "${OUT_DIR}" "${GPU_INDEX}" <<'PY'
import json
import pathlib
import re
import sys

label, host, out_dir_raw, gpu_raw = sys.argv[1:]
out_dir = pathlib.Path(out_dir_raw)
gpu = int(gpu_raw)
text = (out_dir / f"write-gpu-{gpu}.txt").read_text()
match = re.search(
    r"IoType:\s+(?P<operation>\w+).*?XferType:\s+(?P<xfer>\w+).*?"
    r"Throughput:\s+(?P<throughput>[0-9.]+)\s+GiB/sec,\s+"
    r"Avg_Latency:\s+(?P<latency>[0-9.]+)\s+usecs",
    text,
)
if not match or match.group("xfer") != "GPUD":
    raise SystemExit("Could not parse fail-closed GDS checkpoint output (XferType: GPUD)")
summary = {
    "label": label,
    "host": host,
    "gpu": gpu,
    "transfer_type": "GPUD",
    "compatibility_fallback_allowed": False,
    "write_throughput_GiBps": float(match.group("throughput")),
    "mean_latency_us": float(match.group("latency")),
}
(out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, sort_keys=True))
PY

touch "${OUT_DIR}/complete"
