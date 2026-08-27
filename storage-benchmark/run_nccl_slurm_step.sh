#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 JOB_ID RESULT_LABEL [SECONDS] [TENSOR_MIB]" >&2
  exit 2
fi

JOB_ID=$1
NCCL_RESULT_LABEL=$2
BENCHMARK_SECONDS=${3:-90}
NCCL_TENSOR_MIB=${4:-256}

mapfile -t HOSTS < <(/opt/slurm/bin/scontrol show hostnames \
  "$(/opt/slurm/bin/squeue -h -j "${JOB_ID}" -o '%N')")
if [[ ${#HOSTS[@]} -ne 2 ]]; then
  echo "Expected two nodes in Slurm job ${JOB_ID}; got ${#HOSTS[@]}" >&2
  exit 1
fi

export MASTER_ADDR=${HOSTS[0]}
export NCCL_RESULT_LABEL
export BENCHMARK_SECONDS
export NCCL_TENSOR_MIB

echo "NCCL_SLURM_STEP_START job=${JOB_ID} nodes=${HOSTS[*]} master=${MASTER_ADDR} label=${NCCL_RESULT_LABEL}"
/opt/slurm/bin/srun \
  --jobid="${JOB_ID}" \
  --overlap \
  --nodes=2 \
  --ntasks=2 \
  --ntasks-per-node=1 \
  --export=ALL \
  /fsx/p5-efa-fsx-contention-lab/run_nccl_benchmark_node.sh
echo "NCCL_SLURM_STEP_COMPLETE job=${JOB_ID} label=${NCCL_RESULT_LABEL}"
