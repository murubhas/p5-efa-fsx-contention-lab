#!/usr/bin/env bash
set -euo pipefail

LABEL=${1:?usage: run_gdsio_transport.sh LABEL [MOUNT] [RUNTIME_SECONDS] [THREADS_PER_GPU] [SIZE_PER_THREAD]}
MOUNT=${2:-/fsx-efa}
RUNTIME_SECONDS=${3:-90}
THREADS_PER_GPU=${4:-4}
SIZE_PER_THREAD=${5:-16G}
RESULT_ROOT=${RESULT_ROOT:-/fsx/p5-efa-fsx-contention-lab/results}
GDS_ROOT=${GDS_ROOT:-/usr/local/cuda-12.8/gds}
GDSIO=${GDS_ROOT}/tools/gdsio
SOURCE_CONFIG=${GDS_ROOT}/cufile.json
DATA_DIR=${MOUNT}/p5-efa-fsx-contention-lab/${LABEL}
OUT_DIR=${RESULT_ROOT}/${LABEL}

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

[[ -x ${GDSIO} ]] || {
  echo "gdsio not found: ${GDSIO}" >&2
  exit 1
}
[[ -r ${SOURCE_CONFIG} ]] || {
  echo "cuFile configuration not found: ${SOURCE_CONFIG}" >&2
  exit 1
}
mountpoint -q "${MOUNT}" || {
  echo "Mount is not active: ${MOUNT}" >&2
  exit 1
}
grep -q '@efa' < <(lnetctl net show --net efa 2>/dev/null) || {
  echo "No local EFA LNet NIDs are configured" >&2
  exit 1
}
grep -q '@efa' < <(lnetctl peer show -v 4 2>/dev/null) || {
  echo "No discovered EFA filesystem peer is present" >&2
  exit 1
}
[[ -r /proc/driver/nvidia-fs/version ]] || {
  echo "nvidia-fs is not loaded" >&2
  exit 1
}
[[ ! -e ${OUT_DIR}/complete ]] || {
  echo "Refusing to overwrite completed result: ${OUT_DIR}" >&2
  exit 1
}

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
if [[ ${GPU_COUNT} -lt 1 ]]; then
  echo "No NVIDIA GPUs found" >&2
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
  findmnt "${MOUNT}" -o TARGET,SOURCE,FSTYPE,OPTIONS > "${OUT_DIR}/mount-${suffix}.txt"
  lnetctl peer show -v 4 > "${OUT_DIR}/lnet-peers-${suffix}.yaml" 2>&1 || true
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
  } > "${OUT_DIR}/efa-hw-counters-${suffix}.txt" 2>&1 || true
}

disable_stats() {
  echo 0 > /sys/module/nvidia_fs/parameters/rw_stats_enabled 2>/dev/null || true
  echo 0 > /sys/module/nvidia_fs/parameters/peer_stats_enabled 2>/dev/null || true
}
trap disable_stats EXIT

echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled
echo 1 > /sys/module/nvidia_fs/parameters/peer_stats_enabled
echo 1 > /proc/driver/nvidia-fs/stats
capture_state before

run_phase() {
  local operation=$1
  local io_type
  case "${operation}" in
    write) io_type=1 ;;
    read) io_type=0 ;;
    *) echo "Unknown GDS phase: ${operation}" >&2; exit 1 ;;
  esac

  local pids=()
  for ((gpu = 0; gpu < GPU_COUNT; gpu++)); do
    gpu_dir=${DATA_DIR}/gpu-${gpu}
    mkdir -p "${gpu_dir}"
    lfs setstripe -c -1 -S 16M "${gpu_dir}"
    CUFILE_ENV_PATH_JSON="${CUFILE_CONFIG}" \
      CUFILE_FORCE_COMPAT_MODE=false \
      "${GDSIO}" \
      -D "${gpu_dir}" \
      -d "${gpu}" \
      -w "${THREADS_PER_GPU}" \
      -s "${SIZE_PER_THREAD}" \
      -i 1M \
      -x 0 \
      -I "${io_type}" \
      -T "${RUNTIME_SECONDS}" \
      > "${OUT_DIR}/${operation}-gpu-${gpu}.txt" 2>&1 &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "${pid}"
  done

  for ((gpu = 0; gpu < GPU_COUNT; gpu++)); do
    output=${OUT_DIR}/${operation}-gpu-${gpu}.txt
    grep -q 'XferType: GPUD' "${output}" || {
      echo "GPU ${gpu} did not report the GPUD transfer type during ${operation}" >&2
      cat "${output}" >&2
      exit 1
    }
  done
}

run_phase write
sync
run_phase read
capture_state after

python3 - "${LABEL}" "${OUT_DIR}" "${GPU_COUNT}" <<'PY'
import json
import pathlib
import re
import statistics
import sys

label = sys.argv[1]
out_dir = pathlib.Path(sys.argv[2])
gpu_count = int(sys.argv[3])
pattern = re.compile(
    r"IoType:\s+(?P<operation>\w+).*?XferType:\s+(?P<xfer>\w+).*?"
    r"Throughput:\s+(?P<throughput>[0-9.]+)\s+GiB/sec,\s+"
    r"Avg_Latency:\s+(?P<latency>[0-9.]+)\s+usecs"
)


def phase(operation: str) -> dict:
    samples = []
    for gpu in range(gpu_count):
        text = (out_dir / f"{operation}-gpu-{gpu}.txt").read_text()
        match = pattern.search(text)
        if not match:
            raise SystemExit(f"Could not parse {operation} output for GPU {gpu}")
        if match.group("xfer") != "GPUD":
            raise SystemExit(f"Unexpected transfer type on GPU {gpu}: {match.group('xfer')}")
        samples.append(
            {
                "gpu": gpu,
                "throughput_GiBps": float(match.group("throughput")),
                "mean_latency_us": float(match.group("latency")),
            }
        )
    return {
        "aggregate_throughput_GiBps": sum(item["throughput_GiBps"] for item in samples),
        "mean_of_gpu_mean_latency_us": statistics.fmean(item["mean_latency_us"] for item in samples),
        "per_gpu": samples,
    }


summary = {
    "label": label,
    "transfer_type": "GPUD",
    "compatibility_fallback_allowed": False,
    "gpu_count": gpu_count,
    "write": phase("write"),
    "read": phase("read"),
}
(out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, sort_keys=True))
PY

touch "${OUT_DIR}/complete"
