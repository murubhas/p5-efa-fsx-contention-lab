#!/usr/bin/env bash
set -euo pipefail

: "${MASTER_ADDR:?MASTER_ADDR is required}"
: "${NCCL_RESULT_LABEL:?NCCL_RESULT_LABEL is required}"

NODE_RANK=${NODE_RANK:-${SLURM_PROCID:-}}
: "${NODE_RANK:?NODE_RANK or SLURM_PROCID is required}"

IMAGE=${IMAGE:-public.ecr.aws/deep-learning-containers/pytorch-training:2.7.1-gpu-py312-cu128-ubuntu22.04-ec2@sha256:f861e28dd9b8ecc86722bd37306b2f7b7e74336bc9c98dba37223cf031d04a7a}
BENCHMARK_SECONDS=${BENCHMARK_SECONDS:-90}
NCCL_TENSOR_MIB=${NCCL_TENSOR_MIB:-256}
NCCL_WARMUP_ITERATIONS=${NCCL_WARMUP_ITERATIONS:-10}
START_AT_EPOCH=${START_AT_EPOCH:-0}
HOST_IFACE=$(ip -o -4 route show default | awk 'NR == 1 {print $5}')
RESULT_DIR=/fsx/p5-efa-fsx-contention-lab/results/${NCCL_RESULT_LABEL}
HOST=$(hostname)

: "${HOST_IFACE:?Could not discover the primary host interface}"
mkdir -p "${RESULT_DIR}"

capture_efa_hardware() {
  local suffix=$1
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
  } > "${RESULT_DIR}/efa-hw-counters-${HOST}-${suffix}.txt"
}

capture_efa_hardware before
date -u +%Y-%m-%dT%H:%M:%SZ > "${RESULT_DIR}/timestamp-${HOST}-before.txt"

docker run --rm --privileged \
  --network host \
  --ipc host \
  --gpus all \
  --ulimit memlock=-1:-1 \
  --ulimit stack=67108864 \
  -v /fsx:/fsx \
  -v /fsx-efa:/fsx-efa \
  -e FI_PROVIDER=efa \
  -e FI_EFA_USE_DEVICE_RDMA=1 \
  -e NCCL_NET="AWS Libfabric" \
  -e NCCL_SOCKET_IFNAME="${HOST_IFACE}" \
  -e NCCL_DEBUG=INFO \
  -e NCCL_DEBUG_SUBSYS=INIT,NET,GRAPH \
  -e MASTER_ADDR="${MASTER_ADDR}" \
  -e MASTER_PORT=29510 \
  -e NODE_RANK="${NODE_RANK}" \
  -e BENCHMARK_SECONDS="${BENCHMARK_SECONDS}" \
  -e NCCL_TENSOR_MIB="${NCCL_TENSOR_MIB}" \
  -e NCCL_WARMUP_ITERATIONS="${NCCL_WARMUP_ITERATIONS}" \
  -e START_AT_EPOCH="${START_AT_EPOCH}" \
  "${IMAGE}" \
  bash -lc "/opt/amazon/efa/bin/fi_info -p efa -t FI_EP_RDM >/dev/null && \
    echo NCCL_EFA_PROVIDER_OK host=\$(hostname) devices=\$(find /dev/infiniband -maxdepth 1 -name 'uverbs*' | wc -l) && \
    torchrun --nnodes=2 --nproc_per_node=8 --node_rank=\${NODE_RANK} \
      --master_addr=\${MASTER_ADDR} --master_port=\${MASTER_PORT} \
      /fsx/p5-efa-fsx-contention-lab/nccl_allreduce_benchmark.py" \
  > "${RESULT_DIR}/nccl-${HOST}.log" 2>&1

capture_efa_hardware after
date -u +%Y-%m-%dT%H:%M:%SZ > "${RESULT_DIR}/timestamp-${HOST}-after.txt"
touch "${RESULT_DIR}/node-${HOST}-complete"

grep 'NCCL_BENCHMARK_COMPLETE' "${RESULT_DIR}/nccl-${HOST}.log" || true
